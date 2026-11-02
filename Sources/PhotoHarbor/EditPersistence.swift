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
    static func snapshot(_ url: URL) throws -> EditSnapshot {
        guard ["jpg", "jpeg"].contains(url.pathExtension.lowercased()) else { throw LibraryError.message("本版仅支持覆盖编辑 JPG。") }
        try rejectLinks(url)
        let a = try fm.attributesOfItem(atPath: url.path)
        guard a[.type] as? FileAttributeType == .typeRegular else { throw LibraryError.message("照片不是普通文件。") }
        let digest = try hash(url)
        let b = try fm.attributesOfItem(atPath: url.path)
        func identity(_ attributes: [FileAttributeKey: Any]) -> String {
            "\(attributes[.systemNumber] ?? "")|\(attributes[.systemFileNumber] ?? "")|\(attributes[.size] ?? "")|\(attributes[.modificationDate] ?? "")"
        }
        guard identity(a) == identity(b) else { throw LibraryError.message("读取期间照片已变化，请重新打开编辑。") }
        return EditSnapshot(digest: digest, identity: identity(b))
    }
    static func backupURL(_ url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(".photoharbor-originals", isDirectory: true)
            .appendingPathComponent(hash(Data(url.lastPathComponent.utf8)) + ".jpg")
    }
    private static func recordURL(_ url: URL) -> URL { backupURL(url).deletingPathExtension().appendingPathExtension("json") }
    static func record(_ url: URL, current: EditSnapshot) throws -> EditBackupRecord? {
        let backup = backupURL(url), manifest = recordURL(url)
        guard fm.fileExists(atPath: backup.path) || fm.fileExists(atPath: manifest.path) else { return nil }
        try rejectLinks(backup); try rejectLinks(manifest)
        let values = try fm.attributesOfItem(atPath: manifest.path)
        guard (values[.size] as? NSNumber)?.intValue ?? Int.max < 64 * 1024 else { throw LibraryError.message("编辑备份记录无效。") }
        let record = try JSONDecoder().decode(EditBackupRecord.self, from: Data(contentsOf: manifest))
        guard record.version == 1, record.fileName == url.lastPathComponent,
              try hash(backup) == record.originalDigest else { throw LibraryError.message("原图备份校验失败，操作已停止。") }
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
    @discardableResult static func save(_ data: Data, to url: URL, expected: EditSnapshot) throws -> EditSnapshot {
        try validateJPEG(data)
        guard try snapshot(url) == expected else { throw LibraryError.message("照片已在外部修改，请重新打开编辑。") }
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
        guard var manifest = try record(url, current: expected) else { throw LibraryError.message("还没有原图备份。") }
        let data = try Data(contentsOf: backupURL(url))
        try validateJPEG(data)
        return try publish(data, to: url, expected: expected, record: &manifest)
    }
    private static func publish(_ data: Data, to url: URL, expected: EditSnapshot, record: inout EditBackupRecord) throws -> EditSnapshot {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".photoharbor-edit-" + UUID().uuidString)
        defer { try? fm.removeItem(at: temporary) }
        try data.write(to: temporary, options: .withoutOverwriting)
        guard try hash(temporary) == hash(data) else { throw LibraryError.message("编辑临时文件校验失败。") }
        if let mode = try fm.attributesOfItem(atPath: url.path)[.posixPermissions] { try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: temporary.path) }
        record.pendingDigest = hash(data)
        try writeRecord(record, for: url)
        guard try snapshot(url) == expected else { throw LibraryError.message("保存前照片已变化，操作已停止。") }
        try rejectLinks(temporary)
        guard rename(temporary.path, url.path) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        record.savedDigest = record.pendingDigest!; record.pendingDigest = nil
        // If this last metadata write fails, the persisted pending digest still
        // identifies the completed image and allows a later save/restore to recover.
        try? writeRecord(record, for: url)
        return try snapshot(url)
    }
}
