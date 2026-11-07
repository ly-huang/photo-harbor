import XCTest
import ImageIO
import CoreGraphics
@testable import PhotoHarbor

final class LibraryServiceTests: XCTestCase {
    func testFilteredExport() throws {
        let jpg = try file("source/A.JPG", content: "new jpg")
        _ = try file("source/A.ARW", content: "raw")
        let files = try LibraryService.scanFiles(jpg.deletingLastPathComponent(), extensions: ["jpg", "arw"])
        let protected = Set(files.map(\.url))
        let output = base.appendingPathComponent("new/output")
        for item in files {
            let dest = PhotoExport.destination(item, folder: output, separate: true)
            _ = try PhotoExport.copy(item, to: dest, protected: protected)
            XCTAssertEqual(try Data(contentsOf: dest), try Data(contentsOf: item.url))
        }
        let item = files.first { !$0.isRAW }!
        let dest = PhotoExport.destination(item, folder: output, separate: false)
        _ = try file("new/output/A.JPG", content: "old")
        let reviewed = try PhotoExport.reviewedTarget(dest)
        XCTAssertEqual(try PhotoExport.copy(item, to: dest, choice: .skip, protected: protected), nil)
        let renamed = try PhotoExport.copy(item, to: dest, protected: protected)!
        XCTAssertEqual(renamed.lastPathComponent, "A (2).JPG")
        XCTAssertEqual(try String(contentsOf: dest, encoding: .utf8), "old")
        _ = try PhotoExport.copy(item, to: dest, choice: .replace, target: reviewed, protected: protected)
        XCTAssertEqual(try Data(contentsOf: dest), try Data(contentsOf: jpg))
        XCTAssertThrowsError(try PhotoExport.copy(item, to: dest, choice: .replace, target: reviewed, protected: protected))
        let own = try PhotoExport.reviewedTarget(jpg)
        XCTAssertThrowsError(try PhotoExport.copy(item, to: jpg, choice: .replace, target: own, protected: protected))
        let link = base.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: output)
        XCTAssertThrowsError(try PhotoExport.copy(item, to: link.appendingPathComponent("A.JPG"), protected: protected))
        _ = try file("source/A.JPG", content: "changed source")
        XCTAssertThrowsError(try PhotoExport.copy(item, to: dest, protected: protected))
    }
    var base: URL!
    override func setUpWithError() throws {
        base = canonicalURL(FileManager.default.temporaryDirectory).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: base) }
    func directory(_ path: String) throws -> URL {
        let url = base.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    func file(_ path: String, content: String = "photo") throws -> URL {
        let url = base.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url)
        return url
    }
    func roots() throws -> Roots { Roots(jpg: try directory("jpg").path, raw: try directory("raw").path) }
    func testRelativePairsStayWithinAlbumDespiteRepeatedNames() throws {
        let roots = try roots()
        for album in ["a", "b"] {
            _ = try file("jpg/\(album)/DSC001.JPG"); _ = try file("raw/\(album)/DSC001.ARW")
        }
        let photos = try LibraryService.scan(roots)
        XCTAssertEqual(photos.count, 2)
        XCTAssertTrue(photos.allSatisfy(\.paired))
        try LibraryService.validateDeletion(photos, roots: roots)
        XCTAssertTrue(photos.allSatisfy { Set($0.files.map { ($0.relative as NSString).deletingLastPathComponent }).count == 1 })
    }
    func testUniqueFallbackAndAmbiguousDuplicates() throws {
        let roots = try roots()
        _ = try file("jpg/one/A.JPG"); _ = try file("raw/other/A.ARW")
        _ = try file("jpg/one/B.JPG"); _ = try file("jpg/two/B.JPG"); _ = try file("raw/three/B.ARW")
        let photos = try LibraryService.scan(roots)
        XCTAssertEqual(photos.filter(\.paired).count, 1)
        XCTAssertEqual(photos.filter(\.ambiguous).count, 3)
        XCTAssertThrowsError(try LibraryService.validateDeletion(photos.filter(\.ambiguous), roots: roots))
    }
    func testNestedAndDisconnectedRootsRejected() throws {
        let root = try directory("library")
        let nested = try directory("library/raw")
        XCTAssertThrowsError(try Roots(jpg: root.path, raw: nested.path).validate())
        XCTAssertThrowsError(try Roots(jpg: root.path, raw: base.appendingPathComponent("missing").path).validate())
    }
    func testNewCounterpartAndChangedFileBlockDeletion() throws {
        let roots = try roots()
        _ = try file("jpg/a/A.JPG")
        let initial = try LibraryService.scan(roots)
        _ = try file("raw/a/A.ARW")
        XCTAssertThrowsError(try LibraryService.validateDeletion(initial, roots: roots))
        let paired = try LibraryService.scan(roots)
        _ = try file("jpg/a/A.JPG", content: "changed content")
        XCTAssertThrowsError(try LibraryService.validateDeletion(paired, roots: roots))
    }
    func testSymlinksAreSkipped() throws {
        let roots = try roots()
        let target = try file("outside/A.JPG")
        try FileManager.default.createSymbolicLink(at: URL(fileURLWithPath: roots.jpg).appendingPathComponent("A.JPG"), withDestinationURL: target)
        XCTAssertTrue(try LibraryService.scan(roots).isEmpty)
    }
    func testPlanAlignsPairDateAndRefusesCollision() throws {
        let roots = try roots(); let source = try directory("source")
        let jpg = try file("source/A.JPG"); let raw = try file("source/A.ARW")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1700000000)], ofItemAtPath: jpg.path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1600000000)], ofItemAtPath: raw.path)
        let plan = try LibraryService.importPlan(source: source, roots: roots, location: "杭州西湖")
        XCTAssertEqual(plan.count, 2)
        XCTAssertEqual(plan[0].destination.deletingLastPathComponent().lastPathComponent, plan[1].destination.deletingLastPathComponent().lastPathComponent)
        XCTAssertTrue(plan.allSatisfy(\.fallbackDate))
        for item in plan { try LibraryService.copyVerified(item); XCTAssertEqual(try Data(contentsOf: item.source), try Data(contentsOf: item.destination)) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: jpg.path))
        XCTAssertThrowsError(try LibraryService.importPlan(source: source, roots: roots, location: "杭州西湖"))
        let conflicts = try LibraryService.importPlan(source: source, roots: roots, location: "杭州西湖", allowExisting: true)
        XCTAssertTrue(conflicts.allSatisfy(\.conflicts))
        XCTAssertEqual(try LibraryService.resolveImportConflicts(conflicts, choice: .skip).count, 0)

        let retained = try LibraryService.resolveImportConflicts(conflicts, choice: .keepBoth)
        XCTAssertEqual(retained.count, 2)
        for item in retained {
            XCTAssertEqual(item.destination.deletingPathExtension().lastPathComponent, "A (2)")
            try LibraryService.copyVerified(item)
        }
        let replacement = try LibraryService.resolveImportConflicts(conflicts, choice: .replace)
        try Data("new source".utf8).write(to: jpg)
        let jpgItem = replacement.first { $0.source == jpg }!
        let rawItem = replacement.first { $0.source == raw }!
        try Data("changed destination".utf8).write(to: rawItem.destination)
        XCTAssertThrowsError(try LibraryService.copyVerified(rawItem))
        XCTAssertEqual(try String(contentsOf: rawItem.destination, encoding: .utf8), "changed destination")
        XCTAssertThrowsError(try LibraryService.resolveImportConflicts(conflicts, choice: .replace))
        try LibraryService.copyVerified(jpgItem)
        XCTAssertEqual(try String(contentsOf: jpgItem.destination, encoding: .utf8), "new source")
        XCTAssertEqual(try String(contentsOf: jpg, encoding: .utf8), "new source")

    }
    func testStreamingImportPreservesBytesAndMetadata() throws {
        let source = try file("source/large.ARW")
        let destination = base.appendingPathComponent("target/large.ARW")
        var payload = Data(repeating: 0x21, count: 4 * 1024 * 1024)
        payload.append(Data(repeating: 0x9b, count: 257))
        try payload.write(to: source)
        let modified = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: modified, .posixPermissions: 0o640], ofItemAtPath: source.path)
        try LibraryService.copyVerified(ImportItem(source: source, destination: destination, bytes: Int64(payload.count), fallbackDate: false))
        XCTAssertEqual(try Data(contentsOf: destination), payload)
        XCTAssertEqual(try Data(contentsOf: source), payload)
        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        XCTAssertEqual(attributes[.modificationDate] as? Date, modified)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o640)
    }

    func testCopyNeverOverwritesAndRejectsSymlinkParent() throws {
        let source = try file("source/A.JPG")
        let dest = try file("target/A.JPG", content: "original")
        XCTAssertThrowsError(try LibraryService.copyVerified(ImportItem(source: source, destination: dest, bytes: 5, fallbackDate: false)))
        XCTAssertEqual(try String(contentsOf: dest, encoding: .utf8), "original")
        let elsewhere = try directory("elsewhere")
        let link = base.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: elsewhere)
        XCTAssertThrowsError(try LibraryService.copyVerified(ImportItem(source: source, destination: link.appendingPathComponent("A.JPG"), bytes: 5, fallbackDate: false)))
    }
    func testRestoreRefusesOverwrite() throws {
        let original = try file("jpg/A.JPG", content: "new")
        let trashed = try file("fake-trash/A.JPG", content: "old")
        XCTAssertThrowsError(try LibraryService.restore(TrashRecord(original: original, trashed: trashed)))
        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "new")
    }
    func testDuplicateImportDestinationsRejectedBeforeCopy() throws {
        let roots = try roots(); let source = try directory("source")
        _ = try file("source/one/A.JPG"); _ = try file("source/one/A.ARW")
        _ = try file("source/two/A.JPG"); _ = try file("source/two/A.ARW")
        XCTAssertThrowsError(try LibraryService.importPlan(source: source, roots: roots, location: "上海"))
        XCTAssertTrue(try LibraryService.scan(roots).isEmpty)
    }
    func testEXIFDateOverridesModificationDate() throws {
        let roots = try roots(); let source = try directory("source")
        let jpg = source.appendingPathComponent("A.JPG")
        let context = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let destination = CGImageDestinationCreateWithURL(jpg as CFURL, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, [kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2020:02:03 10:15:00"]] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        _ = try file("source/A.ARW")
        let plan = try LibraryService.importPlan(source: source, roots: roots, location: "西湖")
        XCTAssertEqual(plan.count, 2)
        XCTAssertTrue(plan.allSatisfy { $0.destination.path.contains("/20200203_西湖/") && !$0.fallbackDate })
    }
    func testReusedPathDoesNotInheritRejection() throws {
        let roots = try roots()
        let original = try file("jpg/A.JPG", content: "first")
        let initial = try LibraryService.scan(roots)
        let timestamp = initial[0].files[0].modified
        let replacement = try file("jpg/B.JPG", content: "other")
        try FileManager.default.removeItem(at: original)
        try FileManager.default.moveItem(at: replacement, to: original)
        try FileManager.default.setAttributes([.modificationDate: timestamp], ofItemAtPath: original.path)
        let current = try LibraryService.scan(roots)
        XCTAssertTrue(initial[0].id != current[0].id)
        XCTAssertThrowsError(try LibraryService.validateDeletion(initial, roots: roots))
    }
    func testOptionalPlaceAndNewRootsPreviewDoesNotWrite() throws {
        let source = try directory("source")
        _ = try file("source/JPG/A.JPG"); _ = try file("source/ARW/A.ARW")
        let roots = Roots(jpg: base.appendingPathComponent("JPG").path, raw: base.appendingPathComponent("RAW").path)
        let plan = try LibraryService.importPlan(source: source, roots: roots, location: "  ")
        XCTAssertEqual(plan.count, 2)
        XCTAssertTrue(plan.allSatisfy { $0.destination.deletingLastPathComponent().lastPathComponent.hasSuffix("_未知") })
        XCTAssertTrue(!FileManager.default.fileExists(atPath: roots.jpg))
        for item in plan { try LibraryService.copyVerified(item) }
        XCTAssertEqual(try LibraryService.scan(roots).filter(\.paired).count, 1)
        XCTAssertThrowsError(try LibraryService.importPlan(source: source, roots: Roots(jpg: source.appendingPathComponent("new/JPG").path, raw: roots.raw), location: ""))
    }
    func testEmbeddedPlaceAndGPSFallbackPriority() throws {
        let roots = try roots(); let source = try directory("source")
        let jpg = source.appendingPathComponent("A.JPG")
        let context = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let dest = CGImageDestinationCreateWithURL(jpg as CFURL, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, context.makeImage()!, [
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2025:05:04 10:00:00"],
            kCGImagePropertyIPTCDictionary: ["City": "杭州", "SubLocation": "西湖"],
            kCGImagePropertyGPSDictionary: ["Latitude": 30.2, "LatitudeRef": "N", "Longitude": 120.1, "LongitudeRef": "E"]
        ] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        _ = try file("source/A.ARW")
        let detected = try LibraryService.importPlan(source: source, roots: roots, location: "", resolvedPlaces: [jpg.path: "其他地点"])
        XCTAssertTrue(detected.allSatisfy { $0.destination.deletingLastPathComponent().lastPathComponent == "20250504_杭州西湖" })
        let manual = try LibraryService.importPlan(source: source, roots: roots, location: "手动地点")
        XCTAssertTrue(manual.allSatisfy { $0.destination.deletingLastPathComponent().lastPathComponent == "20250504_手动地点" })
        XCTAssertEqual(Metadata.read(jpg).latitude, 30.2)
        _ = try file("source/B.JPG")
        let gps = try LibraryService.importPlan(source: source, roots: roots, location: "", resolvedPlaces: [source.appendingPathComponent("B.JPG").path: "上海/浦东"])
        XCTAssertTrue(gps.contains { $0.destination.deletingLastPathComponent().lastPathComponent.hasSuffix("_上海 浦东") })
    }
    func testSingleFormatAlbumsAndSharedImportDestination() throws {
        let jpg = try directory("jpg-only")
        let raw = try directory("raw-only")
        _ = try file("jpg-only/A.JPG"); _ = try file("raw-only/B.ARW")
        XCTAssertEqual(try LibraryService.scan(Roots(jpg: jpg.path)).count, 1)
        XCTAssertEqual(try LibraryService.scan(Roots(raw: raw.path)).count, 1)
        XCTAssertThrowsError(try Roots().validate())
        let source = try directory("source")
        _ = try file("source/A.JPG"); _ = try file("source/A.ARW")
        let target = base.appendingPathComponent("shared")
        let plan = try LibraryService.importPlan(source: source, roots: Roots(jpg: target.path, raw: target.path), location: "西湖")
        XCTAssertTrue(plan.contains { $0.destination.path.hasPrefix(target.appendingPathComponent("JPG").path + "/") })
        XCTAssertTrue(plan.contains { $0.destination.path.hasPrefix(target.appendingPathComponent("RAW").path + "/") })
        for item in plan { try LibraryService.copyVerified(item) }
        XCTAssertEqual(try LibraryService.scan(Roots.importDestinations(jpg: target.path, raw: target.path)).filter(\.paired).count, 1)
    }
    func testLegacyStateAndHistoryExpiry() throws {
        let roots = try roots()
        let original = base.appendingPathComponent("jpg/A.JPG")
        let trashed = try file("fake-trash/A.JPG")
        let legacy: [String: Any] = ["roots": ["jpg": roots.jpg, "raw": roots.raw], "rejected": [], "trash": [["original": original.absoluteString, "trashed": trashed.absoluteString]]]
        var state = try JSONDecoder().decode(SavedState.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertEqual(state.albums.count, 1)
        XCTAssertEqual(state.deletionBatches.count, 1)
        let albumID = state.albums[0].id
        let missing = TrashRecord(original: original, trashed: base.appendingPathComponent("missing"))
        state.deletionBatches.append(DeletionBatch(albumID: albumID, records: [missing]))
        state.pruneHistory(availableAlbumIDs: [albumID])
        XCTAssertEqual(state.deletionBatches.count, 1)
        state.pruneHistory(availableAlbumIDs: [])
        XCTAssertTrue(state.deletionBatches.isEmpty)
        state.albums = []
        let roundtrip = try JSONDecoder().decode(SavedState.self, from: JSONEncoder().encode(state))
        XCTAssertTrue(roundtrip.albums.isEmpty)
    }
}
