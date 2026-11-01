import Foundation

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
        let a = try file("first/A.JPG"); let b = try file("second/B.ARW")
        let store = LibraryStore(stateURL: base.appendingPathComponent("state.json"))
        try store.applyRoots(Roots(jpg: a.deletingLastPathComponent().path), title: "第一本")
        try await wait(store)
        let first = store.state.albums[0]
        try store.applyRoots(Roots(raw: b.deletingLastPathComponent().path), title: "第二本")
        try await wait(store)
        let second = store.state.albums[1]
        precondition(store.albums.count == 2 && store.photos.count == 2)
        precondition(store.photos.first { $0.albumID == second.id }?.files.first?.isRAW == true)
        print("PASS append independent JPG-only and RAW-only albums")
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

        let one = try file("trash/one.JPG"), two = try file("trash/two.JPG")
        let stale = base.appendingPathComponent("trash/gone.JPG")
        let originalOne = a.deletingLastPathComponent().appendingPathComponent("one.JPG")
        let originalTwo = a.deletingLastPathComponent().appendingPathComponent("two.JPG")
        let batch1 = DeletionBatch(albumID: first.id, records: [TrashRecord(original: originalOne, trashed: one)])
        let batch2 = DeletionBatch(albumID: first.id, records: [TrashRecord(original: originalTwo, trashed: two), TrashRecord(original: base.appendingPathComponent("first/gone.JPG"), trashed: stale)])
        store.state.deletionBatches = [batch1, batch2]; store.album = first.id
        store.undoTrash(); try await wait(store)
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
        store.scan(); try await wait(store)
        precondition(store.unavailable.contains(second.id) && store.state.deletionBatches.isEmpty)
        print("PASS unavailable album expires undo history")
        print("7 store scenarios passed")
    }
}
