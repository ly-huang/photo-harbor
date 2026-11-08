import Foundation
import CryptoKit
import ImageIO
import Darwin

struct EditSnapshot: Equatable, Sendable {
    let digest: String
    let identity: String
}

struct EditBackupRecord: Codable {
    var version = 1
    let fileName: String
    let originalDigest: String
    var savedDigest: String
    var pendingDigest: String?
    func recognizes(_ digest: String) -> Bool { digest == savedDigest || digest == pendingDigest }
}

enum EditPersistence {
    private static let fm = FileManager.default
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func hash(_ url: URL) throws -> String { try LibraryService.digest(url).map { String(format: "%02x", $0) }.joined() }
    static func rejectLinks(_ url: URL) throws {
        guard url.isFileURL else { throw LibraryError.message("仅支持本地文件。") }
        var path = url.path
        while path != "/", !path.isEmpty {
            var info = stat()
            guard lstat(path, &info) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            if info.st_mode & S_IFMT == S_IFLNK { throw LibraryError.message("编辑目录不能包含符号链接：\((path as NSString).lastPathComponent)") }
            path = (path as NSString).deletingLastPathComponent
        }
    }
    static func fileVersion(_ url: URL) throws -> String {
        guard ["jpg", "jpeg"].contains(url.pathExtension.lowercased()) else { throw LibraryError.message("本版仅支持覆盖编辑 JPG。") }
        return version(try fileInfo(url))
    }
    private static func fileInfo(_ url: URL) throws -> stat {
        try rejectLinks(url)
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            throw LibraryError.message("照片不是可访问的普通文件。")
        }
        return info
    }
    private static func renameIdentity(_ info: stat) -> String {
        let modified = info.st_mtimespec
        return "\(info.st_dev)|\(info.st_ino)|\(info.st_size)|\(modified.tv_sec)|\(modified.tv_nsec)"
    }
    private static func version(_ info: stat) -> String {
        let changed = info.st_ctimespec
        return "\(renameIdentity(info))|\(changed.tv_sec)|\(changed.tv_nsec)"
    }
    static func snapshot(_ url: URL) throws -> EditSnapshot {
        let version = try fileVersion(url)
        let digest = try hash(url)
        guard try fileVersion(url) == version else { throw LibraryError.message("读取期间照片已变化，请重新打开编辑。") }
        return EditSnapshot(digest: digest, identity: version)
    }
    static func readSource(_ url: URL) throws -> (Data, EditSnapshot) {
        let version = try fileVersion(url)
        let data = try Data(contentsOf: url)
        let digest = hash(data)
        guard try fileVersion(url) == version else { throw LibraryError.message("读取期间照片已变化，请重新打开编辑。") }
        return (data, EditSnapshot(digest: digest, identity: version))
    }
    static func backupURL(_ url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(".photoharbor-originals", isDirectory: true)
            .appendingPathComponent(hash(Data(url.lastPathComponent.utf8)) + ".jpg")
    }
    private static func recordURL(_ url: URL) -> URL { backupURL(url).deletingPathExtension().appendingPathExtension("json") }
    static func record(_ url: URL, current: EditSnapshot) throws -> EditBackupRecord? {
        guard let record = try readRecord(url, current: current) else { return nil }
        guard try hash(backupURL(url)) == record.originalDigest else {
            throw LibraryError.message("原图备份校验失败，操作已停止。")
        }
        return record
    }
    private static func readRecord(_ url: URL, current: EditSnapshot) throws -> EditBackupRecord? {
        let backup = backupURL(url), manifest = recordURL(url)
        guard fm.fileExists(atPath: backup.path) || fm.fileExists(atPath: manifest.path) else { return nil }
        try rejectLinks(backup); try rejectLinks(manifest)
        let values = try fm.attributesOfItem(atPath: manifest.path)
        guard (values[.size] as? NSNumber)?.intValue ?? Int.max < 64 * 1024 else { throw LibraryError.message("编辑备份记录无效。") }
        let record = try JSONDecoder().decode(EditBackupRecord.self, from: Data(contentsOf: manifest))
        guard record.version == 1, record.fileName == url.lastPathComponent else { throw LibraryError.message("原图备份校验失败，操作已停止。") }
        guard record.recognizes(current.digest) else { throw LibraryError.message("JPG 已被其他程序修改，原图备份与当前版本不匹配；请另存新名称后编辑。") }
        return record
    }
    private static func writeRecord(_ record: EditBackupRecord, for url: URL) throws {
        let path = recordURL(url)
        if fm.fileExists(atPath: path.path) { try rejectLinks(path) }
        try JSONEncoder().encode(record).write(to: path, options: .atomic)
    }
    private static func validateJPEG(_ data: Data) throws {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetType(source) as String? == "public.jpeg",
              CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else { throw LibraryError.message("生成的 JPG 无法解码，原图未修改。") }
    }
    @discardableResult static func save(_ data: Data, to url: URL, expected: EditSnapshot, renderedFrom source: EditSnapshot? = nil) throws -> EditSnapshot {
        try validateJPEG(data)
        let current = try source ?? snapshot(url)
        guard current == expected, try fileVersion(url) == expected.identity else {
            throw LibraryError.message("照片已在外部修改，请重新打开编辑。")
        }
        let backup = backupURL(url), directory = backup.deletingLastPathComponent()
        if fm.fileExists(atPath: directory.path) { try rejectLinks(directory) }
        else { try fm.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        var manifest: EditBackupRecord
        if let existing = try record(url, current: expected) { manifest = existing }
        else {
            // A backup must be complete and verified before any overwrite is permitted.
            try fm.copyItem(at: url, to: backup)
            guard try hash(backup) == expected.digest else { throw LibraryError.message("原图备份失败，照片未覆盖。") }
            manifest = EditBackupRecord(fileName: url.lastPathComponent, originalDigest: expected.digest, savedDigest: expected.digest)
            try writeRecord(manifest, for: url)
        }
        return try publish(data, to: url, expected: expected, record: &manifest)
    }
    @discardableResult static func restore(_ url: URL, expected: EditSnapshot) throws -> EditSnapshot {
        guard try snapshot(url) == expected else { throw LibraryError.message("照片已在外部修改，无法还原。") }
        guard var manifest = try readRecord(url, current: expected) else { throw LibraryError.message("还没有原图备份。") }
        let data = try Data(contentsOf: backupURL(url))
        guard hash(data) == manifest.originalDigest else {
            throw LibraryError.message("原图备份校验失败，操作已停止。")
        }
        try validateJPEG(data)
        return try publish(data, to: url, expected: expected, record: &manifest)
    }
    private static func publish(_ data: Data, to url: URL, expected: EditSnapshot, record: inout EditBackupRecord) throws -> EditSnapshot {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".photoharbor-edit-" + UUID().uuidString)
        defer { try? fm.removeItem(at: temporary) }
        try data.write(to: temporary, options: .withoutOverwriting)
        let digest = hash(data)
        if let mode = try fm.attributesOfItem(atPath: url.path)[.posixPermissions] { try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: temporary.path) }
        let staged = try fileInfo(temporary)
        guard try hash(temporary) == digest else { throw LibraryError.message("编辑临时文件校验失败。") }
        record.pendingDigest = digest
        try writeRecord(record, for: url)
        guard try snapshot(url) == expected else { throw LibraryError.message("保存前照片已变化，操作已停止。") }
        guard version(try fileInfo(temporary)) == version(staged) else {
            throw LibraryError.message("编辑临时文件已变化，操作已停止。")
        }
        guard rename(temporary.path, url.path) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let published = try fileInfo(url)
        let result: EditSnapshot
        if staged.st_ino != 0, renameIdentity(staged) == renameIdentity(published) {
            result = EditSnapshot(digest: digest, identity: version(published))
        } else {
            result = try snapshot(url)
            guard result.digest == digest else { throw LibraryError.message("发布后的 JPG 已变化。") }
        }
        record.savedDigest = digest; record.pendingDigest = nil
        // If this last metadata write fails, the persisted pending digest still
        // identifies the completed image and allows a later save/restore to recover.
        try? writeRecord(record, for: url)
        return result
    }
}
