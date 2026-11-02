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
    let digest:String
    var annotation:PhotoAnnotation
    var updated=Date()
}

enum PhotoMarkStorage {
    static func directory(_ file:PhotoFile)->URL{file.url.deletingLastPathComponent().appendingPathComponent(".photoharbor-marks",isDirectory:true)}
    static func url(_ file:PhotoFile)->URL{directory(file).appendingPathComponent(EditPersistence.hash(Data(file.url.lastPathComponent.utf8))+".json")}
    private static func checkFile(_ file:PhotoFile)throws {
        try EditPersistence.rejectLinks(file.url)
        let a=try FileManager.default.attributesOfItem(atPath:file.url.path)
        let identity="\(a[.systemNumber] ?? ""):\(a[.systemFileNumber] ?? ""):\(a[.creationDate] ?? "")"
        guard a[.type] as? FileAttributeType == .typeRegular,identity==file.identity,(a[.size] as? NSNumber)?.int64Value==file.bytes,a[.modificationDate] as? Date==file.modified else{throw LibraryError.message("照片已变化，请重新扫描后再设置标记。")}
    }
    private static func read(_ file:PhotoFile)throws->PhotoMarkRecord? {
        let target=url(file)
        guard FileManager.default.fileExists(atPath:target.path) else{return nil}
        try EditPersistence.rejectLinks(target)
        let size=try target.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? Int.max
        guard size<=16384 else{throw LibraryError.message("照片标记记录过大。")}
        let record=try JSONDecoder().decode(PhotoMarkRecord.self,from:Data(contentsOf:target))
        guard record.version==1,record.filename==file.url.lastPathComponent,record.digest.count==64,record.digest.allSatisfy(\.isHexDigit) else{throw LibraryError.message("照片标记记录无效。")}
        return record
    }
    static func load(_ photo:Photo,legacyRejected:Bool=false)throws->PhotoAnnotation {
        var records:[PhotoMarkRecord]=[],mismatch=false,found=false
        for file in photo.files {
            guard let record=try read(file) else{continue};found=true
            guard record.bytes==file.bytes else{mismatch=true;continue}
            try checkFile(file);let digest=try EditPersistence.hash(file.url);try checkFile(file)
            guard record.digest==digest else{mismatch=true;continue};records.append(record)
        }
        if !found && legacyRejected {
            let migrated=PhotoAnnotation(rejected:true);try save(migrated,for:photo);return migrated
        }
        var result=records.max{$0.updated<$1.updated}?.annotation ?? PhotoAnnotation()
        // Any changed member invalidates a pair's destructive flag, even when RAW is unchanged.
        if mismatch{result.rejected=false}
        return result
    }
    static func save(_ annotation:PhotoAnnotation,for photo:Photo)throws {
        var prepared:[(URL,Data,Data?)]=[]
        let date=Date()
        for file in photo.files {
            try checkFile(file);let digest=try EditPersistence.hash(file.url);try checkFile(file)
            let folder=directory(file),target=url(file)
            if FileManager.default.fileExists(atPath:folder.path){try EditPersistence.rejectLinks(folder)}
            else{try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:false);try EditPersistence.rejectLinks(folder)}
            var old:Data?
            if FileManager.default.fileExists(atPath:target.path){_ = try read(file);old=try Data(contentsOf:target)}
            let record=PhotoMarkRecord(filename:file.url.lastPathComponent,bytes:file.bytes,digest:digest,annotation:annotation,updated:date)
            prepared.append((target,try JSONEncoder().encode(record),old))
        }
        for file in photo.files{try checkFile(file)}
        var committed:[(URL,Data?)]=[]
        do {
            for (target,data,old) in prepared {
                try EditPersistence.rejectLinks(target.deletingLastPathComponent())
                if FileManager.default.fileExists(atPath:target.path){try EditPersistence.rejectLinks(target)}
                try data.write(to:target,options:.atomic);committed.append((target,old))
            }
        } catch {
            // Cross-volume writes cannot be atomic; restore committed copies when possible.
            for (target,old) in committed.reversed(){if let old{try? old.write(to:target,options:.atomic)}else{try? FileManager.default.removeItem(at:target)}}
            throw error
        }
    }
    static func consumeRejection(_ file:PhotoFile)throws {
        guard var record=try read(file) else{return}
        record.annotation.rejected=false;record.updated=Date()
        try JSONEncoder().encode(record).write(to:url(file),options:.atomic)
    }
}
