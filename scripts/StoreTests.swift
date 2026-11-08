import Foundation
import AppKit

@main struct StoreTests {
    @MainActor static func wait(_ store: LibraryStore) async throws {
        for _ in 0..<500 {
            if !store.busy { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw LibraryError.message("Store test timed out")
    }
    @MainActor static func main() async throws {
        let base = canonicalURL(FileManager.default.temporaryDirectory).appendingPathComponent("PhotoHarborStore-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        func file(_ path: String) throws -> URL {
            let url = base.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("fixture".utf8).write(to: url)
            return url
        }
        let thumbnailURL = try file("thumbnail/sample.JPG")
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
                                      samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB,
                                      bytesPerRow: 0, bitsPerPixel: 0)!
        for x in 0..<2 { for y in 0..<2 { bitmap.setColor(.red, atX: x, y: y) } }
        try bitmap.representation(using: .jpeg, properties: [:])!.write(to: thumbnailURL)
        let thumbnail = try LibraryService.scanFiles(thumbnailURL.deletingLastPathComponent(), extensions: ["jpg"])[0]
        let thumbnails = ImageCache()
        thumbnails.queue.isSuspended = true
        let oldRequest = Task { await thumbnails.load(thumbnail, size: 32, priority: .high) }
        for _ in 0..<100 {
            if thumbnails.queue.operationCount > 0 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        precondition(thumbnails.queue.operationCount == 1)
        oldRequest.cancel()
        thumbnails.queue.isSuspended = false
        let cancelledImage = await oldRequest.value
        precondition(cancelledImage == nil && thumbnails.cache.object(forKey: "\(thumbnail.url.path):32:\(thumbnail.identity):\(thumbnail.bytes):\(thumbnail.modified.timeIntervalSince1970)" as NSString) == nil)
        let currentImage = await thumbnails.load(thumbnail, size: 32, priority: .high)
        precondition(currentImage != nil)
        try FileManager.default.removeItem(at: thumbnailURL)
        let reusedImage = await thumbnails.load(thumbnail, size: 32, priority: .high)
        precondition(reusedImage === currentImage)
        print("PASS thumbnail queue skips cancelled pending requests and reuses completed images")
        let a = try file("first/A.JPG"); let b = try file("second/B.ARW")
        let store = LibraryStore(stateURL: base.appendingPathComponent("state.json"))
        try store.applyRoots(Roots(jpg: a.deletingLastPathComponent().path), title: "第一本")
        try await wait(store)
        let first = store.state.albums[0]
        let addedWhileOpen = try file("first/later.JPG")
        try store.applyRoots(Roots(raw: b.deletingLastPathComponent().path), title: "第二本")
        try await wait(store)
        let second = store.state.albums[1]
        precondition(store.albums.count == 2 && store.photos.count == 2)
        precondition(store.photos.first { $0.albumID == second.id }?.files.first?.isRAW == true)
        let reopened = LibraryStore(stateURL: store.stateURL)
        reopened.scanOnLaunch()
        try await wait(reopened)
        precondition(reopened.photos.contains { $0.preview == addedWhileOpen })
        reopened.scanOnLaunch()
        precondition(!reopened.busy)
        try FileManager.default.removeItem(at: addedWhileOpen)
        print("PASS append independent JPG-only and RAW-only albums")
        _ = try file("archive/JPG/20241115_未知/A.JPG")
        _ = try file("archive/RAW/20241115_未知/A.ARW")
        _ = try file("archive/JPG/20241116_未知/A.JPG")
        _ = try file("archive/RAW/20241117_未知/A.ARW")
        let archive = Roots(jpg: base.appendingPathComponent("archive/JPG").path,
                            raw: base.appendingPathComponent("archive/RAW").path)
        let groupedStore = LibraryStore(stateURL: base.appendingPathComponent("grouped-state.json"))
        try groupedStore.applyRoots(archive)
        try await wait(groupedStore)
        let aggregate = groupedStore.albums[0]
        do {
            try await groupedStore.applyAlbumFolders(archive)
            preconditionFailure("An open parent must prevent duplicate registration")
        } catch is LibraryError {}
        precondition(groupedStore.albums == [aggregate])
        groupedStore.closeAlbum(aggregate.id)
        try await groupedStore.applyAlbumFolders(archive)
        try await wait(groupedStore)
        precondition(groupedStore.albums.map(\.title) == ["20241115_未知", "20241116_未知", "20241117_未知"])
        precondition(groupedStore.photos.count == 3 && groupedStore.photos.filter(\.paired).count == 1)
        let rawOnly = groupedStore.photos.first { $0.files.count == 1 && $0.files[0].isRAW }
        precondition(rawOnly?.preview.pathExtension == "ARW" && rawOnly?.paired == false)
        let serialArchive = try LibraryService.scan(archive)
        let parallelArchive = try await LibraryService.scanForBrowsing(archive, parallelFormats: true)
        precondition(parallelArchive.map(\.id) == serialArchive.map(\.id))
        let albumIDs = groupedStore.albums.map(\.id)
        try await groupedStore.applyAlbumFolders(archive)
        try await wait(groupedStore)
        precondition(groupedStore.albums.map(\.id) == albumIDs)
        print("PASS opening archive folders pairs within named subfolders and prevents overlapping or duplicate albums")
        groupedStore.album = nil
        let batch = groupedStore.photos
        groupedStore.setLabel(.blue, enabled: true, for: batch)
        try await wait(groupedStore)
        precondition(batch.allSatisfy { groupedStore.labels(for: $0) == [.blue] })
        groupedStore.setRejected(true, for: batch)
        try await wait(groupedStore)
        precondition(groupedStore.rejected.count == 3)
        precondition(batch.allSatisfy { groupedStore.labels(for: $0) == [.blue] })
        groupedStore.deleteRejected(permanently: true)
        try await wait(groupedStore)
        precondition(groupedStore.error == nil && groupedStore.photos.isEmpty && groupedStore.undoBatches.isEmpty)
        precondition(batch.flatMap(\.files).allSatisfy { !FileManager.default.fileExists(atPath: $0.url.path) })
        print("PASS bulk color and deletion marks persist independently and direct deletion processes the batch")
        let compareA = store.photos[0], compareB = store.photos[1]
        store.toggleComparison(compareA); store.toggleComparison(compareB)
        precondition(store.comparisonPhotos.count == 2)
        store.toggleComparison(compareA)
        precondition(store.comparisonPhotos.count == 1)
        store.toggleComparison(compareA)
        precondition(store.comparisonPhotos.map(\.id) == [compareB.id, compareA.id])
        _ = try file("first/C.JPG"); _ = try file("first/D.JPG"); _ = try file("first/E.JPG")
        store.scan(); try await wait(store)
        let others = store.photos.filter { $0.id != compareA.id && $0.id != compareB.id }
        store.toggleComparison(others[0]); store.toggleComparison(others[1])
        precondition(store.comparisonPhotos.count == 4)
        let four = store.comparisonSelection
        store.toggleComparison(others[2])
        precondition(store.comparisonSelection == four)
        store.toggleComparison(others[0]); store.toggleComparison(others[1])
        precondition(store.comparisonPhotos.count == 2)
        print("PASS ordered four-photo comparison, deselection and fifth-photo limit")
        let photoIDsBeforeClear = store.photos.map(\.id)
        let rejectedBeforeClear = store.state.rejected
        store.clearComparisonSelection()
        precondition(store.comparisonSelection.isEmpty && store.comparisonPhotos.isEmpty)
        precondition(store.photos.map(\.id) == photoIDsBeforeClear && store.state.rejected == rejectedBeforeClear)
        precondition(FileManager.default.fileExists(atPath: a.path) && FileManager.default.fileExists(atPath: b.path))
        store.toggleComparison(compareA); store.toggleComparison(compareB)
        precondition(store.comparisonPhotos.map(\.id) == [compareA.id, compareB.id])
        print("PASS clear comparison selection preserves photos and marks; selection can be rebuilt")

        let untouchedAddition = try file("second/later.ARW")
        store.album = first.id
        store.toggleReject(compareA)
        try await wait(store)
        store.deleteRejected { _ in ([:], "没有移动权限") }
        try await wait(store)
        precondition(store.error != nil && store.status.contains("未能"))
        precondition(store.rejected.map(\.id) == [compareA.id] && store.undoBatches.isEmpty)
        precondition(FileManager.default.fileExists(atPath: a.path))
        precondition(!store.photos.contains { $0.preview == untouchedAddition })
        store.error = nil
        store.toggleReject(compareA)
        try await wait(store)
        try FileManager.default.removeItem(at: untouchedAddition)
        print("PASS failed trash unlocks controls, retains the mark and does not rescan unrelated albums")

        let pairedJPG = try file("partial/jpg/P.JPG")
        let pairedRAW = try file("partial/raw/P.ARW")
        let trashCopy = base.appendingPathComponent("partial/P.JPG")
        let partialStore = LibraryStore(stateURL: base.appendingPathComponent("partial-state.json"))
        try partialStore.applyRoots(Roots(jpg: pairedJPG.deletingLastPathComponent().path,
                                          raw: pairedRAW.deletingLastPathComponent().path))
        try await wait(partialStore)
        partialStore.toggleReject(partialStore.photos[0])
        try await wait(partialStore)
        let firstMember = partialStore.photos[0].files[0].url
        partialStore.deleteRejected { urls in
            precondition(Set(urls) == [pairedJPG, pairedRAW])
            try! FileManager.default.moveItem(at: firstMember, to: trashCopy)
            return ([firstMember: trashCopy], "另一份文件未移动")
        }
        try await wait(partialStore)
        precondition(partialStore.undoBatches.first?.records.count == 1)
        precondition(partialStore.rejected.count == 1 && partialStore.rejected[0].files.count == 1)
        partialStore.undoTrash()
        try await wait(partialStore)
        precondition(partialStore.photos.count == 1 && partialStore.photos[0].paired)
        print("PASS partial trash retains the remaining file and restores the moved member")

        partialStore.toggleReject(partialStore.photos[0])
        try await wait(partialStore)
        try Data("replacement".utf8).write(to: pairedRAW)
        partialStore.deleteRejected(permanently: true)
        try await wait(partialStore)
        precondition(partialStore.error != nil && partialStore.undoBatches.isEmpty)
        precondition(FileManager.default.fileExists(atPath: pairedJPG.path))
        precondition(FileManager.default.fileExists(atPath: pairedRAW.path))
        partialStore.error = nil
        partialStore.scan()
        try await wait(partialStore)
        partialStore.toggleReject(partialStore.photos[0])
        try await wait(partialStore)
        partialStore.deleteRejected(permanently: true)
        try await wait(partialStore)
        precondition(partialStore.error == nil && partialStore.undoBatches.isEmpty && partialStore.photos.isEmpty)
        precondition(!FileManager.default.fileExists(atPath: pairedJPG.path))
        precondition(!FileManager.default.fileExists(atPath: pairedRAW.path))
        print("PASS direct deletion checks both members before removing either and creates no undo record")

        let chosen = try file("context/CHOSEN.JPG")
        let markedNeighbor = try file("context/KEEP.JPG")
        let contextStore = LibraryStore(stateURL: base.appendingPathComponent("context-state.json"))
        try contextStore.applyRoots(Roots(jpg: chosen.deletingLastPathComponent().path, raw: ""))
        try await wait(contextStore)
        let chosenPhoto = contextStore.photos.first { $0.preview == chosen }!
        let untouchedPhoto = contextStore.photos.first { $0.preview == markedNeighbor }!
        let initialIDs = contextStore.visibleIDs
        contextStore.setRejected(true, for: [untouchedPhoto])
        try await wait(contextStore)
        precondition(contextStore.visibleIDs == initialIDs)
        contextStore.filter = "待删除"
        precondition(contextStore.visibleIDs == [untouchedPhoto.id])
        contextStore.deletePhotos([chosenPhoto], permanently: true, completion: { error in
            precondition(error == nil)
        })
        try await wait(contextStore)
        precondition(contextStore.visibleIDs == [untouchedPhoto.id] && contextStore.photos.count == 1)
        precondition(!FileManager.default.fileExists(atPath: chosen.path))
        precondition(FileManager.default.fileExists(atPath: markedNeighbor.path))
        print("PASS contextual deletion targets only the chosen photo regardless of the rejected filter")

        let one = try file("trash/one.JPG"), two = try file("trash/two.JPG")
        let stale = base.appendingPathComponent("trash/gone.JPG")
        let originalOne = a.deletingLastPathComponent().appendingPathComponent("one.JPG")
        let originalTwo = a.deletingLastPathComponent().appendingPathComponent("two.JPG")
        let batch1 = DeletionBatch(albumID: first.id, records: [TrashRecord(original: originalOne, trashed: one)])
        let batch2 = DeletionBatch(albumID: first.id, records: [TrashRecord(original: originalTwo, trashed: two), TrashRecord(original: base.appendingPathComponent("first/gone.JPG"), trashed: stale)])
        store.state.deletionBatches = [batch1, batch2]; store.album = first.id
        let unrelatedUndo = try file("second/undo-scan-sentinel.ARW")
        store.undoTrash(); try await wait(store)
        precondition(!store.photos.contains { $0.preview == unrelatedUndo })
        try FileManager.default.removeItem(at: unrelatedUndo)
        precondition(FileManager.default.fileExists(atPath: originalTwo.path))
        precondition(FileManager.default.fileExists(atPath: one.path))
        precondition(store.state.deletionBatches.count == 1)
        print("PASS undo only the latest batch; missing trash records do not block it")

        let conflict = try file("trash/conflict.JPG"), good = try file("trash/good.JPG")
        let conflictOriginal = try file("first/conflict.JPG")
        let goodOriginal = base.appendingPathComponent("first/good.JPG")
        let mixed = DeletionBatch(albumID: first.id, records: [TrashRecord(original: conflictOriginal, trashed: conflict), TrashRecord(original: goodOriginal, trashed: good)])
        store.state.deletionBatches.append(mixed)
        store.undoTrash(mixed.id); try await wait(store)
        precondition(FileManager.default.fileExists(atPath: goodOriginal.path))
        precondition(store.state.deletionBatches.first { $0.id == mixed.id }?.records.count == 1)
        store.dismissBatch(mixed.id)
        print("PASS restore continues past collisions; failed batches can be dismissed")

        store.closeAlbum(first.id)
        precondition(store.albums.count == 1 && store.albums[0].id == second.id)
        precondition(store.state.deletionBatches.isEmpty && FileManager.default.fileExists(atPath: a.path))
        let saved = try JSONDecoder().decode(SavedState.self, from: Data(contentsOf: store.stateURL))
        precondition(saved.albums.count == 1)
        print("PASS close album removes only its session and history; files retained")

        let offlineRecord = try file("trash/offline.ARW")
        store.state.deletionBatches.append(DeletionBatch(albumID: second.id, records: [TrashRecord(original: b, trashed: offlineRecord)]))
        try FileManager.default.moveItem(at: b.deletingLastPathComponent(), to: base.appendingPathComponent("disconnected"))
        store.album = second.id
        store.undoTrash(); try await wait(store)
        precondition(store.unavailable.contains(second.id) && store.state.deletionBatches.isEmpty)
        precondition(FileManager.default.fileExists(atPath: offlineRecord.path))
        precondition(!FileManager.default.fileExists(atPath: b.deletingLastPathComponent().path))
        print("PASS unavailable album expires undo history")

        try store.applyRoots(Roots(jpg: a.deletingLastPathComponent().path))
        try await wait(store)
        precondition(store.albums.count == 2)
        store.search = "fixture"
        store.labelFilter = .orange
        store.closeAllAlbums()
        let closedState = try JSONDecoder().decode(SavedState.self, from: Data(contentsOf: store.stateURL))
        precondition(closedState.albums.isEmpty && closedState.deletionBatches.isEmpty)
        precondition(store.photos.isEmpty && store.unavailable.isEmpty && store.selected == nil && store.album == nil)
        precondition(store.search.isEmpty && store.labelFilter == nil && store.comparisonSelection.isEmpty)
        precondition(FileManager.default.fileExists(atPath: a.path))
        precondition(FileManager.default.fileExists(atPath: base.appendingPathComponent("disconnected").path))
        print("PASS close all clears active and offline albums while retaining source files")

        let firstImport = try file("incoming/earlier.JPG")
        let secondImport = try file("incoming/later.JPG")
        let importedRoot = base.appendingPathComponent("classified")
        let importPlan = [
            ImportItem(source: secondImport, destination: importedRoot.appendingPathComponent("20250831_杭州/later.JPG"), bytes: 7, fallbackDate: false),
            ImportItem(source: firstImport, destination: importedRoot.appendingPathComponent("20250830_杭州/earlier.JPG"), bytes: 7, fallbackDate: false)
        ]
        let previousReveal = store.importedAlbumReveal
        store.executeImport(importPlan, roots: Roots(jpg: importedRoot.path))
        try await wait(store)
        precondition(store.albums.map(\.title) == ["20250830_杭州", "20250831_杭州"])
        precondition(store.album == store.albums.first?.id && store.importedAlbumReveal != previousReveal)
        precondition(store.status.contains("2 个相册") && store.status.contains("20250830_杭州、20250831_杭州"))
        print("PASS multi-album import selects and reveals the first album in sorted order")

        let untouched = try file("classified/20250830_杭州/external.JPG")
        let pipelineRoot = base.appendingPathComponent("pipeline")
        let collision = try file("pipeline/20250901_杭州/B.JPG")
        try Data("existing target".utf8).write(to: collision)
        let pipelinePlan = try ["A", "B", "C"].map { name in
            let source = try file("pipeline-source/\(name).JPG")
            return ImportItem(source: source, destination: pipelineRoot.appendingPathComponent("20250901_杭州/\(name).JPG"), bytes: 7, fallbackDate: false)
        }
        store.executeImport(pipelinePlan, roots: Roots(jpg: pipelineRoot.path))
        try await wait(store)
        precondition(store.error != nil)
        precondition(FileManager.default.fileExists(atPath: pipelinePlan[0].destination.path))
        let collisionContents = try String(contentsOf: collision, encoding: .utf8)
        precondition(collisionContents == "existing target")
        precondition(!FileManager.default.fileExists(atPath: pipelinePlan[2].destination.path))
        let pipelineNames = try FileManager.default.contentsOfDirectory(atPath: collision.deletingLastPathComponent().path)
        precondition(!pipelineNames.contains { $0.hasPrefix(".import-") })
        precondition(!store.photos.contains { $0.preview == untouched })
        store.scan()
        try await wait(store)
        precondition(store.photos.contains { $0.preview == untouched })
        print("PASS import publishes in order, cleans prepared copies on failure and refreshes only affected albums")
        let stateFiles = try FileManager.default.contentsOfDirectory(atPath: base.path)
        precondition(!stateFiles.contains {
            $0.hasPrefix("import-") && ($0.hasSuffix(".json") || $0.hasSuffix(".jsonl"))
        })
        print("PASS import does not persist a completion journal")



        let incoming = try ["card-a", "card-b"].map { card in
            let jpg = try file("\(card)/A.JPG")
            _ = try file("\(card)/A.ARW")
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)], ofItemAtPath: jpg.path)
            return jpg.deletingLastPathComponent()
        }
        let sharedRoots = Roots(jpg: base.appendingPathComponent("shared-jpg").path,
                                raw: base.appendingPathComponent("shared-raw").path)
        let cancelledPreview = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await LibraryService.importPlanResolvingPlaces(sources: incoming, roots: sharedRoots, location: "", lookupGPS: false)
        }
        do {
            _ = try await cancelledPreview.value
            preconditionFailure("A cancelled preview must not return an import plan")
        } catch is CancellationError {}
        let sharedPlan = try await LibraryService.importPlanResolvingPlaces(sources: incoming, roots: sharedRoots, location: "", lookupGPS: false)
        precondition(!FileManager.default.fileExists(atPath: sharedRoots.jpg))
        precondition(!FileManager.default.fileExists(atPath: sharedRoots.raw))
        print("PASS cancelled import preview can be retried without creating destination folders")
        precondition(sharedPlan.first?.source.deletingLastPathComponent() == incoming[0])
        precondition(sharedPlan.allSatisfy { $0.destination.deletingLastPathComponent().lastPathComponent.hasSuffix("_未知") })
        precondition(sharedPlan.count == 4 && Set(sharedPlan.map(\.destination)).count == 4)
        for group in Dictionary(grouping: sharedPlan, by: \.pairID).values {
            precondition(group.count == 2)
            precondition(Set(group.map { $0.destination.deletingPathExtension().lastPathComponent }).count == 1)
        }
        for item in sharedPlan { try LibraryService.copyVerified(item) }
        let sharedAlbum = Roots(jpg: sharedPlan.first { $0.destination.pathExtension == "JPG" }!.destination.deletingLastPathComponent().path,
                                raw: sharedPlan.first { $0.destination.pathExtension == "ARW" }!.destination.deletingLastPathComponent().path)
        let paired = try LibraryService.scan(sharedAlbum)
        precondition(paired.count == 2 && paired.allSatisfy(\.paired))
        do {
            _ = try await LibraryService.importPlanResolvingPlaces(sources: [incoming[0], incoming[0].appendingPathComponent("nested")], roots: sharedRoots, location: "测试地点")
            preconditionFailure("Expected overlapping import sources to be rejected")
        } catch let error as LibraryError {
            precondition(error.localizedDescription.contains("互相包含"))
        }
        print("PASS multi-source import uses shared roots, preserves pairs on name collisions and rejects overlapping sources")

        let ambiguousJPG = try file("ambiguous-a/one/A.JPG")
        let ambiguousRAW1 = try file("ambiguous-a/two/A.ARW")
        let ambiguousRAW2 = try file("ambiguous-a/three/A.ARW")
        let ambiguousB1 = try file("ambiguous-b/one/B.JPG")
        let ambiguousB2 = try file("ambiguous-b/two/B.JPG")
        let missingSource = base.appendingPathComponent("missing-source")
        let problemSources = [base.appendingPathComponent("ambiguous-a"), base.appendingPathComponent("ambiguous-b"), missingSource]
        do {
            _ = try await LibraryService.importPlanResolvingPlaces(sources: problemSources, roots: sharedRoots, location: "测试地点")
            preconditionFailure("Expected all source problems in one report")
        } catch let error as LibraryError {
            let report = error.localizedDescription
            precondition(report.contains("3 组来源问题"))
            precondition(report.contains("1 个 JPG、2 个 ARW") && report.contains("2 个 JPG、0 个 ARW"))
            precondition(([ambiguousJPG, ambiguousRAW1, ambiguousRAW2, ambiguousB1, ambiguousB2, missingSource]).allSatisfy { report.contains($0.path) })
        }
        print("PASS import preflight reports every ambiguous group and unreadable source with paths")





        let marked=LibraryStore(stateURL:base.appendingPathComponent("marks-state.json"))
        try marked.applyRoots(Roots(jpg:a.deletingLastPathComponent().path));try await wait(marked)
        let target=marked.photos.first{$0.preview==a}!
        marked.toggleLabel(.orange,photo:target);try await wait(marked)
        marked.toggleLabel(.blue,photo:target);try await wait(marked)
        marked.toggleReject(target);try await wait(marked)
        precondition(marked.labels(for:target)==[.orange,.blue] && marked.state.rejected.contains(target.id))
        marked.labelFilter = .orange;precondition(marked.visible.contains{$0.id==target.id})
        marked.labelFilter = .gray;precondition(marked.visible.isEmpty && marked.rejected.isEmpty)
        marked.labelFilter=nil;marked.closeAllAlbums()
        try marked.applyRoots(Roots(jpg:a.deletingLastPathComponent().path));try await wait(marked)
        precondition(marked.labels(for:target)==[.orange,.blue] && marked.state.rejected.contains(target.id))
        let independent=LibraryStore(stateURL:base.appendingPathComponent("independent-state.json"))
        try independent.applyRoots(Roots(jpg:a.deletingLastPathComponent().path));try await wait(independent)
        precondition(independent.labels(for:target)==[.orange,.blue] && independent.state.rejected.contains(target.id))
        let otherAlbum = try file("edit-unrelated/fixture.ARW").deletingLastPathComponent()
        try independent.applyRoots(Roots(raw: otherAlbum.path))
        try await wait(independent)
        let unrelatedEdit = try file("edit-unrelated/edit-scan-sentinel.ARW")
        try Data("fixture edited".utf8).write(to:a)
        await independent.reloadAfterEditing(a)
        precondition(!independent.photos.contains { $0.preview == unrelatedEdit })
        try FileManager.default.removeItem(at: unrelatedEdit)
        let edited=independent.photos.first{$0.preview==a}!
        precondition(independent.labels(for:edited)==[.orange,.blue] && !independent.state.rejected.contains(edited.id))
        independent.clearLabels(edited);try await wait(independent)
        independent.scan();try await wait(independent)
        precondition(independent.labels(for:edited).isEmpty && !independent.state.rejected.contains(edited.id))
        print("PASS color filtering, scoped delete targets, close/reopen and config-independent marks, color retention after app editing and persistent clear")
        print("8 store scenarios passed")
    }
}
