import Foundation

struct PhotoExport {
    enum Choice { case keepBoth, replace, skip }
    struct Target: Sendable { let url: URL; let fingerprint: String }
    static func fingerprint(_ url: URL) throws -> String {
        let values = try URL(fileURLWithPath: url.path).resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, canonicalURL(url).path == url.path else { throw LibraryError.message("目标不是普通文件或包含符号链接。") }
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return "\(attrs[.systemNumber] ?? ""):\(attrs[.systemFileNumber] ?? ""):\(try LibraryService.digest(url))"
    }
    static func destination(_ file: PhotoFile, folder: URL, separate: Bool) -> URL {
        (separate ? folder.appendingPathComponent(file.isRAW ? "RAW" : "JPG") : folder).appendingPathComponent(file.url.lastPathComponent)
    }
    static func reviewedTarget(_ url: URL) throws -> Target { Target(url: url, fingerprint: try fingerprint(url)) }
    static func copy(_ file: PhotoFile, to requested: URL, choice: Choice = .keepBoth, target: Target? = nil, protected: Set<URL>) throws -> URL? {
        if choice == .skip { return nil }
        let fm = FileManager.default
        guard canonicalURL(file.url).path == file.url.path else { throw LibraryError.message("来源路径已变化。") }
        let values = try URL(fileURLWithPath: file.url.path).resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
        let attrs = try fm.attributesOfItem(atPath: file.url.path)
        let identity = "\(attrs[.systemNumber] ?? ""):\(attrs[.systemFileNumber] ?? ""):\(attrs[.creationDate] ?? "")"
        guard values.isRegularFile == true, Int64(values.fileSize ?? 0) == file.bytes,
              values.contentModificationDate == file.modified, identity == file.identity else { throw LibraryError.message("来源文件已变化，请重新扫描：\(file.url.lastPathComponent)") }
        let sourceHash = try LibraryService.digest(file.url)
        let parent = requested.deletingLastPathComponent()
        guard canonicalURL(parent).path == parent.path else { throw LibraryError.message("目标目录包含符号链接。") }
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        guard canonicalURL(parent).path == parent.path else { throw LibraryError.message("目标目录已变化。") }
        var destination = requested
        if choice == .keepBoth {
            var index = 2
            while fm.fileExists(atPath: destination.path) || (try? destination.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                destination = parent.appendingPathComponent("\(requested.deletingPathExtension().lastPathComponent) (\(index)).\(requested.pathExtension)"); index += 1
            }
        }
        let temporary = parent.appendingPathComponent(".export-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: temporary) }
        try fm.copyItem(at: file.url, to: temporary)
        guard try LibraryService.digest(temporary) == sourceHash, try LibraryService.digest(file.url) == sourceHash else { throw LibraryError.message("来源变化或复制校验失败。") }
        guard canonicalURL(parent).path == parent.path else { throw LibraryError.message("目标目录已变化。") }
        if choice == .replace {
            guard let target, target.url == destination, try fingerprint(destination) == target.fingerprint else { throw LibraryError.message("冲突文件已变化，请重新导出并确认。") }
            let destAttrs = try fm.attributesOfItem(atPath: destination.path)
            for url in protected.union([file.url]) {
                if canonicalURL(url) == canonicalURL(destination) { throw LibraryError.message("不能替换来源文件，请保留两者或跳过。") }
                if let attrs = try? fm.attributesOfItem(atPath: url.path), String(describing: attrs[.systemNumber]) == String(describing: destAttrs[.systemNumber]), String(describing: attrs[.systemFileNumber]) == String(describing: destAttrs[.systemFileNumber]) { throw LibraryError.message("目标与来源为同一文件，不能替换。") }
            }
            _ = try fm.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try fm.moveItem(at: temporary, to: destination)
        }
        return destination
    }
}
