import SwiftUI
import AppKit

private let canvas = Color(red: 0.09, green: 0.10, blue: 0.115)
private let panel = Color(red: 0.125, green: 0.137, blue: 0.16)
private let accent = Color(red: 0.51, green: 0.72, blue: 0.96)

struct LibraryView: View {
    @EnvironmentObject var store: LibraryStore
    @ViewState private var thumbnailSize: Double = 210
    @ViewState private var showingSelection = false
    @ViewState private var exportPhotos: [Photo] = []
    @ViewState private var showingExport = false
    @ViewState private var confirmCloseAll = false
    @ViewState private var confirmDirectDelete = false
    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 208)
            Divider()
            VStack(spacing: 0) {
                header
                Divider()
                if store.photos.isEmpty && store.scanningAlbums {
                    ContentUnavailableView("正在扫描相册", systemImage: "folder", description: Text(store.status))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if store.photos.isEmpty { emptyState }
                else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: thumbnailSize), spacing: 18)], spacing: 20) {
                            ForEach(store.visible) { photo in PhotoCard(photo: photo) }
                        }.padding(24)
                    }
                    .overlay { if store.visible.isEmpty { ContentUnavailableView("没有符合条件的照片", systemImage: "line.3.horizontal.decrease.circle", description: Text("尝试切换相册、筛选或搜索词。")) } }
                }
                Divider()
                HStack {
                    if store.busy { ProgressView().controlSize(.small) }
                    Text(store.status).lineLimit(1).help(store.status)
                    Spacer()
                    if let progress = store.importProgress {
                        ProgressView(value: progress).frame(width: 80)
                        Button("停止导入") { store.cancellationRequested = true }.buttonStyle(.borderless)
                    }
                    Image(systemName: "internaldrive"); Text("本地照片库")
                }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 20).frame(height: 38)
            }.background(canvas)
            Divider()
            inspector.frame(width: 248)
        }
        .tint(accent)
        .background(WindowTitleHider())
        .background(MainToolbar(store: store))
        .sheet(isPresented: $store.settings) { SettingsView() }
        .sheet(isPresented: $store.importing) { ImportView() }
        .sheet(isPresented: $store.history) { DeletionHistoryView() }
        .sheet(isPresented: $showingExport) {
            PhotoExportView(photos: exportPhotos, protected: Set(store.photos.flatMap(\.files).map(\.url)))
        }
        .alert("操作未完成", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) { Button("知道了") { store.error = nil } } message: { Text(store.error ?? "") }
        .confirmationDialog("将 \(store.rejected.count) 张照片移入废纸篓？", isPresented: $store.confirmTrash, titleVisibility: .visible) {
            Button("移入废纸篓", role: .destructive) { store.deleteRejected() }
        } message: {
            Text("共 \(store.rejected.reduce(0) { $0 + $1.files.count }) 个 JPG / ARW 文件，\(readableBytes(store.rejected.reduce(0) { $0 + $1.bytes }))。操作前会再次核对配对关系；有歧义的照片不会删除。")
        }
        .alert("直接删除 \(store.rejected.count) 张照片？", isPresented: $confirmDirectDelete) {
            Button("取消", role: .cancel) {}
            Button("直接删除", role: .destructive) { store.deleteRejected(permanently: true) }
        } message: {
            Text("将删除共 \(store.rejected.reduce(0) { $0 + $1.files.count }) 个 JPG / ARW 文件，包含配对文件。此操作绕过系统废纸篓，无法通过拾影撤销。")
        }
        .alert("关闭所有相册？", isPresented: $confirmCloseAll) {
            Button("取消", role: .cancel) {}
            Button("关闭所有相册") { store.closeAllAlbums() }
        } message: {
            Text("将关闭列表中的 \(store.albums.count) 个相册，并清除相关的废纸篓撤销记录。磁盘上的照片和标记会保留。")
        }
        .task { store.scanOnLaunch() }
        .task(id: store.selected) { await store.loadMetadata() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in if !store.busy { store.refreshHistory() } }
        .onChange(of: store.visible.map(\.id)) { _, _ in store.reconcileSelection() }
    }
    private var sidebar: some View {
        let albumCounts = store.photos.reduce(into: [String: Int]()) { $0[$1.albumID, default: 0] += 1 }
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "square.stack.3d.up.fill").font(.title2).foregroundStyle(accent)
                VStack(alignment: .leading, spacing: 3) { Text("拾影").font(.title2.weight(.semibold)); Text("Photo Harbor").font(.caption).foregroundStyle(.secondary) }
            }.padding(24)
            Text("照片库").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 24).padding(.bottom, 9)
            nav("全部照片", icon: "square.grid.2x2", count: store.photos.count)
            nav("未配对", icon: "link", count: store.photos.filter { !$0.paired }.count)
            nav("待检查", icon: "exclamationmark.triangle", count: store.photos.filter(\.ambiguous).count)
            nav("待删除", icon: "trash", count: store.rejected.count)
            HStack {
                Text("拍摄相册")
                Spacer()
                Text("\(store.albums.count)")
                Button { confirmCloseAll = true } label: {
                    Label("关闭所有相册", systemImage: "xmark.circle").labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help("关闭所有相册，保留磁盘照片")
                .disabled(store.busy || store.editorActive || store.albums.isEmpty)
            }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 24).padding(.top, 30).padding(.bottom, 10)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(store.albums) { album in
                            let paths = [album.roots.jpg, album.roots.raw].filter { !$0.isEmpty }
                            let urls = paths.map { URL(fileURLWithPath: $0, isDirectory: true) }
                            Button {
                                store.album = album.id; store.filter = "全部照片"
                            } label: {
                                HStack(alignment: .top, spacing: 9) { Image(systemName: store.unavailable.contains(album.id) ? "externaldrive.badge.exclamationmark" : "folder").foregroundStyle(accent); Text(album.title).lineLimit(2); Spacer(minLength: 0); Text("\(albumCounts[album.id, default: 0])").font(.caption2).foregroundStyle(.secondary) }
                                    .font(.system(size: 12)).padding(.horizontal, 12).padding(.vertical, 9)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(store.album == album.id ? accent.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 6))
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain).disabled(store.busy && !store.scanningAlbums)
                                .id(album.id)
                                .help(paths.joined(separator: "\n"))
                                .overlay {
                                    AlbumContextMenu(roots: urls, canClose: !store.busy && !store.editorActive) {
                                        store.closeAlbum(album.id)
                                    }
                                }
                        }
                    }.padding(.horizontal, 12)
                }
                .onChange(of: store.importedAlbumReveal) {
                    if let album = store.album { proxy.scrollTo(album, anchor: .top) }
                }
            }
            Spacer(minLength: 16)
            VStack(alignment: .leading, spacing: 8) {
                Label("双格式，一起管理", systemImage: "link").font(.caption).foregroundStyle(accent)
                Text("JPG 轻松浏览\nARW 保留每一份细节").font(.caption).foregroundStyle(.secondary).lineSpacing(4)
            }.padding(20)
        }.background { SidebarMaterial().ignoresSafeArea() }
    }
    private func nav(_ title: String, icon: String, count: Int) -> some View {
        Button { store.filter = title; store.album = nil } label: {
            HStack { Image(systemName: icon).frame(width: 20); Text(title); Spacer(); Text("\(count)").font(.caption).foregroundStyle(.secondary) }
                .font(.system(size: 13)).padding(.horizontal, 12).padding(.vertical, 10)
                .background(store.filter == title && store.album == nil ? accent.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 6))
                .foregroundStyle(store.filter == title && store.album == nil ? accent : .primary)
                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain).padding(.horizontal, 12).padding(.vertical, 2)
    }
    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text(store.albumTitle ?? store.filter).font(.system(size: 25, weight: .semibold))
                Text("\(store.visible.count) 张").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("对比所选图片（\(store.comparisonPhotos.count)/4）") { store.showComparison() }.disabled(!(2...4).contains(store.comparisonPhotos.count)).help("按住 ⌘ 选择二至四张照片，或右键加入对比")
                Button { showingSelection.toggle() } label: {
                    Label("已选照片（\(store.comparisonPhotos.count)）", systemImage: "photo.stack")
                }.help("快速查看和移出对比选择")
                    .popover(isPresented: $showingSelection, arrowEdge: .top) {
                        ComparisonSelectionPopover(openComparison: { showingSelection = false; store.showComparison() })
                            .environmentObject(store)
                    }
                if store.filter == "待删除" {
                    Menu("删除操作") {
                        Button("移入废纸篓") { store.confirmTrash = true }
                        Button("直接删除…", role: .destructive) { confirmDirectDelete = true }
                    }.disabled(store.busy || !store.trusted || store.rejected.isEmpty)
                }
            }
            HStack {
                HStack { Image(systemName: "magnifyingglass"); TextField("搜索文件名或相册", text: $store.search).textFieldStyle(.plain) }
                    .font(.system(size: 12)).padding(8).frame(maxWidth: 280).background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                Spacer()
                Menu {
                    ForEach(PhotoLabel.allCases,id:\.self){label in Button {store.labelFilter=label;store.reconcileSelection()} label:{Label{Text(label.rawValue)} icon:{Image(nsImage:label.menuImage).renderingMode(.original)}.labelStyle(.titleAndIcon)}}
                } label:{Label(store.labelFilter.map{"\($0.rawValue)标记"} ?? "颜色标记",systemImage:"tag")}
                if store.labelFilter != nil{Button{store.labelFilter=nil;store.reconcileSelection()}label:{Image(systemName:"xmark.circle.fill")}.buttonStyle(.borderless).help("清除标记筛选")}
                if store.labelFilter != nil {
                    Button { exportPhotos = store.visible; showingExport = true } label: {
                        Label("导出筛选照片", systemImage: "square.and.arrow.up")
                    }.disabled(store.busy || store.visible.isEmpty).help("导出当前颜色、相册、搜索及分类筛选后的照片")
                }
                Image(systemName: "square.grid.3x3").foregroundStyle(.secondary)
                Slider(value: $thumbnailSize, in: 150...320).frame(width: 90).help("缩略图大小")
            }
        }.padding(.horizontal, 24).padding(.vertical, 12)
    }
    private var emptyState: some View {
        VStack(spacing: 22) {
            Spacer()
            Image(systemName: "rectangle.stack.badge.plus").font(.system(size: 64, weight: .ultraLight)).foregroundStyle(accent)
            VStack(spacing: 10) {
                Text("给每一次拍摄，一个清楚的归处").font(.title2.weight(.medium))
                Text("打开已有照片目录，在原位配对浏览；\n导入新拍摄时，按日期和地点分类复制。").foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(6)
            }
            HStack(spacing: 12) {
                Button("打开相册") { store.settings = true }.buttonStyle(.borderedProminent).disabled(store.busy)
                Button("导入新照片") { store.importing = true }.disabled(store.busy && !store.scanningAlbums)
            }
            Text("源文件保留 · 删除进入系统废纸篓").font(.caption).foregroundStyle(.tertiary)
            Spacer()
        }.frame(maxWidth: .infinity)
    }
    private var inspector: some View {
        VStack(spacing: 0) {
            ScrollView { inspectorDetails.id(store.focused?.id) }
            Divider()
            HStack {
                Button { store.undoTrash() } label: { Label("撤销最近删除", systemImage: "arrow.uturn.backward") }.disabled(store.busy || store.undoBatches.isEmpty)
                Spacer(minLength: 4)
                Button { store.history = true } label: { Image(systemName: "clock.arrow.circlepath") }.help("按相册查看删除批次")
            }.font(.caption).padding(12)
        }.background(panel)
    }
    private var inspectorDetails: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("照片信息").font(.system(size: 13, weight: .semibold))
            if let photo = store.focused {
                PhotoImage(file: photo.previewFile).frame(height: 144).clipShape(RoundedRectangle(cornerRadius: 5))
                VStack(alignment: .leading, spacing: 6) {
                    Text(photo.name).font(.title3.weight(.semibold)).textSelection(.enabled)
                    Text(photo.album).font(.caption).foregroundStyle(.secondary)
                }
                Label(photo.ambiguous ? "同名歧义，需人工检查" : photo.paired ? "JPG 与 ARW 已配对" : "仅找到一种格式", systemImage: photo.ambiguous ? "exclamationmark.triangle" : photo.paired ? "link" : "link.badge.plus").font(.caption).foregroundStyle(photo.ambiguous ? .orange : accent)
                Divider()
                info("拍摄时间", store.metadata.date?.formatted(date: .numeric, time: .standard) ?? "无拍摄时间信息")
                info("相机", store.metadata.camera)
                if !store.metadata.dimensions.isEmpty { info("尺寸", store.metadata.dimensions) }
                if !store.metadata.exposure.isEmpty { info("光圈", store.metadata.exposure) }
                if !store.metadata.gps.isEmpty { info("GPS", store.metadata.gps) }
                info("文件总大小", readableBytes(photo.bytes))
                Divider()
                HStack {
                    Text("照片评测").font(.headline)
                    Spacer()
                    Button(store.assessments[photo.id] == nil ? "评测" : "重新评测") { store.assessPhoto(photo) }.disabled(store.assessing.contains(photo.id))
                }
                if store.assessing.contains(photo.id) { ProgressView("正在本机评测…").font(.caption) }
                if let stats = store.assessments[photo.id] {
                    AssessmentDetails(stats: stats, compact: false)
                } else if let issue = store.assessmentErrors[photo.id] { Text(issue).font(.caption).foregroundStyle(.orange) }
                else { Text("右键照片选择“评测此图片”，在本机生成审美和曝光参考。").font(.caption).foregroundStyle(.secondary) }
                Divider()
                ForEach(photo.files, id: \.url) { file in
                    Button { NSWorkspace.shared.activateFileViewerSelecting([file.url]) } label: {
                        HStack(alignment: .top) { Image(systemName: "doc"); VStack(alignment: .leading, spacing: 4) { Text(file.isRAW ? "ARW 原片" : "JPG 照片").foregroundStyle(.primary); Text(file.url.path).lineLimit(3).foregroundStyle(.secondary) }; Spacer(minLength: 0); Image(systemName: "arrow.up.right") }.font(.caption)
                    }.buttonStyle(.plain).help("在 Finder 中显示")
                }
                Spacer()
                Button { store.showViewer() } label: { Label("查看大图", systemImage: "arrow.up.left.and.arrow.down.right").frame(maxWidth: .infinity) }
                Button { store.toggleReject(photo) } label: { Label(store.state.rejected.contains(photo.id) ? "取消待删除" : "标记待删除", systemImage: store.state.rejected.contains(photo.id) ? "arrow.uturn.backward" : "trash").frame(maxWidth: .infinity) }.disabled(store.busy)
                Text("⌫ 标记 · Return 大图").font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity)
            } else {
                Spacer(); Image(systemName: "viewfinder").font(.largeTitle).foregroundStyle(.tertiary).frame(maxWidth: .infinity)
                Text("选择一张照片查看详情").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity); Spacer()
            }
        }.padding(18).frame(maxHeight: .infinity).background(panel)
    }
    private func info(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) { Text(label).font(.caption2).foregroundStyle(.secondary); Text(value).font(.system(size: 12)).textSelection(.enabled).id(value) }
    }
}

