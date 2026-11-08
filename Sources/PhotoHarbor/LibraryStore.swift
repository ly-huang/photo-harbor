import SwiftUI
import AppKit

@MainActor final class LibraryStore: ObservableObject {
    @Published var state = SavedState() {
        didSet {
            if oldValue.rejected != state.rejected { rejectedCache = nil }
            if (filter == "待删除" && oldValue.rejected != state.rejected) ||
                (!search.isEmpty && oldValue.albums != state.albums) { visibleCache = nil }
        }
    }
    @Published var photos: [Photo] = [] {
        didSet {
            visibleCache = nil
            rejectedCache = nil
            photosByID = Dictionary(photos.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            albumCounts = photos.reduce(into: [:]) { $0[$1.albumID, default: 0] += 1 }
            unpairedCount = photos.count { !$0.paired }
            ambiguousCount = photos.count { $0.ambiguous }
        }
    }
    private var photosByID: [String: Photo] = [:]
    private(set) var albumCounts: [String: Int] = [:]
    private(set) var unpairedCount = 0
    private(set) var ambiguousCount = 0
    @Published var annotations:[String:PhotoAnnotation]=[:] {
        didSet { if labelFilter != nil { visibleCache = nil } }
    }
    @Published var labelFilter:PhotoLabel? { didSet { visibleCache = nil } }
    @Published var selected: String?
    @Published var filter = "全部照片" { didSet { visibleCache = nil } }
    @Published var album: String? { didSet { visibleCache = nil } }
    @Published private(set) var importedAlbumReveal = UUID()
    @Published var search = "" { didSet { visibleCache = nil } }
    @Published var busy = false
    @Published private(set) var marking = false
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
    struct DeletionProgress {
        let title: String
        let total: Int
        let inLibrary: Bool
        var stage: String
        var completed: Int?
    }
    @Published private(set) var deletionProgress: DeletionProgress?
    @Published var confirmTrash = false
    @Published var history = false
    @Published private(set) var importProgress: Double?
    @Published var cancellationRequested = false
    var viewerController: PhotoViewerController?
    var comparisonController: ComparisonController?
    var comparisonPhotos: [Photo] { comparisonSelection.compactMap { photosByID[$0] } }
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
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.collectionBehavior = behavior
    }
    let stateURL: URL
    var focused: Photo? { selected.flatMap { photosByID[$0] } }
    var albums: [OpenAlbum] { state.albums }
    var albumTitle: String? { albums.first { $0.id == album }?.title }
    private var rejectedCache: [Photo]?
    var rejected: [Photo] {
        guard !state.rejected.isEmpty else { return [] }
        let marked = rejectedCache ?? photos.filter { state.rejected.contains($0.id) }
        rejectedCache = marked
        guard album != nil || labelFilter != nil else { return marked }
        return marked.filter { photo in
            (album == nil || photo.albumID == album) &&
                (labelFilter.map { labels(for: photo).contains($0) } ?? true)
        }
    }
    var undoBatches: [DeletionBatch] { state.deletionBatches.filter { (album == nil || $0.albumID == album) && !unavailable.contains($0.albumID) }.reversed() }
    private var visibleCache: (photos: [Photo], ids: [String])?
    var visibleIDs: [String] {
        _ = visible
        return visibleCache?.ids ?? []
    }
    var visible: [Photo] {
        if let visibleCache { return visibleCache.photos }
        let result = photos.filter { photo in
            (album == nil || photo.albumID == album) &&
            (labelFilter == nil || annotations[photo.id]?.colors.contains(labelFilter!) == true) &&
            (search.isEmpty || photo.name.localizedCaseInsensitiveContains(search) || photo.album.localizedCaseInsensitiveContains(search) || (albums.first { $0.id == photo.albumID }?.title.localizedCaseInsensitiveContains(search) ?? false)) &&
            (filter != "待删除" || state.rejected.contains(photo.id)) &&
            (filter != "未配对" || !photo.paired) &&
            (filter != "待检查" || photo.ambiguous)
        }
        visibleCache = (result, result.map(\.id))
        return result
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
        state.pruneHistory(availableAlbumIDs: Set(state.albums.map(\.id)).subtracting(failed), only: albumIDs)
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
        guard let oldPhoto = photos.first(where: { $0.files.contains { $0.url == url } }) else { return }
        busy = true
        let oldColors = annotations[oldPhoto.id]?.colors ?? []
        await reloadAlbums(only: [oldPhoto.albumID])
        if let edited = photos.first(where: { $0.files.contains(where: { $0.url == url }) }) {
            selected = edited.id
            if !oldColors.isEmpty {
                let annotation=PhotoAnnotation(colors:oldColors,rejected:false)
                do{try await Task.detached{try PhotoMarkStorage.save(annotation,for:edited)}.value;annotations[edited.id]=annotation;state.rejected.remove(edited.id);save()}
                catch{self.error="照片已保存，颜色标记未能更新到新版本：\(error.localizedDescription)"}
            }
        }
        busy = false
    }
    func select(_ photo: Photo) { if selected != photo.id { selected = photo.id } }
    func reconcileSelection() {
        let ids = visibleIDs
        if let selected, ids.contains(selected) { return }
        if selected != ids.first { selected = ids.first }
    }
    private final class CachedMetadata {
        let value: Metadata
        init(_ value: Metadata) { self.value = value }
    }
    private let metadataCache: NSCache<NSString, CachedMetadata> = {
        let cache = NSCache<NSString, CachedMetadata>()
        cache.countLimit = 256
        return cache
    }()
    func cachedMetadata(for photo: Photo) -> Metadata? {
        metadataCache.object(forKey: photo.id as NSString)?.value
    }
    func loadMetadata(for photo: Photo) async -> Metadata? {
        if let cached = cachedMetadata(for: photo) { return cached }
        // Avoid starting a network read for each intermediate selection.
        do { try await Task.sleep(for: .milliseconds(75)) }
        catch { return nil }
        let result = await Task.detached { Metadata.readIfAvailable(photo.preview) }.value
        if let result {
            metadataCache.setObject(CachedMetadata(result), forKey: photo.id as NSString)
        }
        return result
    }
    func labels(for photo:Photo)->Set<PhotoLabel>{annotations[photo.id]?.colors ?? []}
    func toggleLabel(_ label:PhotoLabel,photo:Photo){var a=annotations[photo.id] ?? PhotoAnnotation(rejected:state.rejected.contains(photo.id));if a.colors.contains(label){a.colors.remove(label)}else{a.colors.insert(label)};writeAnnotation(a,photo:photo)}
    func clearLabels(_ photo:Photo){var a=annotations[photo.id] ?? PhotoAnnotation(rejected:state.rejected.contains(photo.id));a.colors=[];writeAnnotation(a,photo:photo)}
    func toggleReject(_ photo: Photo) {
        var a=annotations[photo.id] ?? PhotoAnnotation();a.rejected = !state.rejected.contains(photo.id);writeAnnotation(a,photo:photo)
    }
    func setRejected(_ rejected: Bool, for photos: [Photo]) {
        writeAnnotations(photos.map { photo in
            var value = annotations[photo.id] ?? PhotoAnnotation()
            value.rejected = rejected
            return (photo, value)
        })
    }
    func setLabel(_ label: PhotoLabel, enabled: Bool, for photos: [Photo]) {
        writeAnnotations(photos.map { photo in
            var value = annotations[photo.id] ?? PhotoAnnotation(rejected: state.rejected.contains(photo.id))
            if enabled { value.colors.insert(label) } else { value.colors.remove(label) }
            return (photo, value)
        })
    }
    func clearLabels(for photos: [Photo]) {
        writeAnnotations(photos.map { ($0, PhotoAnnotation(rejected: state.rejected.contains($0.id))) })
    }
    private func writeAnnotation(_ annotation: PhotoAnnotation, photo: Photo) {
        writeAnnotations([(photo, annotation)])
    }
    private func writeAnnotations(_ requested: [(Photo, PhotoAnnotation)]) {
        guard !busy else { return }
        let changes = requested.compactMap { photo, value -> (Photo, PhotoAnnotation)? in
            let previous = annotations[photo.id] ?? PhotoAnnotation(rejected: state.rejected.contains(photo.id))
            guard previous != value else { return nil }
            return (photo, value)
        }
        guard !changes.isEmpty else { return }
        busy = true
        marking = true
        status = "正在保存 \(changes.count) 张照片的标记…"
        Task {
            defer { marking = false; busy = false }
            let results = await Task.detached {
                await withTaskGroup(of: [(String, PhotoAnnotation, String?)].self) { group in
                    let workers = min(3, changes.count)
                    for worker in 0..<workers {
                        group.addTask {
                            var completed: [(String, PhotoAnnotation, String?)] = []
                            for index in stride(from: worker, to: changes.count, by: workers) {
                                let (photo, annotation) = changes[index]
                                do {
                                    if changes.count == 1 { try await PhotoMarkStorage.savePair(annotation, for: photo) }
                                    else { try PhotoMarkStorage.save(annotation, for: photo) }
                                    completed.append((photo.id, annotation, nil))
                                } catch {
                                    completed.append((photo.id, annotation, "\(photo.name)：\(error.localizedDescription)"))
                                }
                            }
                            return completed
                        }
                    }
                    var completed: [(String, PhotoAnnotation, String?)] = []
                    for await result in group { completed += result }
                    return completed
                }
            }.value
            var updated = annotations
            var rejected = state.rejected
            let failures = results.compactMap { $0.2 }
            for (id, annotation, failure) in results where failure == nil {
                updated[id] = annotation
                if annotation.rejected { rejected.insert(id) } else { rejected.remove(id) }
            }
            annotations = updated
            if state.rejected != rejected { state.rejected = rejected; save() }
            if labelFilter != nil || filter == "待删除" { reconcileSelection() }
            status = "已保存 \(results.count - failures.count)/\(results.count) 张照片的标记。"
            if !failures.isEmpty { error = "\(failures.count) 张照片的标记保存失败。\n" + failures.prefix(3).joined(separator: "\n") }
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
            NSApp.activate()
            if window.styleMask.contains(.fullScreen) {
                window.makeKeyAndOrderFront(nil); window.orderFrontRegardless()
                NSRunningApplication.current.activate(options: [.activateAllWindows])
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
    func deleteRejected(permanently: Bool = false, recycle: (([URL]) async -> ([URL: URL], String?))? = nil) {
        deletePhotos(rejected, permanently: permanently, recycle: recycle)
    }

    func deletePhotos(_ targets: [Photo], permanently: Bool,
                      recycle: (([URL]) async -> ([URL: URL], String?))? = nil,
                      completion: ((String?) -> Void)? = nil) {
        guard trusted, !busy, !editorActive, !targets.isEmpty else {
            completion?("当前无法删除照片，请稍后重试。")
            return
        }
        let action = permanently ? "直接删除" : "移入废纸篓"
        busy = true
        status = "正在核对照片及配对关系…"
        Task {
            deletionProgress = DeletionProgress(title: action, total: targets.count, inLibrary: completion == nil, stage: status)
            defer { deletionProgress = nil; busy = false }
            var count = 0
            var changedAlbums: Set<String> = []
            var failures: [String] = []
            do {
                let files = targets.flatMap { photo in photo.files.map { (photo.albumID, $0) } }
                guard Set(files.map { $0.1.url }).count == files.count else {
                    throw LibraryError.message("多个待删除项目指向同一文件，请重新扫描后检查。")
                }
                let groups = try Dictionary(grouping: targets, by: \.albumID).map { id, photos in
                    guard let owner = state.albums.first(where: { $0.id == id }) else {
                        throw LibraryError.message("相册已关闭。")
                    }
                    return (photos, owner.roots)
                }
                try await withThrowingTaskGroup(of: Void.self) { group in
                    var pending = groups.makeIterator()
                    for _ in 0..<min(3, groups.count) {
                        if let (photos, roots) = pending.next() {
                            group.addTask { try LibraryService.validateDeletion(photos, roots: roots) }
                        }
                    }
                    while try await group.next() != nil {
                        if let (photos, roots) = pending.next() {
                            group.addTask { try LibraryService.validateDeletion(photos, roots: roots) }
                        }
                    }
                }
                if permanently {
                    status = "正在直接删除照片…"
                    deletionProgress?.stage = status
                    deletionProgress?.completed = 0
                    await withTaskGroup(of: (String, Int, String?).self) { group in
                        var pending = targets.makeIterator()
                        for _ in 0..<min(4, targets.count) {
                            if let photo = pending.next() {
                                group.addTask { Self.removePhotoFiles(photo) }
                            }
                        }
                        for await (albumID, removed, problem) in group {
                            if let photo = pending.next() {
                                group.addTask { Self.removePhotoFiles(photo) }
                            }
                            count += removed
                            if removed > 0 { changedAlbums.insert(albumID) }
                            if let problem { failures.append(problem) }
                            deletionProgress?.completed? += 1
                        }
                    }
                } else {
                    try persist()
                    try await Task.detached {
                        for (_, file) in files { try LibraryService.validateRemoval(file) }
                    }.value
                    status = "正在等待系统移入废纸篓…"
                    deletionProgress?.stage = status
                    let urls = files.map { $0.1.url }
                    let (locations, problem): ([URL: URL], String?)
                    if let recycle { (locations, problem) = await recycle(urls) }
                    else { (locations, problem) = await Self.recycleFiles(urls) }
                    var batches: [String: DeletionBatch] = [:]
                    var moved: [PhotoFile] = []
                    for (albumID, file) in files {
                        guard let destination = locations[file.url] else { continue }
                        moved.append(file)
                        batches[albumID, default: DeletionBatch(albumID: albumID)].records.append(
                            TrashRecord(original: file.url, trashed: destination)
                        )
                    }
                    count = moved.count
                    changedAlbums.formUnion(batches.keys)
                    if !batches.isEmpty {
                        state.deletionBatches.append(contentsOf: batches.values.sorted { $0.albumID < $1.albumID })
                        do { try persist() }
                        catch { failures.append("无法保存废纸篓撤销记录。\(error.localizedDescription)") }
                        let markFailures = await Task.detached { [moved] in
                            moved.compactMap { file -> String? in
                                do { try PhotoMarkStorage.consumeRejection(file); return nil }
                                catch { return "无法清除「\(file.url.lastPathComponent)」的待删除标记。\(error.localizedDescription)" }
                            }
                        }.value
                        failures.append(contentsOf: markFailures)
                    }
                    if count != files.count {
                        failures.append("\(files.count - count) 个文件未确认移入废纸篓。NAS 共享需要支持 macOS 废纸篓并允许移动。")
                    }
                    if let problem { failures.append(problem) }
                }
            } catch { failures.append(error.localizedDescription) }
            if !changedAlbums.isEmpty {
                status = "正在更新受影响的相册…"
                deletionProgress?.stage = status
                deletionProgress?.completed = nil
                await reloadAlbums(only: changedAlbums)
            }
            deletionProgress = nil
            if !failures.isEmpty {
                status = count == 0 ? "未能\(action)。" : "\(action)完成，已处理 \(count) 个文件，有错误。"
                let message = ([status] + Array(failures.prefix(5)) + (failures.count > 5 ? ["另有 \(failures.count - 5) 条错误。"] : [])).joined(separator: "\n")
                if let completion { completion(message) } else { self.error = message }
            } else {
                status = permanently ? "已直接删除 \(count) 个文件。" : "已将 \(count) 个文件移入废纸篓，按相册和操作批次记录。"
                completion?(nil)
            }
        }
    }

    private static func recycleFiles(_ urls: [URL]) async -> ([URL: URL], String?) {
        await withCheckedContinuation { continuation in
            NSWorkspace.shared.recycle(urls) { locations, error in
                continuation.resume(returning: (locations, error?.localizedDescription))
            }
        }
    }

    nonisolated private static func removePhotoFiles(_ photo: Photo) -> (String, Int, String?) {
        var removed = 0
        var markFailures: [String] = []
        for file in photo.files {
            do {
                try LibraryService.deletePermanently(file)
                removed += 1
            } catch {
                return (photo.albumID, removed, "无法直接删除「\(file.url.lastPathComponent)」。\(error.localizedDescription)")
            }
            do { try PhotoMarkStorage.consumeRejection(file) }
            catch { markFailures.append("文件已删除，但无法更新「\(file.url.lastPathComponent)」的标记。\(error.localizedDescription)") }
        }
        return (photo.albumID, removed, markFailures.isEmpty ? nil : markFailures.joined(separator: "\n"))
    }

    func dismissBatch(_ id: String) { state.deletionBatches.removeAll { $0.id == id }; save() }
    private var historyRefresh: Task<Void, Never>?
    private var lastHistoryRefresh: ContinuousClock.Instant?
    func refreshHistory(force: Bool = false) {
        guard !busy, historyRefresh == nil else { return }
        if !force, let lastHistoryRefresh, lastHistoryRefresh.duration(to: .now) < .seconds(10) { return }
        let albums = state.albums
        let batches = state.deletionBatches
        let files = Set(batches.flatMap(\.records).map(\.trashed))
        historyRefresh = Task {
            defer { historyRefresh = nil }
            let (available, missing) = await Task.detached {
                let available = Set(albums.filter { (try? $0.roots.validate()) != nil }.map(\.id))
                let missing = Set(files.filter { !FileManager.default.fileExists(atPath: $0.path) })
                return (available, missing)
            }.value
            guard !busy, state.albums == albums, state.deletionBatches == batches else { return }
            lastHistoryRefresh = .now
            let offline = Set(albums.map(\.id)).subtracting(available)
            if unavailable != offline { unavailable = offline }
            var updated = batches.filter { available.contains($0.albumID) }
            for index in updated.indices {
                updated[index].records.removeAll { missing.contains($0.trashed) }
            }
            updated.removeAll { $0.records.isEmpty }
            if updated != batches { state.deletionBatches = updated; save() }
        }
    }
    func undoTrash(_ batchID: String? = nil) {
        guard !busy else { return }
        guard let batch = undoBatches.first(where: { batchID == nil || $0.id == batchID }), let owner = state.albums.first(where: { $0.id == batch.albumID }) else { return }
        busy = true
        Task {
            let (restored, missing, handled, failures) = await Task.detached {
                var restored = 0, missing = 0
                var handled: Set<URL> = []
                var failures: [String] = []
                do { try owner.roots.validate() }
                catch { return (restored, missing, handled, [error.localizedDescription]) }
                for record in batch.records {
                    do {
                        if FileManager.default.fileExists(atPath: record.trashed.path) {
                            try LibraryService.restore(record, roots: owner.roots)
                            restored += 1
                        } else {
                            missing += 1
                        }
                        handled.insert(record.trashed)
                    } catch {
                        failures.append(record.original.lastPathComponent + "：" + error.localizedDescription)
                        if (try? owner.roots.validate()) == nil { break }
                    }
                }
                return (restored, missing, handled, failures)
            }.value
            if let index = state.deletionBatches.firstIndex(where: { $0.id == batch.id }) {
                state.deletionBatches[index].records.removeAll { handled.contains($0.trashed) }
            }
            // The scoped reload persists the updated batch once. An interrupted
            // restore is reconciled later from the remaining Trash entries.
            await reloadAlbums(only: [owner.id])
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
