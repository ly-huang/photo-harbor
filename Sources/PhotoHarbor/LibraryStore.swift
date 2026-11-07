import SwiftUI
import AppKit

@MainActor final class LibraryStore: ObservableObject {
    @Published var state = SavedState()
    @Published var photos: [Photo] = []
    @Published var annotations:[String:PhotoAnnotation]=[:]
    @Published var labelFilter:PhotoLabel?
    @Published var selected: String?
    @Published var filter = "全部照片"
    @Published var album: String?
    @Published private(set) var importedAlbumReveal = UUID()
    @Published var search = ""
    @Published var busy = false
    @Published private(set) var scanningAlbums = false
    private var didStartInitialScan = false
    @Published var trusted = false
    @Published var unavailable: Set<String> = []
    @Published var status = "打开已有相册，或导入一次拍摄。"
    @Published var error: String?
    @Published var settings = false
    @Published var importing = false
    @Published var editorActive = false
    var editorCloseRequest: (() -> Void)?
    @Published var editorCanUndo = false
    @Published var editorCanRedo = false
    var editorUndo: (() -> Void)?
    var editorRedo: (() -> Void)?
    @Published var viewer = false
    @Published var viewerFullScreen = false
    @Published var navigatorVisible = true
    @Published var comparisonSelection: [String] = []
    @Published var comparisonFullScreen = false
    @Published var assessments: [String: PhotoAssessment] = [:]
    @Published var assessing: Set<String> = []
    @Published var assessmentErrors: [String: String] = [:]
    @Published var confirmTrash = false
    @Published var history = false
    @Published var metadata = Metadata()
    @Published private(set) var importProgress: Double?
    @Published var cancellationRequested = false
    var viewerController: PhotoViewerController?
    var comparisonController: ComparisonController?
    var comparisonPhotos: [Photo] { comparisonSelection.compactMap { id in photos.first { $0.id == id } } }
    func toggleComparison(_ photo: Photo) {
        if comparisonSelection.contains(photo.id) { comparisonSelection.removeAll { $0 == photo.id } }
        else {
            guard comparisonSelection.count < 4 else { status = "最多选择四张照片，请先移除一张。"; return }
            comparisonSelection.append(photo.id)
        }
    }
    func clearComparisonSelection() {
        comparisonSelection.removeAll()
        status = "已清空对比选择。"
    }
    func showComparison() {
        guard (2...4).contains(comparisonPhotos.count) else { return }
        if comparisonController == nil { comparisonController = ComparisonController(store: self) }
        if let window = comparisonController?.window { activateWindow(window) }
    }
    func recordAssessment(_ result: PhotoAssessment, for photo: Photo) {
        guard photos.contains(where: { $0.id == photo.id }) else { return }
        assessments[photo.id] = result; assessmentErrors[photo.id] = nil
    }
    func assessPhoto(_ photo: Photo) {
        guard !assessing.contains(photo.id) else { return }
        assessing.insert(photo.id); assessmentErrors[photo.id] = nil
        Task {
            defer { assessing.remove(photo.id) }
            do { recordAssessment(try await AssessmentService.shared.assess(photo.preview), for: photo) }
            catch { assessmentErrors[photo.id] = error.localizedDescription }
        }
    }
    private func activateWindow(_ window: NSWindow) {
        let behavior = window.collectionBehavior
        window.collectionBehavior.insert(.moveToActiveSpace)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.collectionBehavior = behavior
    }
    let stateURL: URL
    var focused: Photo? { photos.first { $0.id == selected } }
    var albums: [OpenAlbum] { state.albums }
    var albumTitle: String? { albums.first { $0.id == album }?.title }
    var rejected: [Photo] { photos.filter { state.rejected.contains($0.id) && (album == nil || $0.albumID == album) && (labelFilter == nil || labels(for:$0).contains(labelFilter!)) } }
    var undoBatches: [DeletionBatch] { state.deletionBatches.filter { (album == nil || $0.albumID == album) && !unavailable.contains($0.albumID) }.reversed() }
    var visible: [Photo] {
        photos.filter { photo in
            (album == nil || photo.albumID == album) &&
            (labelFilter == nil || annotations[photo.id]?.colors.contains(labelFilter!) == true) &&
            (search.isEmpty || photo.name.localizedCaseInsensitiveContains(search) || photo.album.localizedCaseInsensitiveContains(search) || (albums.first { $0.id == photo.albumID }?.title.localizedCaseInsensitiveContains(search) ?? false)) &&
            (filter != "待删除" || state.rejected.contains(photo.id)) &&
            (filter != "未配对" || !photo.paired) &&
            (filter != "待检查" || photo.ambiguous)
        }
    }
    init(stateURL: URL? = nil) {
        self.stateURL = stateURL ?? ProcessInfo.processInfo.environment["PHOTOHARBOR_STATE_PATH"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("PhotoHarbor/state.json")
        if FileManager.default.fileExists(atPath: self.stateURL.path) {
            do { state = try JSONDecoder().decode(SavedState.self, from: Data(contentsOf: self.stateURL)) }
            catch { self.error = "无法读取保存的设置，原文件已保留：\(error.localizedDescription)" }
        }
    }
    func persist() throws {
        try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
    }
    func save() { do { try persist() } catch { self.error = "设置保存失败：\(error.localizedDescription)" } }
    func scanOnLaunch() {
        guard !didStartInitialScan else { return }
        didStartInitialScan = true
        if !albums.isEmpty { scan() }
    }
    func scan(only albumIDs: Set<String>? = nil) {
        guard !busy else { return }
        busy = true; scanningAlbums = true; trusted = false
        status = "正在扫描打开的相册…"
        Task {
            await reloadAlbums(only: albumIDs, publishIncrementally: true)
            scanningAlbums = false
            busy = false
        }
    }
    private func reloadAlbums(only albumIDs: Set<String>? = nil, publishIncrementally: Bool = false) async {
        let albumsToLoad = state.albums
        let legacy = state.rejected
        var targets = albumsToLoad.filter { albumIDs?.contains($0.id) ?? true }
        if let album, let index = targets.firstIndex(where: { $0.id == album }), index > 0 {
            targets.insert(targets.remove(at: index), at: 0)
        }
        var byAlbum = Dictionary(grouping: photos, by: \.albumID)
        var failed = unavailable
        var marks = annotations
        var markErrors = 0
        var scannedCount = 0
        let scanCount = targets.count
        let parallelFormats = scanCount == 1
        await withTaskGroup(of: AlbumScan.self) { group in
            var pending = targets.makeIterator()
            for _ in 0..<min(3, scanCount) {
                guard let item = pending.next() else { break }
                group.addTask(priority: .userInitiated) { await Self.readAlbum(item, legacy: legacy, parallelFormats: parallelFormats) }
            }
            for await result in group {
                for photo in byAlbum[result.id] ?? [] { marks.removeValue(forKey: photo.id) }
                byAlbum[result.id] = result.photos
                marks.merge(result.marks) { _, fresh in fresh }
                markErrors += result.markErrors
                if result.failed { failed.insert(result.id) } else { failed.remove(result.id) }
                if let item = pending.next() {
                    group.addTask(priority: .userInitiated) { await Self.readAlbum(item, legacy: legacy, parallelFormats: parallelFormats) }
                }
                if publishIncrementally {
                    scannedCount += 1
                    annotations = marks
                    photos = albumsToLoad.flatMap { byAlbum[$0.id] ?? [] }
                    unavailable = failed
                    reconcileSelection()
                    status = "已扫描 \(scannedCount)/\(scanCount) 个相册，已找到 \(photos.count) 张照片…"
                }
            }
        }
        let results = albumsToLoad.flatMap { byAlbum[$0.id] ?? [] }
        annotations = marks
        state.rejected = Set(marks.compactMap { $0.value.rejected ? $0.key : nil })
        if markErrors > 0 { error = "\(markErrors) 张照片的目录标记未能读取或迁移，请检查权限及隐藏记录；未对这些照片启用删除标记。" }
        photos = results; unavailable = failed
        state.pruneHistory(availableAlbumIDs: Set(state.albums.map(\.id)).subtracting(failed))
        let currentIDs = Set(results.map(\.id))
        assessments = assessments.filter { currentIDs.contains($0.key) }
        assessmentErrors = assessmentErrors.filter { currentIDs.contains($0.key) }
        comparisonSelection.removeAll { !currentIDs.contains($0) }
        state.rejected.formIntersection(currentIDs)
        trusted = !state.albums.isEmpty
        reconcileSelection(); save()
        status = "\(photos.count) 张照片，\(photos.filter(\.paired).count) 对 JPG + RAW" + (failed.isEmpty ? "" : "；\(failed.count) 个相册无法访问，已清除其撤销记录")
    }
    private struct AlbumScan: Sendable {
        let id: String
        var photos: [Photo] = []
        var marks: [String: PhotoAnnotation] = [:]
        var markErrors = 0
        var failed = false
    }

    nonisolated private static func readAlbum(_ album: OpenAlbum, legacy: Set<String>, parallelFormats: Bool) async -> AlbumScan {
        var result = AlbumScan(id: album.id)
        do {
            result.photos = try await LibraryService.scanForBrowsing(album.roots, parallelFormats: parallelFormats)
        } catch {
            result.failed = true
            return result
        }
        var index = PhotoMarkStorage.DirectoryIndex()
        for i in result.photos.indices {
            result.photos[i].albumID = album.id
            let photo = result.photos[i]
            let id = photo.id
            do {
                result.marks[id] = try index.load(photo, legacyRejected: legacy.contains(id))
            } catch {
                result.markErrors += 1
                let existing = photo.files.contains { FileManager.default.fileExists(atPath: PhotoMarkStorage.url($0).path) }
                result.marks[id] = PhotoAnnotation(rejected: !existing && legacy.contains(id))
            }
        }
        return result
    }

    func reloadAfterEditing(_ url: URL) async {
        busy = true
        let oldPhoto=photos.first{$0.files.contains{$0.url==url}}
        let oldColors=oldPhoto.flatMap{annotations[$0.id]?.colors} ?? []
        await reloadAlbums()
        if let edited = photos.first(where: { $0.files.contains(where: { $0.url == url }) }) {
            selected = edited.id
            if !oldColors.isEmpty {
                let annotation=PhotoAnnotation(colors:oldColors,rejected:false)
                do{try await Task.detached{try PhotoMarkStorage.save(annotation,for:edited)}.value;annotations[edited.id]=annotation;state.rejected.remove(edited.id);save()}
                catch{self.error="照片已保存，颜色标记未能更新到新版本：\(error.localizedDescription)"}
            }
        }
        ImageCache.shared.cache.removeAllObjects()
        busy = false
    }
    func select(_ photo: Photo) { selected = photo.id }
    func reconcileSelection() {
        if !visible.contains(where: { $0.id == selected }) { selected = visible.first?.id }
    }
    func loadMetadata() async {
        guard let photo = focused else { metadata = Metadata(); return }
        metadata = Metadata()
        let id = photo.id
        let result = await Task.detached { Metadata.read(photo.preview) }.value
        if selected == id { metadata = result }
    }
    func labels(for photo:Photo)->Set<PhotoLabel>{annotations[photo.id]?.colors ?? []}
    func toggleLabel(_ label:PhotoLabel,photo:Photo){var a=annotations[photo.id] ?? PhotoAnnotation(rejected:state.rejected.contains(photo.id));if a.colors.contains(label){a.colors.remove(label)}else{a.colors.insert(label)};writeAnnotation(a,photo:photo)}
    func clearLabels(_ photo:Photo){var a=annotations[photo.id] ?? PhotoAnnotation(rejected:state.rejected.contains(photo.id));a.colors=[];writeAnnotation(a,photo:photo)}
    func toggleReject(_ photo: Photo) {
        var a=annotations[photo.id] ?? PhotoAnnotation();a.rejected = !state.rejected.contains(photo.id);writeAnnotation(a,photo:photo)
    }
    private func writeAnnotation(_ annotation:PhotoAnnotation,photo:Photo){
        guard !busy else{return};busy=true
        Task {
            defer{busy=false}
            do {
                try await Task.detached{try PhotoMarkStorage.save(annotation,for:photo)}.value
                annotations[photo.id]=annotation
                if annotation.rejected{state.rejected.insert(photo.id)}else{state.rejected.remove(photo.id)}
                save();reconcileSelection();status="已保存照片目录中的标记。"
            } catch{self.error="标记保存失败，未更新标记：\(error.localizedDescription)"}
        }
    }
    func navigate(_ offset: Int) {
        let list = visible
        guard !list.isEmpty else { return }
        let index = list.firstIndex { $0.id == selected } ?? 0
        selected = list[min(max(index + offset, 0), list.count - 1)].id
    }
    @discardableResult private func registerAlbum(_ roots: Roots, title: String? = nil) throws -> String {
        try roots.validate()
        let incoming = OpenAlbum(roots: roots, title: title)
        let (albums, ids) = try Self.registerAlbums([incoming], into: state.albums)
        state.albums = albums
        return ids[0]
    }

    nonisolated private static func registerAlbums(_ incoming: [OpenAlbum], into existing: [OpenAlbum], allowAncestor: Bool = true) throws -> ([OpenAlbum], [String]) {
        var albums = existing
        var paths = existing.map { $0.roots.urls.map(\.path) }
        var ids: [String] = []
        for item in incoming {
            let children = item.roots.urls.map(\.path)
            if let owner = albums.indices.first(where: { index in
                albums[index].roots == item.roots || children.allSatisfy { child in
                    paths[index].contains { child == $0 || child.hasPrefix($0 + "/") }
                }
            }) {
                guard allowAncestor || albums[owner].roots == item.roots else {
                    throw LibraryError.message("子目录已由「\(albums[owner].title)」管理。请先关闭该上层相册，再按子目录打开。")
                }
                ids.append(albums[owner].id)
                continue
            }
            if let overlap = paths.firstIndex(where: { roots in
                roots.contains { a in children.contains { b in a == b || a.hasPrefix(b + "/") || b.hasPrefix(a + "/") } }
            }) {
                throw LibraryError.message("这些目录与已打开的“\(albums[overlap].title)”重叠。请先关闭该相册，避免重复管理同一文件。")
            }
            albums.append(item)
            paths.append(children)
            ids.append(item.id)
        }
        return (albums, ids)
    }

    func applyRoots(_ roots: Roots, title: String = "") throws {
        try roots.validate()
        let (albums, ids) = try Self.registerAlbums([OpenAlbum(roots: roots, title: title)], into: state.albums)
        try finishOpening(albums, ids: ids)
    }

    func applyAlbumFolders(_ roots: Roots) async throws {
        guard !busy else { throw LibraryError.message("照片库正在处理其他任务，请稍后重试。") }
        let existing = state.albums
        let (albums, ids) = try await Task.detached {
            let incoming = try LibraryService.discoverAlbumFolders(roots)
            return try Self.registerAlbums(incoming, into: existing, allowAncestor: false)
        }.value
        guard !busy, state.albums == existing else { throw LibraryError.message("相册列表已变化，请重新打开。") }
        try finishOpening(albums, ids: ids)
    }

    private func finishOpening(_ albums: [OpenAlbum], ids: [String]) throws {
        let previous = state
        state.albums = albums
        do { try persist() } catch { state = previous; throw error }
        album = ids.first
        filter = "全部照片"; search = ""; settings = false
        scan(only: Set(ids))
        if ids.count > 1 { importedAlbumReveal = UUID() }
    }
    func closeAlbum(_ id: String) {
        closeAlbums([id], all: false)
    }

    func closeAllAlbums() {
        closeAlbums(Set(albums.map(\.id)), all: true)
    }

    private func closeAlbums(_ albumIDs: Set<String>, all: Bool) {
        guard !busy, !editorActive, albums.contains(where: { albumIDs.contains($0.id) }) else { return }
        let photoIDs = Set(photos.filter { albumIDs.contains($0.albumID) }.map(\.id))
        let previous = state
        if all { state.rejected.removeAll() } else { state.rejected.subtract(photoIDs) }
        state.deletionBatches.removeAll { albumIDs.contains($0.albumID) }
        state.albums.removeAll { albumIDs.contains($0.id) }
        do {
            try persist()
        } catch {
            state = previous
            self.error = "无法保存相册列表：\(error.localizedDescription)"
            return
        }

        annotations = annotations.filter { !photoIDs.contains($0.key) }
        comparisonSelection.removeAll { photoIDs.contains($0) }
        photos.removeAll { albumIDs.contains($0.albumID) }
        unavailable.subtract(albumIDs)
        if let album, albumIDs.contains(album) { self.album = nil }
        if focused == nil { viewerController?.close() }
        if all {
            trusted = false
            annotations.removeAll()
            comparisonSelection.removeAll()
            comparisonController?.close()
            filter = "全部照片"
            search = ""
            labelFilter = nil
        }
        reconcileSelection()
        status = all ? "已关闭所有相册，磁盘照片保留。" : "已关闭相册，磁盘照片保留。"
    }

    func showViewer() {
        guard !editorActive else { viewerController?.window?.makeKeyAndOrderFront(nil); return }
        viewer = true
        if let controller = viewerController, let window = controller.window {
            // Reuse the existing fullscreen window and bring its Space forward.
            NSApp.activate(ignoringOtherApps: true)
            if window.styleMask.contains(.fullScreen) {
                window.makeKeyAndOrderFront(nil); window.orderFrontRegardless()
                NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            }
            else { activateWindow(window) }
            return
        }
        guard focused != nil else { viewer = false; return }
        let controller = PhotoViewerController(store: self)
        viewerController = controller
        controller.showWindow(nil); if let window = controller.window { activateWindow(window) }
    }
    func executeImport(_ plan: [ImportItem], roots: Roots) {
        guard !busy, !plan.isEmpty else { return }
        let roots = Roots.importDestinations(jpg: roots.jpg, raw: roots.raw)
        busy = true; importProgress = 0; cancellationRequested = false
        Task {
            var completed: [ImportItem] = []
            var outcome = ""
            var pending: Task<LibraryService.PreparedImport, Error>?
            do {
                try roots.validate(allowMissing: true)
                try persist()
                for (index, item) in plan.enumerated() {
                    if cancellationRequested { break }
                    status = "正在校验复制 \(completed.count + 1)/\(plan.count)：\(item.source.lastPathComponent)"
                    let current = pending ?? Task.detached(priority: .userInitiated) { try LibraryService.prepareVerifiedImport(item) }
                    pending = nil
                    if index + 1 < plan.count {
                        let next = plan[index + 1]
                        pending = Task.detached(priority: .userInitiated) { try LibraryService.prepareVerifiedImport(next) }
                    }
                    let prepared = try await current.value
                    if cancellationRequested {
                        prepared.discard()
                        break
                    }
                    try await Task.detached(priority: .userInitiated) { try LibraryService.publishVerifiedImport(prepared) }.value
                    completed.append(item)
                    importProgress = Double(completed.count) / Double(plan.count)
                }
                outcome = "已复制并校验 \(completed.count)/\(plan.count) 个文件。源文件保留。"
            } catch { self.error = "已完成 \(completed.count) 个文件；导入停止：\(error.localizedDescription)"; outcome = "导入已停止，已完成 \(completed.count)/\(plan.count) 个文件。" }
            if let pending {
                pending.cancel()
                if let prepared = try? await pending.value { prepared.discard() }
            }
            importProgress = nil
            cancellationRequested = false
            let groups = Dictionary(grouping: completed, by: { $0.destination.deletingLastPathComponent().lastPathComponent })
            var openedAlbumIDs: [String] = []
            var seenAlbumIDs = Set<String>()
            var registrationFailed = false
            for name in groups.keys.sorted() {
                let items = groups[name]!
                let j = items.first { !$0.source.pathExtension.lowercased().contains("arw") }?.destination.deletingLastPathComponent().path ?? ""
                let r = items.first { $0.source.pathExtension.lowercased() == "arw" }?.destination.deletingLastPathComponent().path ?? ""
                do {
                    let id = try registerAlbum(Roots(jpg: j, raw: r), title: name)
                    if seenAlbumIDs.insert(id).inserted { openedAlbumIDs.append(id) }
                }
                catch {
                    registrationFailed = true
                    self.error = "照片已复制，但相册未自动打开：\(error.localizedDescription)"
                }
            }
            if let first = openedAlbumIDs.first {
                album = first
                let titles = openedAlbumIDs.compactMap { id in albums.first { $0.id == id }?.title }
                outcome = "本次导入 \(titles.count) 个相册（\(titles.joined(separator: "、"))）。" + outcome
            }
            filter = "全部照片"; search = ""; save()
            if registrationFailed || !seenAlbumIDs.isEmpty {
                await reloadAlbums(only: registrationFailed ? nil : seenAlbumIDs)
            }
            status = outcome; busy = false
            if !openedAlbumIDs.isEmpty { importedAlbumReveal = UUID() }
        }
    }
    func deleteRejected(permanently: Bool = false, moveToTrash: @escaping @Sendable (PhotoFile) throws -> TrashRecord = { try LibraryService.trash($0) }) {
        guard trusted, !busy, !rejected.isEmpty else { return }
        let targets = rejected
        let action = permanently ? "直接删除" : "移入废纸篓"
        busy = true
        status = "正在核对待删除照片及配对关系…"
        Task {
            defer { busy = false }
            var count = 0
            var changedAlbums: Set<String> = []
            var failure: String?
            do {
                // Validate every affected album before deleting the first file.
                for group in Dictionary(grouping: targets, by: \.albumID) {
                    guard let owner = state.albums.first(where: { $0.id == group.key }) else { throw LibraryError.message("相册已关闭。") }
                    try await Task.detached { try LibraryService.validateDeletion(group.value, roots: owner.roots) }.value
                }
                try persist()
                var batchIDs: [String: String] = [:]
                for photo in targets {
                    for file in photo.files {
                        status = "正在\(action)：\(file.url.lastPathComponent)…"
                        let record = try await Task.detached { () -> TrashRecord? in
                            do {
                                if permanently {
                                    try LibraryService.deletePermanently(file)
                                    return nil
                                }
                                return try moveToTrash(file)
                            }
                            catch {
                                if permanently {
                                    throw LibraryError.message("无法直接删除「\(file.url.lastPathComponent)」。\(error.localizedDescription)")
                                }
                                throw LibraryError.message("无法将「\(file.url.lastPathComponent)」移入系统废纸篓。\(error.localizedDescription) 如果照片位于 NAS，请确认共享支持 macOS 废纸篓且具有移动权限。")
                            }
                        }.value
                        count += 1
                        changedAlbums.insert(photo.albumID)
                        guard let record else {
                            try await Task.detached { try PhotoMarkStorage.consumeRejection(file) }.value
                            continue
                        }
                        let index: Int
                        if let batchID = batchIDs[photo.albumID], let found = state.deletionBatches.firstIndex(where: { $0.id == batchID }) { index = found }
                        else {
                            let batch = DeletionBatch(albumID: photo.albumID)
                            batchIDs[photo.albumID] = batch.id; state.deletionBatches.append(batch)
                            index = state.deletionBatches.count - 1
                        }
                        state.deletionBatches[index].records.append(record)
                        try persist()
                        try await Task.detached{try PhotoMarkStorage.consumeRejection(file)}.value
                    }
                    state.rejected.remove(photo.id); try persist()
                }
            } catch { failure = error.localizedDescription }
            if !changedAlbums.isEmpty {
                status = "正在更新受影响的相册…"
                await reloadAlbums(only: changedAlbums)
            }
            if let failure {
                let result = permanently ? "已直接删除 \(count) 个文件，无法通过拾影撤销。" : "已移动 \(count) 个文件，可按批次撤销。"
                status = count == 0 ? "未能\(action)，待删除标记已保留。" : "\(action)已停止。\(result)"
                self.error = count == 0 ? failure : "\(failure) \(result)"
            } else {
                status = permanently ? "已直接删除 \(count) 个文件。" : "已将 \(count) 个文件移入废纸篓，按相册和操作批次记录。"
            }
        }
    }
    func dismissBatch(_ id: String) { state.deletionBatches.removeAll { $0.id == id }; save() }
    func refreshHistory() {
        let available = Set(state.albums.filter { (try? $0.roots.validate()) != nil }.map(\.id))
        state.pruneHistory(availableAlbumIDs: available)
        unavailable = Set(state.albums.map(\.id)).subtracting(available)
        save()
    }
    func undoTrash(_ batchID: String? = nil) {
        guard !busy else { return }
        // Refresh lifecycle before selecting a batch. Closed/offline albums expire.
        refreshHistory()
        guard let batch = undoBatches.first(where: { batchID == nil || $0.id == batchID }), let owner = state.albums.first(where: { $0.id == batch.albumID }) else { return }
        busy = true
        Task {
            var restored = 0, missing = 0, failures: [String] = []
            for record in batch.records {
                do {
                    try owner.roots.validate()
                    if !FileManager.default.fileExists(atPath: record.trashed.path) { missing += 1 }
                    else { try await Task.detached { try LibraryService.restore(record) }.value; restored += 1 }
                    if let i = state.deletionBatches.firstIndex(where: { $0.id == batch.id }) { state.deletionBatches[i].records.removeAll { $0.trashed == record.trashed } }
                    // Persist every successful move, including a partially restored pair.
                    try persist()
                } catch { failures.append(record.original.lastPathComponent + "：" + error.localizedDescription) }
            }
            await reloadAlbums()
            status = "已恢复 \(restored) 个文件" + (missing > 0 ? "，清除 \(missing) 条失效记录" : "")
            if !failures.isEmpty { self.error = "已继续恢复其他可用文件。\(failures.count) 个文件未恢复，可在删除记录中重试或移除该批记录。\n" + failures.prefix(3).joined(separator: "\n") }
            busy = false
        }
    }
    func chooseDirectory() -> String? {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.canCreateDirectories = true; panel.prompt = "选择目录"
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
}
