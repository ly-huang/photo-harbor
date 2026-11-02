import Foundation
import SwiftUI

struct CubeLUT: Sendable {
    let dimension: Int
    let data: Data
    var minimum = SIMD3<Float>(repeating: 0)
    var maximum = SIMD3<Float>(repeating: 1)
    static func parse(_ source: Data) throws -> CubeLUT {
        guard source.count <= 32 * 1024 * 1024, let decoded = String(data: source, encoding: .utf8) else { throw LibraryError.message("LUT 必须是小于 32 MB 的 UTF-8 .cube 文件。") }
        let text = decoded.replacingOccurrences(of: "\u{FEFF}", with: "")
        var size: Int?, minimum = SIMD3<Float>(repeating: 0), maximum = SIMD3<Float>(repeating: 1)
        var values: [Float] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.components(separatedBy: "#")[0].trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            let words = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            if words[0] == "TITLE" { continue }
            if words[0] == "LUT_1D_SIZE" { throw LibraryError.message("仅支持三维 LUT，不支持1D LUT。") }
            if words[0] == "LUT_3D_SIZE" {
                guard size == nil, values.isEmpty, words.count == 2, let value = Int(words[1]), (2...64).contains(value) else { throw LibraryError.message("LUT_3D_SIZE 必须为 2–64。") }
                size = value; continue
            }
            if words[0] == "DOMAIN_MIN" || words[0] == "DOMAIN_MAX" {
                let domain = words.dropFirst().compactMap(Float.init)
                guard words.count == 4, domain.count == 3, domain.allSatisfy({ $0.isFinite && abs($0) <= 1_000_000 }), values.isEmpty else { throw LibraryError.message("LUT 输入范围无效。") }
                if words[0] == "DOMAIN_MIN" { minimum = SIMD3(domain[0], domain[1], domain[2]) }
                else { maximum = SIMD3(domain[0], domain[1], domain[2]) }
                continue
            }
            let numbers = words.compactMap(Float.init)
            guard numbers.count == 3, words.count == 3, numbers.allSatisfy({ $0.isFinite && abs($0) <= 1_000_000 }) else { throw LibraryError.message("LUT 含无效数据或不支持的指令。") }
            values.append(contentsOf: numbers); values.append(1)
            guard values.count <= 64 * 64 * 64 * 4 else { throw LibraryError.message("LUT 数据过大。") }
        }
        guard let dimension = size, values.count == dimension * dimension * dimension * 4 else { throw LibraryError.message("LUT 数据行数不匹配。") }
        for i in 0..<3 { guard minimum[i] < maximum[i] else { throw LibraryError.message("LUT 输入范围无效。") } }
        let data = values.withUnsafeBufferPointer { Data(buffer: $0) }
        return CubeLUT(dimension: dimension, data: data, minimum: minimum, maximum: maximum)
    }
}

struct LUTEntry: Identifiable, Codable, Sendable {
    let id: String
    let name: String
}

enum LUTStorage {
    static func file(_ entry: LUTEntry, in directory: URL) -> URL { directory.appendingPathComponent(entry.id + ".cube") }
    static func entries(in directory: URL) -> [LUTEntry] {
        guard (try? EditPersistence.rejectLinks(directory)) != nil, let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        return files.filter { $0.pathExtension == "json" }.compactMap { url in
            guard (try? EditPersistence.rejectLinks(url)) != nil, let data = try? Data(contentsOf: url), data.count < 64 * 1024, let entry = try? JSONDecoder().decode(LUTEntry.self, from: data),
                  entry.id.count == 64, entry.id.allSatisfy({ $0.isHexDigit }),
                  FileManager.default.fileExists(atPath: file(entry, in: directory).path) else { return nil }
            return entry
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    static func add(_ source: URL, to directory: URL, name: String? = nil) throws -> LUTEntry {
        guard source.pathExtension.lowercased() == "cube" else { throw LibraryError.message("请选择 .cube 文件。") }
        let attributes = try source.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard attributes.isRegularFile == true, (attributes.fileSize ?? Int.max) <= 32 * 1024 * 1024 else { throw LibraryError.message("LUT 文件无效或过大。") }
        let data = try Data(contentsOf: source)
        _ = try CubeLUT.parse(data)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try EditPersistence.rejectLinks(directory)
        let displayName = try normalizedName(name ?? source.deletingPathExtension().lastPathComponent)
        let entry = LUTEntry(id: EditPersistence.hash(data), name: displayName)
        let destination = file(entry, in: directory), metadata = directory.appendingPathComponent(entry.id + ".json")
        if FileManager.default.fileExists(atPath: destination.path) {
            try EditPersistence.rejectLinks(destination)
            guard try Data(contentsOf: destination) == data else { throw LibraryError.message("LUT 库中的文件已被修改。") }
        } else { try data.write(to: destination, options: .withoutOverwriting) }
        if FileManager.default.fileExists(atPath: metadata.path) {
            try EditPersistence.rejectLinks(metadata)
            let existing = try JSONDecoder().decode(LUTEntry.self, from: Data(contentsOf: metadata))
            guard existing.id == entry.id else { throw LibraryError.message("LUT 库元数据无效。") }
            return existing // Reimporting never renames an existing library entry.
        }
        try requireUniqueName(entry.name, except: entry.id, in: directory)
        try JSONEncoder().encode(entry).write(to: metadata, options: .withoutOverwriting)
        return entry
    }
    static func normalizedName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 80, !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }), !trimmed.contains("/"), !trimmed.contains(":") else { throw LibraryError.message("LUT 名称须为 1–80 个字符，不能包含换行、斜杠或冒号。") }
        return trimmed
    }
    private static func requireUniqueName(_ name: String, except id: String, in directory: URL) throws {
        guard !entries(in: directory).contains(where: { $0.id != id && $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }) else { throw LibraryError.message("库中已有同名 LUT，请换一个名称。") }
    }
    static func rename(_ entry: LUTEntry, to name: String, in directory: URL) throws -> LUTEntry {
        let name = try normalizedName(name)
        _ = try load(entry, in: directory)
        let metadata = directory.appendingPathComponent(entry.id + ".json")
        try EditPersistence.rejectLinks(metadata)
        let current = try JSONDecoder().decode(LUTEntry.self, from: Data(contentsOf: metadata))
        guard current.id == entry.id else { throw LibraryError.message("LUT 元数据已变化，请重新打开管理窗口。") }
        try requireUniqueName(name, except: entry.id, in: directory)
        let renamed = LUTEntry(id: entry.id, name: name)
        try JSONEncoder().encode(renamed).write(to: metadata, options: .atomic)
        return renamed
    }
    static func load(_ entry: LUTEntry, in directory: URL) throws -> CubeLUT {
        let url = file(entry, in: directory); try EditPersistence.rejectLinks(url)
        let data = try Data(contentsOf: url)
        guard EditPersistence.hash(data) == entry.id else { throw LibraryError.message("LUT 库文件校验失败。") }
        return try CubeLUT.parse(data)
    }
}