struct PhotoCard: View {
    @EnvironmentObject var store: LibraryStore
    let photo: Photo
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ZStack(alignment: .topTrailing) {
                PhotoImage(file: photo.previewFile, priority: .high).aspectRatio(1.4, contentMode: .fit)
                VStack(alignment: .trailing, spacing: 5) {
                    if store.state.rejected.contains(photo.id) { Image(systemName: "trash.fill").font(.caption).padding(8).background(.red.opacity(0.85), in: Circle()) }
                    if let score = store.assessments[photo.id]?.aesthetics {
                        ScoreBadge(score: score)
                    }
                    if store.assessing.contains(photo.id) { ProgressView().controlSize(.small).padding(6).background(.black.opacity(0.6), in: Circle()) }
                }.padding(8)
                if let index = store.comparisonSelection.firstIndex(of: photo.id) {
                    Text("\(index + 1)").font(.caption.bold()).frame(width: 27, height: 27)
                        .modifier(PhotoGlass(radius: 20)).foregroundStyle(.blue)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(8)
                        .allowsHitTesting(false)
                }
            }.clipShape(RoundedRectangle(cornerRadius: 6))
            HStack {
                Text(photo.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                if !store.labels(for:photo).isEmpty {PhotoLabelDots(labels:store.labels(for:photo))}
                Spacer(minLength: 3)
                Text(photo.ambiguous ? "待检查" : photo.paired ? "JPG + ARW" : photo.files[0].isRAW ? "ARW" : "JPG")
                    .font(.system(size: 9, weight: .medium)).foregroundStyle(photo.ambiguous ? .orange : .secondary)
            }.padding(.horizontal, 3)
        }.padding(6)
        .background(store.selected == photo.id ? accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(store.selected == photo.id ? accent : .clear, lineWidth: 1.5))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { NSApp.keyWindow?.makeFirstResponder(nil); store.select(photo); store.showViewer() }
        .onTapGesture { NSApp.keyWindow?.makeFirstResponder(nil); if NSEvent.modifierFlags.contains(.command) { store.toggleComparison(photo) }; store.select(photo) }
        .contextMenu {
            Button("查看大图") { store.select(photo); store.showViewer() }
            Button(store.comparisonSelection.contains(photo.id) ? "移出对比" : "加入对比（最多四张）") { store.toggleComparison(photo) }
            if store.comparisonSelection.contains(photo.id) { Button("对比所选图片") { store.showComparison() }.disabled(!(2...4).contains(store.comparisonPhotos.count)) }
            Button("评测此图片") { store.assessPhoto(photo) }.disabled(store.assessing.contains(photo.id))
            Divider()
            PhotoLabelMenu(photo:photo)
            Button(store.state.rejected.contains(photo.id) ? "取消待删除" : "标记待删除") { store.toggleReject(photo) }.disabled(store.busy)
            Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting(photo.files.map(\.url)) }
        }.accessibilityElement(children: .contain).accessibilityAddTraits(.isButton).accessibilityLabel(photo.name)
    }
}

