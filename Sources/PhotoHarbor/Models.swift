import Foundation
import ImageIO
import Darwin

func canonicalURL(_ url: URL) -> URL {
    guard let path = realpath(url.path, nil) else { return url.standardizedFileURL }
    defer { free(path) }
    return URL(fileURLWithPath: String(cString: path))
}

struct Roots: Codable, Equatable, Sendable {
    var jpg = ""
    var raw = ""
    var urls: [URL] { [jpg, raw].filter { !$0.isEmpty }.map { canonicalURL(URL(fileURLWithPath: $0)) } }
    var jpgURL: URL? { jpg.isEmpty ? nil : canonicalURL(URL(fileURLWithPath: jpg)) }
    var rawURL: URL? { raw.isEmpty ? nil : canonicalURL(URL(fileURLWithPath: raw)) }
    static func importDestinations(jpg: String, raw: String) -> Roots {
        guard !jpg.isEmpty, !raw.isEmpty, canonicalURL(URL(fileURLWithPath: jpg)) == canonicalURL(URL(fileURLWithPath: raw)) else { return Roots(jpg: jpg, raw: raw) }
        let parent = URL(fileURLWithPath: jpg)
        return Roots(jpg: parent.appendingPathComponent("JPG").path, raw: parent.appendingPathComponent("RAW").path)
    }
    func validate(allowMissing: Bool = false) throws {
        guard !jpg.isEmpty || !raw.isEmpty else { throw LibraryError.message("请至少选择一个 JPG 或 RAW 目录。") }
        let paths = urls.map(\.path)
        if paths.count == 2, paths[0] == paths[1] || paths[0].hasPrefix(paths[1] + "/") || paths[1].hasPrefix(paths[0] + "/") {
            throw LibraryError.message("两个根目录必须不同，且不能互相包含。")
        }
        for url in urls {
            if allowMissing && !FileManager.default.fileExists(atPath: url.path) {
                var ancestor = url.deletingLastPathComponent()
                while !FileManager.default.fileExists(atPath: ancestor.path), ancestor.path != "/" { ancestor.deleteLastPathComponent() }
                let values = try ancestor.resourceValues(forKeys: [.isDirectoryKey, .isReadableKey, .isWritableKey])
                guard values.isDirectory == true, values.isReadable == true, values.isWritable == true else { throw LibraryError.message("无法创建目标目录：\(url.path)") }
                continue
            }
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isReadableKey])
            guard values.isDirectory == true, values.isReadable == true else { throw LibraryError.message("目录不可访问：\(url.path)。请检查硬盘连接和权限。") }
        }
    }
}

enum LibraryError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let message) = self { return message }; return nil }
}

struct PhotoFile: Hashable, Sendable {
    let url: URL
    let relative: String
    let bytes: Int64
    let modified: Date
    let identity: String
    var stem: String { url.deletingPathExtension().lastPathComponent.lowercased() }
    var relativeStem: String { (relative as NSString).deletingPathExtension.lowercased() }
    var isRAW: Bool { url.pathExtension.lowercased() == "arw" }
}

struct Photo: Identifiable, Sendable {
    let files: [PhotoFile]
    var ambiguous = false
    var albumID = ""
    // Persist marks against this specific file generation, never just a reused camera name.
    let id: String
    init(files: [PhotoFile], ambiguous: Bool = false, albumID: String = "") {
        self.files = files
        self.ambiguous = ambiguous
        self.albumID = albumID
        id = files.map { "\($0.url.path)|\($0.identity)|\($0.bytes)|\($0.modified.timeIntervalSince1970)" }.sorted().joined(separator: "\n")
    }
    var name: String { files[0].url.deletingPathExtension().lastPathComponent }
    var previewFile: PhotoFile { files.first(where: { !$0.isRAW }) ?? files[0] }
    var preview: URL { previewFile.url }
    var paired: Bool { files.count == 2 && !ambiguous }
    var album: String {
        let directory = (files[0].relative as NSString).deletingLastPathComponent
        return directory.isEmpty ? "未分类" : directory
    }
    var bytes: Int64 { files.reduce(0) { $0 + $1.bytes } }
}