@MainActor final class LUTLibrary: ObservableObject {
    private static var instances: [URL: LUTLibrary] = [:]
    static func shared(directory: URL) -> LUTLibrary {
        if let library = instances[directory] { return library }
        let library = LUTLibrary(directory: directory); instances[directory] = library; return library
    }
    @Published var entries: [LUTEntry] = []
    @Published var selectedKind = FilterLibraryKind.filter
    @Published var photoFilters: [ImportedPhotoFilter] = []
    @Published var importCompleted=0
    @Published var importTotal=0
    var filtersDirectory: URL { directory.deletingLastPathComponent().appendingPathComponent("Filters") }
    let directory: URL
    init(directory: URL) { self.directory = directory; reload() }
    func reload() { entries = LUTStorage.entries(in: directory); photoFilters = PhotoFilterStorage.entries(in: filtersDirectory) }
    func add(_ urls: [URL]) async throws { try await addNamed(urls.map { LUTImportItem(url: $0, name: $0.deletingPathExtension().lastPathComponent) }) }
    func addNamed(_ items: [LUTImportItem]) async throws {
        let result=await importNamed(items)
        if !result.failures.isEmpty { throw LibraryError.message("已成功处理 \(result.succeeded) 个，失败 \(result.failures.count) 个：\n"+result.failures.map(\.message).joined(separator:"\n")) }
    }
    func importNamed(_ items:[LUTImportItem]) async -> FilterImportResult {
        let directory = directory, filtersDirectory = filtersDirectory
        var result=FilterImportResult();importCompleted=0;importTotal=items.count
        for item in items {
            do { try await Task.detached { if item.url.pathExtension.lowercased() == "xmp" { _ = try PhotoFilterStorage.add(item.url,to:filtersDirectory,name:item.name) } else { _ = try LUTStorage.add(item.url, to: directory, name: item.name) } }.value;result.succeeded+=1 }
            catch { result.failures.append(FilterImportFailure(item:item,message:item.url.lastPathComponent + "：" + error.localizedDescription)) }
            importCompleted+=1
        }
        reload()
        return result
    }
    func rename(_ entry: LUTEntry, to name: String) throws { _ = try LUTStorage.rename(entry, to: name, in: directory); reload() }
    func rename(_ entry: ImportedPhotoFilter, to name: String) throws { try PhotoFilterStorage.rename(entry,to:name,in:filtersDirectory);reload() }
    func remove(_ entry: ImportedPhotoFilter) throws {
        for url in [PhotoFilterStorage.file(entry,in:filtersDirectory),filtersDirectory.appendingPathComponent(entry.id+".json")] {
            if FileManager.default.fileExists(atPath:url.path) { try EditPersistence.rejectLinks(url);try FileManager.default.trashItem(at:url,resultingItemURL:nil) }
        }
        reload()
    }
    func remove(_ entry: LUTEntry) throws {
        let fm = FileManager.default
        try EditPersistence.rejectLinks(directory)
        for url in [LUTStorage.file(entry, in: directory), directory.appendingPathComponent(entry.id + ".json")] {
            if fm.fileExists(atPath: url.path) { try EditPersistence.rejectLinks(url); try fm.trashItem(at: url, resultingItemURL: nil) }
        }
        reload()
    }
}

struct LUTImportItem: Identifiable, Sendable {
    let id = UUID()
    let url: URL
    var name: String
}
struct FilterImportFailure:Sendable {let item:LUTImportItem;let message:String}
struct FilterImportResult:Sendable {var succeeded=0;var failures:[FilterImportFailure]=[]}