struct SettingsView: View {
    @EnvironmentObject var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @ViewState private var roots = Roots()
    @ViewState private var title = ""
    @ViewState private var splitOverride: Bool?
    @ViewState private var opening = false
    @ViewState private var problem: String?
    private var splitFolders: Bool {
        splitOverride ?? [roots.jpg, roots.raw].contains { path in
            ["JPG", "RAW"].contains((path as NSString).lastPathComponent.uppercased())
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("打开相册").font(.title2.weight(.semibold))
            Text("在原目录配对和浏览，不移动、不复制、不重新分类。新相册会追加到左侧列表。").foregroundStyle(.secondary)
            Group {
                folderRow("JPG 目录（可选）", path: $roots.jpg)
                folderRow("RAW 目录（可选）", path: $roots.raw)
                Toggle("按子目录打开相册", isOn: Binding(get: { splitFolders }, set: { splitOverride = $0 }))
                if splitFolders {
                    Text("JPG 和 RAW 下同名的一级子目录合为一个相册，只有一种格式的子目录也可以打开。").font(.caption).foregroundStyle(.secondary)
                } else {
                    TextField("相册名称（可选）", text: $title).textFieldStyle(.roundedBorder)
                }
            }.disabled(opening)
            Text("至少填写一个目录。相同的相对路径和文件名优先配对；其余仅在文件名唯一时配对。").font(.caption).foregroundStyle(.secondary)
            if let problem { Text(problem).foregroundStyle(.orange).font(.caption) }
            HStack {
                if opening { ProgressView("正在查找子目录…").controlSize(.small) }
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction).disabled(opening)
                Button("打开并扫描") {
                    opening = true
                    problem = nil
                    Task {
                        defer { opening = false }
                        do {
                            if splitFolders { try await store.applyAlbumFolders(roots) }
                            else { try store.applyRoots(roots, title: title) }
                        } catch { problem = error.localizedDescription }
                    }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(opening || store.busy || (roots.jpg.isEmpty && roots.raw.isEmpty))
            }
        }.padding(28).frame(width: 590)
    }
    private func folderRow(_ title: String, path: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: "folder").font(.headline)
            HStack { TextField("选择文件夹", text: path).textFieldStyle(.roundedBorder); Button("选择…") { if let result = store.chooseDirectory() { path.wrappedValue = result } }; if !path.wrappedValue.isEmpty { Button("清除") { path.wrappedValue = "" } } }
        }
    }
}

