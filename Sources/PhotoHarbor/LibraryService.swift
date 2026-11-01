import Foundation
import CryptoKit
import CoreLocation

struct LibraryService {
    static let manager = FileManager.default
    static func scanFiles(_ root: URL, extensions: Set<String>) throws -> [PhotoFile] {
        let root = canonicalURL(root)
        var failure: Error?
        guard let iterator = manager.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey], options: [.skipsHiddenFiles], errorHandler: { _, error in failure = error; return false }) else { throw LibraryError.message("无法读取目录：\(root.path)") }
        var files: [PhotoFile] = []
        for case let enumeratedURL as URL in iterator {
            let url = enumeratedURL
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
            if values.isSymbolicLink == true { iterator.skipDescendants(); continue }
            guard values.isRegularFile == true, extensions.contains(url.pathExtension.lowercased()) else { continue }
            let attributes = try manager.attributesOfItem(atPath: url.path)
            let identity = "\(attributes[.systemNumber] ?? ""):\(attributes[.systemFileNumber] ?? ""):\(attributes[.creationDate] ?? "")"
            files.append(PhotoFile(url: url, relative: String(url.path.dropFirst(root.path.count + 1)), bytes: Int64(values.fileSize ?? 0), modified: values.contentModificationDate ?? .distantPast, identity: identity))
        }
        if let failure { throw failure }
        return files.sorted { $0.relative.localizedStandardCompare($1.relative) == .orderedAscending }
    }
    static func scan(_ roots: Roots) throws -> [Photo] {
        try roots.validate()
        return pair(jpg: try roots.jpgURL.map { try scanFiles($0, extensions: ["jpg", "jpeg"]) } ?? [], raw: try roots.rawURL.map { try scanFiles($0, extensions: ["arw"]) } ?? [])
    }
    static func pair(jpg: [PhotoFile], raw: [PhotoFile]) -> [Photo] {
        let jRelative = Dictionary(grouping: jpg, by: \.relativeStem)
        let rRelative = Dictionary(grouping: raw, by: \.relativeStem)
        var consumed = Set<URL>(); var output: [Photo] = []
        for key in jRelative.keys.sorted() {
            if let j = jRelative[key], j.count == 1, let r = rRelative[key], r.count == 1 {
                output.append(Photo(files: j + r)); (j + r).forEach { consumed.insert($0.url) }
            }
        }
        let remaining = (jpg + raw).filter { !consumed.contains($0.url) }
        let grouped = Dictionary(grouping: remaining, by: \.stem)
        for key in grouped.keys.sorted() {
            let group = grouped[key]!
            let j = group.filter { !$0.isRAW }; let r = group.filter(\.isRAW)
            if j.count == 1 && r.count == 1 { output.append(Photo(files: j + r)) }
            else { output += group.map { Photo(files: [$0], ambiguous: group.count > 1) } }
        }
        return output.sorted { $0.files[0].relative.localizedStandardCompare($1.files[0].relative) == .orderedAscending }
    }
    static func importPlan(source: URL, roots: Roots, location: String, resolvedPlaces: [String: String] = [:]) throws -> [ImportItem] {
        let roots = Roots.importDestinations(jpg: roots.jpg, raw: roots.raw)
        try roots.validate(allowMissing: true)
        let source = canonicalURL(source)
        for root in roots.urls {
            guard source != root, !source.path.hasPrefix(root.path + "/"), !root.path.hasPrefix(source.path + "/") else { throw LibraryError.message("来源与照片库目录不能相同或互相包含。") }
        }
        let place = location.trimmingCharacters(in: .whitespacesAndNewlines)
        guard place != ".", place != "..", !place.contains("/"), !place.contains(":"), !place.contains("\n") else { throw LibraryError.message("地点不能包含斜杠、冒号或换行。") }
        let files = try scanFiles(source, extensions: ["jpg", "jpeg", "arw"])
        let photos = pair(jpg: files.filter { !$0.isRAW }, raw: files.filter(\.isRAW))
        let day = DateFormatter(); day.locale = Locale(identifier: "en_US_POSIX"); day.dateFormat = "yyyyMMdd"
        var plan: [ImportItem] = []; var destinations = Set<String>()
        for photo in photos {
            guard !photo.ambiguous else { throw LibraryError.message("来源中存在无法配对的同名照片：\(photo.name)。请先分批导入或重命名。") }
            let metadata = photo.files.sorted { !$0.isRAW && $1.isRAW }.map { Metadata.read($0.url) }
            let captureDate = metadata.compactMap(\.date).first
            let date = captureDate ?? photo.files.first(where: { !$0.isRAW })?.modified ?? photo.files[0].modified
            let detected = metadata.map(\.place).first(where: { !$0.isEmpty }) ?? resolvedPlaces[photo.preview.path] ?? "未知"
            let folderPlace = place.isEmpty ? safePlace(detected) : place
            for file in photo.files {
                guard let root = file.isRAW ? roots.rawURL : roots.jpgURL else { throw LibraryError.message("来源包含\(file.isRAW ? "RAW" : "JPG") 文件，请设置对应的导入位置。") }
                let dest = root.appendingPathComponent("\(day.string(from: date))_\(folderPlace)").appendingPathComponent(file.url.lastPathComponent)
                guard destinations.insert(dest.path.lowercased()).inserted, !manager.fileExists(atPath: dest.path) else { throw LibraryError.message("目标文件重名，未执行导入：\(dest.path)") }
                plan.append(ImportItem(source: file.url, destination: dest, bytes: file.bytes, fallbackDate: captureDate == nil))
            }
        }
        return plan
    }
    static func safePlace(_ value: String) -> String {
        let cleaned = value.components(separatedBy: CharacterSet(charactersIn: "/:\\").union(.controlCharacters)).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty || cleaned == "." || cleaned == ".." ? "未知" : String(cleaned.prefix(80))
    }
    static func importPlanResolvingPlaces(source: URL, roots: Roots, location: String) async throws -> [ImportItem] {
        // Validate paths/collisions before attempting any network lookup.
        _ = try importPlan(source: source, roots: roots, location: location)
        if !location.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return try importPlan(source: source, roots: roots, location: location) }
        let files = try scanFiles(source, extensions: ["jpg", "jpeg", "arw"])
        let photos = pair(jpg: files.filter { !$0.isRAW }, raw: files.filter(\.isRAW))
        var places: [String: String] = [:], cache: [String: String] = [:]
        var lookupUnavailable = false
        for photo in photos {
            let metadata = photo.files.map { Metadata.read($0.url) }
            guard !metadata.contains(where: { !$0.place.isEmpty }),
                  let gps = metadata.first(where: { $0.latitude != nil && $0.longitude != nil }),
                  let lat = gps.latitude, let lon = gps.longitude,
                  CLLocationCoordinate2DIsValid(CLLocationCoordinate2D(latitude: lat, longitude: lon)) else { continue }
            let key = String(format: "%.2f,%.2f", lat, lon)
            if let cached = cache[key] { places[photo.preview.path] = cached; continue }
            if lookupUnavailable { continue }
            let geocoder = CLGeocoder()
            let timeout = Task { try? await Task.sleep(nanoseconds: 8_000_000_000); if !Task.isCancelled { geocoder.cancelGeocode() } }
            defer { timeout.cancel() }
            do {
                let marks = try await geocoder.reverseGeocodeLocation(CLLocation(latitude: lat, longitude: lon), preferredLocale: Locale(identifier: "zh_CN"))
                let mark = marks.first
                let name = [mark?.locality ?? mark?.administrativeArea, mark?.subLocality].compactMap { $0 }.joined()
                cache[key] = name.isEmpty ? "未知" : name
                places[photo.preview.path] = cache[key]
            } catch { lookupUnavailable = true }
        }
        return try importPlan(source: source, roots: roots, location: location, resolvedPlaces: places)
    }
    static func digest(_ url: URL) throws -> SHA256.Digest {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty { hash.update(data: chunk) }
        return hash.finalize()
    }
    static func copyVerified(_ item: ImportItem) throws {
        let parent = item.destination.deletingLastPathComponent()
        try manager.createDirectory(at: parent, withIntermediateDirectories: true)
        // Recheck resolved destination to prevent following symlinked album folders.
        guard canonicalURL(parent).path == parent.path else { throw LibraryError.message("目标包含符号链接，停止导入。") }
        let temporary = parent.appendingPathComponent(".import-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: temporary) }
        try manager.copyItem(at: item.source, to: temporary)
        guard try digest(item.source) == digest(temporary) else { throw LibraryError.message("文件校验失败：\(item.source.lastPathComponent)") }
        // moveItem fails if a destination already exists; never overwrite.
        try manager.moveItem(at: temporary, to: item.destination)
    }
    static func validateDeletion(_ photos: [Photo], roots: Roots) throws {
        let fresh = try scan(roots)
        let byID = Dictionary(uniqueKeysWithValues: fresh.map { ($0.id, $0) })
        for photo in photos {
            guard !photo.ambiguous, let current = byID[photo.id], !current.ambiguous, Set(current.files) == Set(photo.files) else { throw LibraryError.message("文件或配对关系已变化：\(photo.name)。请重新扫描后检查。") }
            for file in photo.files {
                guard canonicalURL(file.url).path == file.url.path else { throw LibraryError.message("文件路径已变为符号链接，停止删除。") }
            }
        }
    }
    static func trash(_ file: PhotoFile) throws -> TrashRecord {
        var result: NSURL?
        try manager.trashItem(at: file.url, resultingItemURL: &result)
        guard let result else { throw LibraryError.message("系统未返回废纸篓位置：\(file.url.path)") }
        return TrashRecord(original: file.url, trashed: result as URL)
    }
    static func restore(_ record: TrashRecord) throws {
        guard !manager.fileExists(atPath: record.original.path) else { throw LibraryError.message("恢复目标已存在，未覆盖：\(record.original.path)") }
        try manager.createDirectory(at: record.original.deletingLastPathComponent(), withIntermediateDirectories: true)
        try manager.moveItem(at: record.trashed, to: record.original)
    }
}