struct Metadata: Sendable {
    var date: Date?
    var camera = "未知相机"
    var dimensions = ""
    var exposure = ""
    var shooting = ""
    var gps = ""
    var place = ""
    var latitude: Double?
    var longitude: Double?
    static func captureDateFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter
    }

    static func read(_ url: URL, importFormatter: DateFormatter? = nil) -> Metadata {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else { return Metadata() }
        let exif = p[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        let tiff = p[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        let gps = p[kCGImagePropertyGPSDictionary as String] as? [String: Any] ?? [:]
        var result = Metadata()
        let iptc = p[kCGImagePropertyIPTCDictionary as String] as? [String: Any] ?? [:]
        result.place = ["City", "SubLocation"].compactMap { iptc[$0] as? String }.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.joined(separator: "")
        if let lat = gps[kCGImagePropertyGPSLatitude as String] as? NSNumber,
           let lon = gps[kCGImagePropertyGPSLongitude as String] as? NSNumber {
            result.latitude = abs(lat.doubleValue) * ((gps[kCGImagePropertyGPSLatitudeRef as String] as? String) == "S" ? -1 : 1)
            result.longitude = abs(lon.doubleValue) * ((gps[kCGImagePropertyGPSLongitudeRef as String] as? String) == "W" ? -1 : 1)
        }
        if let value = exif[kCGImagePropertyExifDateTimeOriginal as String] as? String ?? tiff[kCGImagePropertyTIFFDateTime as String] as? String {
            result.date = (importFormatter ?? captureDateFormatter()).date(from: value)
        }
        if importFormatter != nil { return result }
        result.camera = tiff[kCGImagePropertyTIFFModel as String] as? String ?? "未知相机"
        if let w = p[kCGImagePropertyPixelWidth as String], let h = p[kCGImagePropertyPixelHeight as String] { result.dimensions = "\(w) × \(h)" }
        if let f = exif[kCGImagePropertyExifFNumber as String] { result.exposure = "ƒ/\(f)" }
        var shooting: [String] = []
        if let seconds = (exif[kCGImagePropertyExifExposureTime as String] as? NSNumber)?.doubleValue, seconds > 0 { shooting.append(seconds < 1 ? "1/\(Int((1 / seconds).rounded()))s" : "\(seconds)s") }
        if let iso = (exif[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber])?.first { shooting.append("ISO \(iso)") }
        if let focal = exif[kCGImagePropertyExifFocalLength as String] { shooting.append("\(focal)mm") }
        result.shooting = shooting.joined(separator: " · ")
        if let lat = gps[kCGImagePropertyGPSLatitude as String], let lon = gps[kCGImagePropertyGPSLongitude as String] { result.gps = "\(lat)° \(gps[kCGImagePropertyGPSLatitudeRef as String] ?? "")  \(lon)° \(gps[kCGImagePropertyGPSLongitudeRef as String] ?? "")" }
        return result
    }
}

struct ImportItem: Identifiable, Sendable {
    let source: URL
    var destination: URL
    let bytes: Int64
    let fallbackDate: Bool
    var pairID: String? = nil
    var conflicts = false
    var conflictVersion: String? = nil
    var replacement: String? = nil
    var id: String { source.path }
}
struct TrashRecord: Codable, Sendable { let original: URL; let trashed: URL }
struct OpenAlbum: Codable, Identifiable, Equatable, Sendable {
    var id = UUID().uuidString
    var title: String
    var roots: Roots
    init(roots: Roots, title: String? = nil) {
        self.roots = Roots(jpg: roots.jpgURL?.path ?? "", raw: roots.rawURL?.path ?? "")
        let urls = self.roots.urls
        let names = urls.map(\.lastPathComponent)
        self.title = title?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? (names.count == 2 && names[0] != names[1] ? urls[0].deletingLastPathComponent().lastPathComponent : names.first ?? "相册")
    }
}
private extension String { var nonEmpty: String? { isEmpty ? nil : self } }
struct DeletionBatch: Codable, Identifiable, Sendable {
    var id = UUID().uuidString
    let albumID: String
    var date = Date()
    var records: [TrashRecord] = []
}
struct SavedState: Codable {
    var roots = Roots()
    var rejected: Set<String> = []
    var albums: [OpenAlbum] = []
    var deletionBatches: [DeletionBatch] = []
    init() {}
    enum CodingKeys: String, CodingKey { case roots, rejected, trash, albums, deletionBatches }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        roots = try values.decodeIfPresent(Roots.self, forKey: .roots) ?? Roots()
        rejected = try values.decodeIfPresent(Set<String>.self, forKey: .rejected) ?? []
        albums = try values.decodeIfPresent([OpenAlbum].self, forKey: .albums) ?? []
        deletionBatches = try values.decodeIfPresent([DeletionBatch].self, forKey: .deletionBatches) ?? []
        if !values.contains(.albums), !roots.urls.isEmpty {
            let album = OpenAlbum(roots: roots); albums = [album]
            let legacy = try values.decodeIfPresent([TrashRecord].self, forKey: .trash) ?? []
            if !legacy.isEmpty { deletionBatches.append(DeletionBatch(albumID: album.id, records: legacy)) }
        }
    }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(roots, forKey: .roots)
        try values.encode(rejected, forKey: .rejected)
        try values.encode(albums, forKey: .albums)
        try values.encode(deletionBatches, forKey: .deletionBatches)
    }
    mutating func pruneHistory(availableAlbumIDs: Set<String>) {
        for i in deletionBatches.indices {
            deletionBatches[i].records.removeAll { !FileManager.default.fileExists(atPath: $0.trashed.path) }
        }
        deletionBatches.removeAll { !availableAlbumIDs.contains($0.albumID) || $0.records.isEmpty }
    }
}
func readableBytes(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