struct ImportView: View {
    @EnvironmentObject var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @ViewState private var source = ""
    @ViewState private var selectedSources: [URL] = []
    @ViewState private var location = ""
    @ViewState private var lookupGPS = true
    @ViewState private var jpgDestination = ""
    @ViewState private var rawDestination = ""
    @ViewState private var plan: [ImportItem] = []
    @ViewState private var previewTask: Task<Void, Never>?
    @ViewState private var confirmingImport = false
    @ViewState private var conflictChoice = LibraryService.ImportConflictChoice.skip
    @ViewState private var problem: String?
    private var planning: Bool { previewTask != nil || confirmingImport }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("导入一次拍摄").font(.title2.weight(.semibold))
            Text("按 YYYYMMDD_地点 分类，分别复制到 JPG 和 RAW 文件夹。").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    if selectedSources.isEmpty {
                        TextField("来源文件夹或相机存储卡", text: $source)
                    } else {
                        Text("已选择 \(selectedSources.count) 个来源文件夹")
                        Spacer()
                        Button("清空") { selectedSources = []; source = "" }
                    }
                    Button("选择文件夹…") { chooseSources() }
                }
                if !selectedSources.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(selectedSources, id: \.self) { url in
                                Text(url.path).font(.caption).textSelection(.enabled)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(height: 76)
                }
            }.disabled(planning)
            TextField("地点（可选）：留空读取照片信息，无法获取时使用“未知”", text: $location).disabled(planning)
            if location.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Toggle("在线根据 GPS 补全地点", isOn: $lookupGPS)
                    .help("关闭后仍读取照片内已有地点，找不到时使用「未知」，可缩短预览时间。")
                    .disabled(planning)
            }
            destinationRow("JPG 存放位置", path: $jpgDestination, fallback: destinationRoots.jpg)
            destinationRow("RAW 存放位置", path: $rawDestination, fallback: destinationRoots.raw)
            Text("存放位置留空时，在列表中第一个来源文件夹同级创建 JPG、RAW；两边使用相同分类文件夹名称。").font(.caption).foregroundStyle(.secondary)
            if selectedSources.count > 1 {
                Text("整批共用存放位置。本批同名照片会自动改名，JPG 和 RAW 共用后缀。").font(.caption).foregroundStyle(.secondary)
            }
            if previewTask != nil {
                ProgressView("正在生成导入预览…")
            } else if confirmingImport {
                ProgressView(conflictChoice == .replace && plan.contains(where: \.conflicts)
                    ? "正在核验同名目标文件…" : "正在准备导入…")
            }
            if let problem {
                ScrollView {
                    Text(problem)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.frame(height: problem.contains("\n") ? 150 : 36)
            }
            if !plan.isEmpty {
                Divider()
                let conflicts = plan.filter(\.conflicts).count
                if conflicts > 0 {
                    Picker("\(conflicts) 个同名目标", selection: $conflictChoice) {
                        ForEach(LibraryService.ImportConflictChoice.allCases, id: \.self) { choice in
                            Text(choice.rawValue).tag(choice)
                        }
                    }.disabled(planning)
                    if conflictChoice == .replace {
                        Text("替换会覆盖同名目标照片，无法通过拾影撤销。").font(.caption).foregroundStyle(.orange)
                    } else {
                        Text("同一张照片的 JPG 和 RAW 会一起跳过或改名。").font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack { Text("导入计划").font(.headline); Spacer(); Text("\(plan.count) 个文件 · \(readableBytes(plan.reduce(0) { $0 + $1.bytes }))").foregroundStyle(.secondary) }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(plan) { item in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.source.lastPathComponent).font(.system(size: 12, weight: .medium))
                                if item.conflicts { Text("目标已存在").font(.caption2).foregroundStyle(.orange) }
                                Text(item.destination.path).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }.frame(height: 190)
                if plan.contains(where: \.fallbackDate) { Label("部分文件没有拍摄时间，将使用文件修改日期。请核对目标日期。", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
            }
            Text("逐文件校验复制内容，来源照片保留。地点优先使用填写内容，其次读取照片地点，再按选项在线反查 GPS，无法获取时归为“未知”。").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(previewTask == nil ? "取消" : "取消预览") {
                    if previewTask != nil { cancelPreview() } else { dismiss() }
                }.keyboardShortcut(.cancelAction).disabled(confirmingImport)
                Spacer()
                if plan.isEmpty {
                    Button("预览导入计划") { makePlan() }.buttonStyle(.borderedProminent).disabled(planning || sources.isEmpty)
                } else {
                    Button("重新规划") { plan = []; problem = nil }.disabled(planning)
                    Button(conflictChoice == .replace && plan.contains(where: \.conflicts) ? "替换并导入" : "复制并校验") { prepareImport() }.buttonStyle(.borderedProminent).disabled(planning || store.busy)
                }
            }
        }.textFieldStyle(.roundedBorder).padding(28).frame(width: 680)
        .onDisappear { cancelPreview() }
        .onChange(of: source) { _, _ in plan = []; problem = nil }
        .onChange(of: selectedSources) { _, _ in plan = []; problem = nil }
        .onChange(of: location) { _, _ in plan = []; problem = nil }
        .onChange(of: lookupGPS) { _, _ in plan = []; problem = nil }
        .onChange(of: jpgDestination) { _, _ in plan = []; problem = nil }
        .onChange(of: rawDestination) { _, _ in plan = []; problem = nil }
    }
    private var sources: [URL] {
        if !selectedSources.isEmpty { return selectedSources }
        let path = source.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? [] : [URL(fileURLWithPath: path)]
    }
    private func chooseSources() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "选择来源"
        guard panel.runModal() == .OK, let first = panel.urls.first else { return }
        source = first.path
        selectedSources = panel.urls.count > 1 ? panel.urls : []
    }
    private var destinationRoots: Roots {
        let parent = (sources.first ?? URL(fileURLWithPath: source)).deletingLastPathComponent()
        return Roots.importDestinations(jpg: jpgDestination.isEmpty ? parent.appendingPathComponent("JPG").path : jpgDestination,
                     raw: rawDestination.isEmpty ? parent.appendingPathComponent("RAW").path : rawDestination)
    }
    private func destinationRow(_ title: String, path: Binding<String>, fallback: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.medium))
            HStack {
                TextField(sources.isEmpty ? "可选，默认放在来源文件夹同级" : fallback, text: path)
                Button("选择…") { if let selected = store.chooseDirectory() { path.wrappedValue = selected } }
                if !path.wrappedValue.isEmpty { Button("默认") { path.wrappedValue = "" } }
            }
        }.disabled(planning)
    }
    private func prepareImport() {
        let preview = plan
        let choice = conflictChoice
        let roots = destinationRoots
        confirmingImport = true
        problem = nil
        Task {
            defer { confirmingImport = false }
            do {
                let resolved = try await Task.detached {
                    try LibraryService.resolveImportConflicts(preview, choice: choice)
                }.value
                guard !resolved.isEmpty else { problem = "已跳过全部重名照片，没有文件需要导入。"; return }
                guard !store.busy else { problem = "照片库正在处理其他任务，请稍后重试。"; return }
                store.executeImport(resolved, roots: roots)
                dismiss()
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    private func cancelPreview() {
        guard let previewTask else { return }
        previewTask.cancel()
        self.previewTask = nil
    }

    private func makePlan() {
        guard !planning else { return }
        problem = nil
        conflictChoice = .skip
        let roots = destinationRoots
        let urls = sources
        let place = location
        let online = lookupGPS
        previewTask = Task {
            let worker = Task.detached {
                try await LibraryService.importPlanResolvingPlaces(sources: urls, roots: roots, location: place, lookupGPS: online)
            }
            let result = await withTaskCancellationHandler {
                await worker.result
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled else { return }
            previewTask = nil
            switch result {
            case .success(let items):
                plan = items
                if items.isEmpty { problem = "来源目录中没有找到 JPG 或 ARW 文件。" }
            case .failure(let error):
                problem = error.localizedDescription
            }
        }
    }
}

struct ViewerView: View {
    @EnvironmentObject var store: LibraryStore
    @StateObject private var chrome = ChromeState()
    @ViewState private var fitToken = 0
    @StateObject private var info = InspectorState()
    @ViewState private var editingPhoto: Photo?
    private var preloadWindow: [URL] {
        guard let current = store.focused?.preview else { return [] }
        return ViewerImageCache.neighbors(store.visible.map(\.preview), current: current)
    }
    var body: some View {
        HStack(spacing: 0) {
            ZStack {
                Color.black
                if let photo = store.focused {
                    InteractivePhoto(url: photo.preview, fitToken: fitToken, fullScreen: store.viewerFullScreen,
                        navigatorVisible: store.navigatorVisible,
                        evaluate: { evaluate(photo) }, showInfo: { info.reveal(); chrome.reveal() },
                        toggleNavigator: { store.navigatorVisible.toggle() }, labels:store.labels(for:photo),labelChanged:{if let label=$0{store.toggleLabel(label,photo:photo)}else{store.clearLabels(photo)}}, rejected: store.state.rejected.contains(photo.id), navigatorTopInset: 60,
                        previous: { store.navigate(-1) }, next: { store.navigate(1) },
                        mark: { if let current = store.focused { store.toggleReject(current) } })
                        .id(photo.id).frame(maxWidth: .infinity, maxHeight: .infinity)
                    if !chrome.visible && store.state.rejected.contains(photo.id) {
                        VStack { HStack { Spacer(); Image(systemName: "trash.fill").foregroundStyle(.white).padding(9).background(.red, in: Circle()) }; Spacer() }.padding(16).allowsHitTesting(false)
                    }
                } else { ContentUnavailableView("当前列表已浏览完", systemImage: "checkmark.circle") }
                VStack {
                    FloatingTools {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing:5){Text(store.focused?.name ?? "没有照片").font(.system(size: 13, weight: .semibold)).lineLimit(1);if let photo=store.focused,!store.labels(for:photo).isEmpty{PhotoLabelDots(labels:store.labels(for:photo))}}
                            Text(store.albums.first { $0.id == store.focused?.albumID }?.title ?? "").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }.frame(maxWidth: 160, alignment: .leading)
                        if let photo = store.focused, store.state.rejected.contains(photo.id) { Image(systemName: "trash.fill").foregroundStyle(.red).help("待删除") }
                        Divider().frame(height: 22)
                        if let photo = store.focused {
                            if let score = store.assessments[photo.id]?.aesthetics { ScoreBadge(score: score) }
                            Button { editingPhoto = photo } label: { Label("编辑", systemImage: "slider.horizontal.3") }.disabled(photo.files.allSatisfy(\.isRAW) || photo.ambiguous || store.busy).help("编辑 JPG，覆盖保存并保留最初备份")
                            Button { evaluate(photo) } label: { Label("评测", systemImage: "sparkles") }.disabled(store.assessing.contains(photo.id)).help("在本机评测当前照片")
                        }
                        Divider().frame(height: 22)
                        Button { info.togglePin() } label: { Label(info.pinned ? "取消固定评测" : "固定评测信息", systemImage: "sidebar.right") }.labelStyle(.iconOnly).help(info.pinned ? "取消固定，靠近右侧自动显示" : "固定评测信息，避免遮挡图片")
                        NavigatorToggle(visible: $store.navigatorVisible)
                        Button { chrome.togglePin() } label: { Label(chrome.pinned ? "自动隐藏工具" : "固定工具", systemImage: chrome.pinned ? "pin.fill" : "pin") }.labelStyle(.iconOnly).help(chrome.pinned ? "工具栏已固定，点击恢复自动隐藏（H）" : "工具栏自动隐藏，点击固定（H）")
                        Button { store.viewerController?.window?.toggleFullScreen(nil) } label: { Label(store.viewerFullScreen ? "退出全屏" : "全屏", systemImage: store.viewerFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") }.labelStyle(.iconOnly).help(store.viewerFullScreen ? "退出全屏" : "全屏")
                    }.fixedSize(horizontal: true, vertical: false)
                    Spacer()
                    FloatingTools {
                        Button { store.navigate(-1) } label: { Label("上一张", systemImage: "chevron.left") }.labelStyle(.iconOnly).help("上一张，←")
                        Button { fitToken += 1 } label: { Label("适应窗口", systemImage: "arrow.down.right.and.arrow.up.left") }.help("适应窗口，F；也可右键当前照片")
                        Divider().frame(height: 16)
                        if let photo = store.focused {
                            Button { store.toggleReject(photo) } label: { Label(store.state.rejected.contains(photo.id) ? "取消待删除" : "标记待删除", systemImage: "trash") }.foregroundStyle(store.state.rejected.contains(photo.id) ? .red : .primary).disabled(store.busy)
                        }
                        Divider().frame(height: 16)
                        Button { store.navigate(1) } label: { Label("下一张", systemImage: "chevron.right") }.labelStyle(.iconOnly).help("下一张，→")
                    }.fixedSize()
                }.padding(12).padding(.top, store.viewerFullScreen ? 0 : 28).opacity(chrome.visible ? 1 : 0).allowsHitTesting(chrome.visible).accessibilityHidden(!chrome.visible)
            }
            if info.pinned, let photo = store.focused {
                AssessmentSidebar(photo: photo, pinned: true, dismiss: { info.togglePin() }).environmentObject(store).frame(width: 280)
            }
        }.overlay(alignment: .trailing) {
            if info.visible && !info.pinned, let photo = store.focused {
                AssessmentSidebar(photo: photo, pinned: false, dismiss: { info.togglePin() })
                    .environmentObject(store).frame(width: 280).modifier(PhotoGlass()).padding(12).padding(.top, store.viewerFullScreen ? 0 : 28)
            }
        }.overlay(alignment: .top) { WindowHeaderMaterial().frame(height: store.viewerFullScreen ? 0 : 28).allowsHitTesting(false) }.ignoresSafeArea(.container, edges: .top).frame(minWidth: 700, minHeight: 480).background(.black).preferredColorScheme(.dark)
            .accessibilityHidden(editingPhoto != nil).allowsHitTesting(editingPhoto == nil)
            .background { if editingPhoto == nil { ChromeTracking(state: chrome, inspector: info, inspectorEnabled: store.focused.map { store.assessments[$0.id] != nil || store.assessing.contains($0.id) } ?? false).frame(width: 0, height: 0) } }
        .task(id: preloadWindow) {
            let urls = preloadWindow
            await ViewerImageCache.shared.setWindow(urls)
            for url in urls {
                guard !Task.isCancelled else { return }
                guard await ViewerImageCache.shared.decode(url, prefetch: true) != nil else { return }
                await Task.yield()
            }
        }
        .onDisappear { Task { await ViewerImageCache.shared.clear() } }
        .overlay {
            if let photo = editingPhoto {
                PhotoEditorView(photo: photo, directory: store.stateURL.deletingLastPathComponent()) { closeWindow in
                    store.editorActive = false; store.editorCloseRequest = nil; editingPhoto = nil
                    if closeWindow { store.viewerController?.close() }
                }.environmentObject(store)
            }
        }

    }
    private func evaluate(_ photo: Photo) { store.assessPhoto(photo); info.reveal(); chrome.reveal(); chrome.scheduleHide() }
}

struct DeletionHistoryView: View {
    @EnvironmentObject var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("删除记录").font(.title2.weight(.semibold)); Spacer(); Button("完成") { dismiss() }.keyboardShortcut(.cancelAction) }
            Text("每次删除单独记录。关闭相册、目录不可访问或废纸篓文件已清除时，相应记录失效。恢复失败不会阻塞其他文件。").font(.caption).foregroundStyle(.secondary)
            List {
                ForEach(store.undoBatches) { batch in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(store.albums.first { $0.id == batch.albumID }?.title ?? "已关闭相册").font(.headline)
                        Text("\(batch.date.formatted(date: .abbreviated, time: .standard)) · \(batch.records.count) 个文件").font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button("撤销这一批") { store.undoTrash(batch.id) }
                            Spacer()
                            Button("移除记录") { store.dismissBatch(batch.id) }
                        }.disabled(store.busy)
                    }.padding(.vertical, 8)
                }
            }.overlay { if store.undoBatches.isEmpty { Text("暂无可撤销记录").foregroundStyle(.secondary) } }
        }.padding(24).frame(width: 600, height: 440).onAppear { store.refreshHistory() }
    }
}
