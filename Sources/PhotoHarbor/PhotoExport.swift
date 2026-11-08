import Foundation
import Darwin

struct PhotoExport {
    enum Choice { case keepBoth, replace, skip }
    struct Target: Sendable { let url: URL; let fingerprint: String }
    struct Protection: Sendable {
        let paths: Set<URL>
        private let byFoldedPath: [String: [URL]]
        private let byIdentity: [String: [URL]]

        init(_ paths: Set<URL>) {
            self.init(paths: Set(paths.map(canonicalURL)), byIdentity: [:])
        }

        init(files: [PhotoFile]) {
            var identities: [String: [URL]] = [:]
            for file in files {
                let parts = file.identity.split(separator: ":", maxSplits: 2)
                if parts.count == 3 {
                    identities["\(parts[0]):\(parts[1])", default: []].append(file.url)
                }
            }
            self.init(paths: Set(files.map(\.url)), byIdentity: identities)
        }

        private init(paths: Set<URL>, byIdentity: [String: [URL]]) {
            self.paths = paths
            self.byIdentity = byIdentity
            byFoldedPath = Dictionary(grouping: paths, by: { $0.path.lowercased() })
        }

        func verify(_ destination: URL, source: URL, info: stat) throws {
            guard destination != source, !paths.contains(destination) else {
                throw LibraryError.message("不能替换来源文件，请保留两者或跳过。")
            }
            // Single-link files cannot alias a different managed path via a hard link.
            // Check case variants on every volume and verify live identities for hard links.
            let identity = "\(info.st_dev):\(info.st_ino)"
            var candidates: Set<URL> = [source]
            candidates.formUnion(byFoldedPath[destination.path.lowercased(), default: []])
            candidates.formUnion(byIdentity[identity, default: []])
            if info.st_nlink != 1 || info.st_ino == 0 { candidates.formUnion(paths) }
            for url in candidates {
                var candidate = stat()
                if fstatat(AT_FDCWD, url.path, &candidate, 0) == 0,
                   candidate.st_dev == info.st_dev, candidate.st_ino == info.st_ino {
                    throw LibraryError.message("目标与来源为同一文件，不能替换。")
                }
            }
        }
    }

    private static func fileInfo(_ url: URL) throws -> stat {
        var info = stat()
        guard canonicalURL(url).path == url.path, lstat(url.path, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG else {
            throw LibraryError.message("目标不是普通文件或包含符号链接。")
        }
        return info
    }
    private static func fingerprint(_ info: stat) -> String {
        let modified = info.st_mtimespec
        let changed = info.st_ctimespec
        return "\(info.st_dev):\(info.st_ino):\(info.st_size):\(modified.tv_sec):\(modified.tv_nsec):\(changed.tv_sec):\(changed.tv_nsec)"
    }
    static func destination(_ file: PhotoFile, folder: URL, separate: Bool) -> URL {
        (separate ? folder.appendingPathComponent(file.isRAW ? "RAW" : "JPG") : folder).appendingPathComponent(file.url.lastPathComponent)
    }
    static func reviewedTarget(_ url: URL) throws -> Target { Target(url: url, fingerprint: fingerprint(try fileInfo(url))) }
    static func copy(_ file: PhotoFile, to requested: URL, choice: Choice = .keepBoth, target: Target? = nil, protected: Set<URL>) throws -> URL? {
        try copy(file, to: requested, choice: choice, target: target, protection: Protection(protected))
    }
    static func copy(_ file: PhotoFile, to requested: URL, choice: Choice, target: Target?, protection: Protection) throws -> URL? {
        if choice == .skip { return nil }
        let fm = FileManager.default
        guard canonicalURL(file.url).path == file.url.path else { throw LibraryError.message("来源路径已变化。") }
        let sourceVersion = fingerprint(try fileInfo(file.url))
        try LibraryService.validateFileIdentity(file)
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
        let sourceHash = try LibraryService.streamPhotoCopy(file.url, to: temporary)
        guard try LibraryService.digest(temporary) == sourceHash else {
            throw LibraryError.message("复制校验失败。")
        }
        guard fingerprint(try fileInfo(file.url)) == sourceVersion, canonicalURL(parent).path == parent.path else {
            throw LibraryError.message("来源文件或目标目录已变化。")
        }
        if choice == .replace {
            let info = try fileInfo(destination)
            guard let target, target.url == destination, fingerprint(info) == target.fingerprint else {
                throw LibraryError.message("冲突文件已变化，请重新导出并确认。")
            }
            try protection.verify(destination, source: file.url, info: info)
            guard fingerprint(try fileInfo(destination)) == target.fingerprint else {
                throw LibraryError.message("冲突文件已变化，请重新导出并确认。")
            }
            _ = try fm.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try fm.moveItem(at: temporary, to: destination)
        }
        return destination
    }
}
