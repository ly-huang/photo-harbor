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
    @Published var search = ""
    @Published var busy = false
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
    @Published var progress: Double = 0
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
    func scan() {
        guard !busy else { return }
        busy = true; trusted = false; status = "正在扫描打开的相册…"
        Task { await reloadAlbums(); busy = false }
    }
    private func reloadAlbums() async {
        var results: [Photo] = [], failed: Set<String> = []
        for item in state.albums {
            do {
                var scanned = try await Task.detached(priority: .userInitiated) { try LibraryService.scan(item.roots) }.value
                for i in scanned.indices { scanned[i].albumID = item.id }
                results += scanned
            } catch { failed.insert(item.id) }
        }
        let markPhotos=results,legacy=state.rejected
        let loaded=await Task.detached { () -> ([String:PhotoAnnotation],Int) in
            var marks:[String:PhotoAnnotation]=[:],errors=0
            for photo in markPhotos {
                do{marks[photo.id]=try PhotoMarkStorage.load(photo,legacyRejected:legacy.contains(photo.id))}
                catch{
                    errors+=1
                    let existing=photo.files.contains{FileManager.default.fileExists(atPath:PhotoMarkStorage.url($0).path)}
                    marks[photo.id]=PhotoAnnotation(rejected:!existing && legacy.contains(photo.id))
                }
            }
            return(marks,errors)
        }.value
        annotations=loaded.0
        state.rejected=Set(results.filter{annotations[$0.id]?.rejected==true}.map(\.id))
        if loaded.1>0{error="\(loaded.1) 张照片的目录标记未能读取或迁移，请检查权限及隐藏记录；未对这些照片启用删除标记。"}
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
        let normalized = OpenAlbum(roots: roots, title: title)
        if let existing = state.albums.first(where: { $0.roots == normalized.roots }) { return existing.id }
        // An existing open ancestor already owns these files. Never list a file twice.
        if let owner = state.albums.first(where: { existing in
            roots.urls.allSatisfy { child in existing.roots.urls.contains { child.path == $0.path || child.path.hasPrefix($0.path + "/") } }
        }) { return owner.id }
        for existing in state.albums {
            if existing.roots.urls.contains(where: { a in roots.urls.contains { b in a.path == b.path || a.path.hasPrefix(b.path + "/") || b.path.hasPrefix(a.path + "/") } }) {
                throw LibraryError.message("这些目录与已打开的“\(existing.title)”重叠。请先关闭该相册，避免重复管理同一文件。")
            }
        }
        state.albums.append(normalized)
        return normalized.id
    }
    func applyRoots(_ roots: Roots, title: String = "") throws {
        let previous = state
        do {
            album = try registerAlbum(roots, title: title)
            try persist()
        } catch { state = previous; throw error }
        filter = "全部照片"; search = ""; settings = false; scan()
    }
    func closeAlbum(_ id: String) {
        guard !busy else { return }
        let ids = Set(photos.filter { $0.albumID == id }.map(\.id))
        state.rejected.subtract(ids)
        annotations=annotations.filter{!ids.contains($0.key)}
        comparisonSelection.removeAll { ids.contains($0) }
        state.deletionBatches.removeAll { $0.albumID == id }
        state.albums.removeAll { $0.id == id }
        photos.removeAll { $0.albumID == id }; unavailable.remove(id)
        if album == id { album = nil }
        if focused == nil { viewerController?.close() }
        reconcileSelection(); save()
        status = "已关闭相册，磁盘照片保留。"
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
        busy = true; progress = 0; cancellationRequested = false
        Task {
            var completed: [ImportItem] = []
            var outcome = ""
            do {
                try roots.validate(allowMissing: true)
                try persist()
                let log = stateURL.deletingLastPathComponent().appendingPathComponent("import-\(UUID().uuidString).json")
                var records: [String] = []
                try JSONEncoder().encode(records).write(to: log, options: .atomic)
                for item in plan {
                    if cancellationRequested { break }
                    status = "正在校验复制 \(completed.count + 1)/\(plan.count)：\(item.source.lastPathComponent)"
                    try await Task.detached(priority: .userInitiated) { try LibraryService.copyVerified(item) }.value
                    completed.append(item); records.append(item.destination.path)
                    try JSONEncoder().encode(records).write(to: log, options: .atomic)
                    progress = Double(completed.count) / Double(plan.count)
                }
                outcome = "已复制并校验 \(completed.count)/\(plan.count) 个文件。源文件保留。"
            } catch { self.error = "已完成 \(completed.count) 个文件；导入停止：\(error.localizedDescription)"; outcome = "导入已停止，已完成 \(completed.count)/\(plan.count) 个文件。" }
            let groups = Dictionary(grouping: completed, by: { $0.destination.deletingLastPathComponent().lastPathComponent })
            for name in groups.keys.sorted() {
                let items = groups[name]!
                let j = items.first { !$0.source.pathExtension.lowercased().contains("arw") }?.destination.deletingLastPathComponent().path ?? ""
                let r = items.first { $0.source.pathExtension.lowercased() == "arw" }?.destination.deletingLastPathComponent().path ?? ""
                do { album = try registerAlbum(Roots(jpg: j, raw: r), title: name) }
                catch { self.error = "照片已复制，但相册未自动打开：\(error.localizedDescription)" }
            }
            filter = "全部照片"; search = ""; save()
            await reloadAlbums(); status = outcome; busy = false
        }
    }
    func deleteRejected() {
        guard trusted, !busy, !rejected.isEmpty else { return }
        let targets = rejected
        busy = true
        Task {
            var count = 0
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
                        let record = try await Task.detached { try LibraryService.trash(file) }.value
                        let index: Int
                        if let batchID = batchIDs[photo.albumID], let found = state.deletionBatches.firstIndex(where: { $0.id == batchID }) { index = found }
                        else {
                            let batch = DeletionBatch(albumID: photo.albumID)
                            batchIDs[photo.albumID] = batch.id; state.deletionBatches.append(batch)
                            index = state.deletionBatches.count - 1
                        }
                        state.deletionBatches[index].records.append(record)
                        try persist(); count += 1
                        try await Task.detached{try PhotoMarkStorage.consumeRejection(file)}.value
                    }
                    state.rejected.remove(photo.id); try persist()
                }
            } catch { self.error = "已移入废纸篓 \(count) 个文件：\(error.localizedDescription)。已完成部分可按批次撤销。" }
            await reloadAlbums()
            status = "已将 \(count) 个文件移入废纸篓，按相册和操作批次记录。"
            busy = false
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
