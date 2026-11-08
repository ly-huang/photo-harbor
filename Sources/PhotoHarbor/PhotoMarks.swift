import Foundation

enum PhotoLabel:String,Codable,CaseIterable,Sendable {
    case orange="橙色",yellow="黄色",green="绿色",blue="蓝色",purple="紫色",gray="灰色"
}
struct PhotoAnnotation:Codable,Equatable,Sendable {
    var colors:Set<PhotoLabel>=[]
    var rejected=false
}
struct PhotoMarkRecord:Codable,Sendable {
    var version=1
    let filename:String
    let bytes:Int64
    let digest: String?
    var identity: String?
    var modified: Date?
    var colorUpdated: Date?
    var annotation:PhotoAnnotation
    var updated=Date()
}

enum PhotoMarkStorage {
    static func directory(_ file:PhotoFile)->URL{file.url.deletingLastPathComponent().appendingPathComponent(".photoharbor-marks",isDirectory:true)}
    static func url(_ file:PhotoFile)->URL{directory(file).appendingPathComponent(EditPersistence.hash(Data(file.url.lastPathComponent.utf8))+".json")}
    private static func checkFile(_ file: PhotoFile) throws {
        try EditPersistence.rejectLinks(file.url)
        try LibraryService.validateFileIdentity(file)
    }
    private static func read(_ file:PhotoFile)throws->(record: PhotoMarkRecord, data: Data)? {
        let target=url(file)
        guard FileManager.default.fileExists(atPath:target.path) else{return nil}
        try EditPersistence.rejectLinks(target)
        let size=try target.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? Int.max
        guard size<=16384 else{throw LibraryError.message("照片标记记录过大。")}
        let data = try Data(contentsOf: target)
        let record=try JSONDecoder().decode(PhotoMarkRecord.self,from:data)
        let digestValid = record.digest.map { $0.count == 64 && $0.allSatisfy(\.isHexDigit) } ?? false
        guard record.filename == file.url.lastPathComponent,
              (record.digest == nil || digestValid),
              (record.version == 1 && digestValid ||
               (2...3).contains(record.version) && record.identity != nil && record.modified != nil) else {
            throw LibraryError.message("照片标记记录无效。")
        }
        return (record, data)
    }
    struct DirectoryIndex {
        private var names: [URL: Set<String>] = [:]
        private var unavailable: Set<URL> = []

        mutating func load(_ photo: Photo, legacyRejected: Bool) throws -> PhotoAnnotation {
            // Legacy migration may create records, so always read directly for those photos.
            if legacyRejected { return try PhotoMarkStorage.load(photo, legacyRejected: true) }
            var candidates: Set<URL> = []
            for file in photo.files {
                let folder = directory(file)
                if names[folder] == nil, !unavailable.contains(folder) {
                    if !FileManager.default.fileExists(atPath: folder.path) {
                        names[folder] = []
                    } else {
                        do {
                            try EditPersistence.rejectLinks(folder)
                            let entries = try FileManager.default.contentsOfDirectory(atPath: folder.path)
                            names[folder] = Set(entries.map { $0.lowercased() })
                        } catch { unavailable.insert(folder) }
                    }
                }
                let target = url(file)
                if names[folder]?.contains(target.lastPathComponent.lowercased()) != false {
                    candidates.insert(file.url)
                }
            }
            return try PhotoMarkStorage.load(photo, candidates: candidates)
        }
    }
    static func load(_ photo:Photo,legacyRejected:Bool=false, candidates: Set<URL>? = nil)throws->PhotoAnnotation {
        var valid: [PhotoMarkRecord] = []
        var found = false
        for file in photo.files {
            if let candidates, !candidates.contains(file.url) { continue }
            guard let record = try read(file)?.record else { continue }
            found = true
            guard record.bytes == file.bytes else { continue }
            if record.version == 1 {
                // Older records have no file identity. Verify their original digest before trusting them.
                guard try EditPersistence.hash(file.url) == record.digest else { continue }
            } else {
                guard record.identity == file.identity, record.modified == file.modified else { continue }
            }
            try checkFile(file)
            valid.append(record)
        }
        if !found && legacyRejected {
            let migrated = PhotoAnnotation(rejected: true)
            try save(migrated, for: photo)
            return migrated
        }
        guard let latest = valid.max(by: { $0.updated < $1.updated }),
              valid.count == photo.files.count else { return PhotoAnnotation() }
        return latest.annotation
    }

    private struct PreparedMark: Sendable {
        let target: URL
        let data: Data
        let previous: Data?
    }

    private static func prepare(_ annotation: PhotoAnnotation, file: PhotoFile, date: Date) throws -> PreparedMark {
        try checkFile(file)
        let target = url(file)
        let previous = try read(file)
        let record = PhotoMarkRecord(version: 3, filename: file.url.lastPathComponent, bytes: file.bytes,
                                     digest: nil, identity: file.identity, modified: file.modified,
                                     annotation: annotation, updated: date)
        return PreparedMark(target: target, data: try JSONEncoder().encode(record), previous: previous?.data)
    }

    static func save(_ annotation: PhotoAnnotation, for photo: Photo) throws {
        let date = Date()
        try commit(photo, prepared: photo.files.map { try prepare(annotation, file: $0, date: date) })
    }

    static func savePair(_ annotation: PhotoAnnotation, for photo: Photo) async throws {
        let date = Date()
        let prepared = try await withThrowingTaskGroup(of: PreparedMark.self) { group in
            for file in photo.files {
                group.addTask { try prepare(annotation, file: file, date: date) }
            }
            var prepared: [PreparedMark] = []
            for try await item in group { prepared.append(item) }
            return prepared
        }
        try commit(photo, prepared: prepared)
    }

    private static func commit(_ photo: Photo, prepared: [PreparedMark]) throws {
        for file in photo.files{try checkFile(file)}
        var committed:[(URL,Data?)]=[]
        do {
            for item in prepared {
                let target = item.target
                let folder = target.deletingLastPathComponent()
                if !FileManager.default.fileExists(atPath: folder.path) {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                }
                try EditPersistence.rejectLinks(folder)
                if FileManager.default.fileExists(atPath:target.path){try EditPersistence.rejectLinks(target)}
                try item.data.write(to: target, options: .atomic)
                committed.append((target, item.previous))
            }
        } catch {
            // Cross-volume writes cannot be atomic; restore committed copies when possible.
            for (target,old) in committed.reversed(){if let old{try? old.write(to:target,options:.atomic)}else{try? FileManager.default.removeItem(at:target)}}
            throw error
        }
    }
    static func consumeRejection(_ file:PhotoFile)throws {
        guard var record=try read(file)?.record else{return}
        record.colorUpdated = record.colorUpdated ?? record.updated
        record.annotation.rejected=false;record.updated=Date()
        try JSONEncoder().encode(record).write(to:url(file),options:.atomic)
    }
}
