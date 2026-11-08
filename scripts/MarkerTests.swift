import Foundation

@main struct MarkerTests {
    static func require(_ value:@autoclosure () throws->Bool) rethrows{let result=try value();precondition(result)}
    static func mustFail(_ work:()throws->Void){do{try work();preconditionFailure("Unsafe mark accepted")}catch{}}
    static func main()throws {
        let fm=FileManager.default,temporary=fm.temporaryDirectory.appendingPathComponent("PhotoHarborMarks-"+UUID().uuidString)
        try fm.createDirectory(at:temporary,withIntermediateDirectories:true);let root=canonicalURL(temporary)
        defer{try? fm.removeItem(at:root)}
        let jpg=root.appendingPathComponent("JPG"),raw=root.appendingPathComponent("RAW")
        try fm.createDirectory(at:jpg,withIntermediateDirectories:true);try fm.createDirectory(at:raw,withIntermediateDirectories:true)
        let j=jpg.appendingPathComponent("A.JPG"),r=raw.appendingPathComponent("A.ARW")
        let jBytes=Data("synthetic JPEG marker fixture".utf8),rBytes=Data("synthetic RAW marker fixture".utf8)
        try jBytes.write(to:j);try rBytes.write(to:r)
        var photo=try LibraryService.scan(Roots(jpg:jpg.path,raw:raw.path))[0]
        let annotation=PhotoAnnotation(colors:[.orange,.purple],rejected:true)
        try PhotoMarkStorage.save(annotation,for:photo)
        try require(PhotoMarkStorage.load(photo)==annotation)
        for file in photo.files {
            let path = PhotoMarkStorage.url(file)
            let record = try JSONDecoder().decode(PhotoMarkRecord.self, from: Data(contentsOf: path))
            precondition(record.version == 3 && record.digest == nil)
            let old = PhotoMarkRecord(version: 2, filename: record.filename, bytes: record.bytes,
                                      digest: String(repeating: "0", count: 64), identity: record.identity,
                                      modified: record.modified, annotation: annotation)
            try JSONEncoder().encode(old).write(to: path)
        }
        try require(PhotoMarkStorage.load(photo) == annotation)
        try require(Data(contentsOf:j)==jBytes && Data(contentsOf:r)==rBytes)
        precondition(photo.files.allSatisfy{fm.fileExists(atPath:PhotoMarkStorage.url($0).path)})
        let moved=root.appendingPathComponent("Moved");try fm.createDirectory(at:moved,withIntermediateDirectories:true)
        try fm.moveItem(at:jpg,to:moved.appendingPathComponent("JPG"));try fm.moveItem(at:raw,to:moved.appendingPathComponent("RAW"))
        let roots=Roots(jpg:moved.appendingPathComponent("JPG").path,raw:moved.appendingPathComponent("RAW").path)
        photo=try LibraryService.scan(roots)[0]
        try require(PhotoMarkStorage.load(photo)==annotation)
        let jpeg=photo.files.first{!$0.isRAW}!,rawFile=photo.files.first{$0.isRAW}!
        var replacement=jBytes;replacement[0]=UInt8(ascii:"X");try replacement.write(to:jpeg.url)
        photo=try LibraryService.scan(roots)[0]
        try require(PhotoMarkStorage.load(photo) == PhotoAnnotation())
        try jBytes.write(to:jpeg.url);photo=try LibraryService.scan(roots)[0]
        try PhotoMarkStorage.save(annotation,for:photo)
        let trash=root.appendingPathComponent("trash.JPG")
        try fm.moveItem(at:jpeg.url,to:trash)
        try PhotoMarkStorage.consumeRejection(jpeg)
        try PhotoMarkStorage.consumeRejection(rawFile)
        try fm.moveItem(at:trash,to:jpeg.url);photo=try LibraryService.scan(roots)[0]
        let restored=try PhotoMarkStorage.load(photo)
        precondition(!restored.rejected && restored.colors==annotation.colors)
        print("PASS paired portable marks, directory move, unchanged originals, same-name replacement safety and consumed delete flag on restore")
        let rawFolder=PhotoMarkStorage.directory(rawFile),saved=root.appendingPathComponent("saved-marks")
        try fm.moveItem(at:rawFolder,to:saved)
        let outside=root.appendingPathComponent("outside");try fm.createDirectory(at:outside,withIntermediateDirectories:true)
        try fm.createSymbolicLink(at:rawFolder,withDestinationURL:outside)
        let jpgMark=PhotoMarkStorage.url(photo.files.first{!$0.isRAW}!),before=try Data(contentsOf:jpgMark)
        mustFail{try PhotoMarkStorage.save(PhotoAnnotation(colors:[.blue]),for:photo)}
        try require(Data(contentsOf:jpgMark)==before)
        try require(fm.contentsOfDirectory(atPath:outside.path).isEmpty)
        try fm.removeItem(at:rawFolder);try fm.moveItem(at:saved,to:rawFolder)
        for file in photo.files{try fm.removeItem(at:PhotoMarkStorage.url(file))}
        let migrated=try PhotoMarkStorage.load(photo,legacyRejected:true)
        precondition(migrated.rejected && photo.files.allSatisfy{fm.fileExists(atPath:PhotoMarkStorage.url($0).path)})
        for file in photo.files {
            let record = try JSONDecoder().decode(PhotoMarkRecord.self, from: Data(contentsOf: PhotoMarkStorage.url(file)))
            precondition(record.digest == nil && record.identity == file.identity)
        }
        try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 10)], ofItemAtPath: jpeg.url.path)
        let changed = try LibraryService.scan(roots)[0]
        try require(!PhotoMarkStorage.load(changed).rejected)
        try Data("broken".utf8).write(to:jpgMark)
        mustFail{_ = try PhotoMarkStorage.load(photo)}
        print("PASS symlink destination rejection with untouched paired record, legacy migration and corrupt-record rejection")
    }
}
