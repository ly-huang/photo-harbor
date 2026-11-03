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
    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 208)
            Divider()
            VStack(spacing: 0) {
                header
                Divider()
                if store.photos.isEmpty { emptyState }
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
                    Text(store.status).lineLimit(1)
                    Spacer()
                    if store.busy && store.progress > 0 {
                        ProgressView(value: store.progress).frame(width: 80)
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
        .task { if !store.albums.isEmpty { store.scan() } }
        .task(id: store.selected) { await store.loadMetadata() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in if !store.busy { store.refreshHistory() } }
        .onChange(of: store.visible.map(\.id)) { _, _ in store.reconcileSelection() }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "square.stack.3d.up.fill").font(.title2).foregroundStyle(accent)
                VStack(alignment: .leading, spacing: 3) { Text("拾影").font(.title2.weight(.semibold)); Text("Photo Harbor").font(.caption).foregroundStyle(.secondary) }
            }.padding(24)
            Text("照片库").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 24).padding(.bottom, 9)
            nav("全部照片", icon: "square.grid.2x2", count: store.photos.count)
            nav("未配对", icon: "link", count: store.photos.filter { !$0.paired }.count)
            nav("待检查", icon: "exclamationmark.triangle", count: store.photos.filter(\.ambiguous).count)
            nav("待删除", icon: "trash", count: store.rejected.count)
            HStack { Text("拍摄相册"); Spacer(); Text("\(store.albums.count)") }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 24).padding(.top, 30).padding(.bottom, 10)
            ScrollView {
                VStack(spacing: 3) {
                    ForEach(store.albums) { album in
                        Button {
                            store.album = album.id; store.filter = "全部照片"
                        } label: {
                            HStack(alignment: .top, spacing: 9) { Image(systemName: store.unavailable.contains(album.id) ? "externaldrive.badge.exclamationmark" : "folder").foregroundStyle(accent); Text(album.title).lineLimit(2); Spacer(minLength: 0); Text("\(store.photos.filter { $0.albumID == album.id }.count)").font(.caption2).foregroundStyle(.secondary) }
                                .font(.system(size: 12)).padding(.horizontal, 12).padding(.vertical, 9)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(store.album == album.id ? accent.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 6))
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(store.busy)
                            .help(album.roots.urls.map(\.path).joined(separator: "\n"))
                            .contextMenu {
                                Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting(album.roots.urls) }
                                Button("关闭并移除相册") { store.closeAlbum(album.id) }.disabled(store.busy)
                                Text("只从列表移除，磁盘照片保留")
                            }
                    }
                }.padding(.horizontal, 12)
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
                    Button("移入废纸篓", role: .destructive) { store.confirmTrash = true }
                        .disabled(store.busy || !store.trusted || store.rejected.isEmpty)
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
                Button("打开相册") { store.settings = true }.buttonStyle(.borderedProminent)
                Button("导入新照片") { store.importing = true }
            }.disabled(store.busy)
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
                PhotoImage(url: photo.preview).frame(height: 144).clipShape(RoundedRectangle(cornerRadius: 5))
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
                PhotoImage(url: photo.preview).aspectRatio(1.4, contentMode: .fit)
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
    @ViewState private var problem: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("打开相册").font(.title2.weight(.semibold))
            Text("在原目录配对和浏览，不移动、不复制、不重新分类。新相册会追加到左侧列表。").foregroundStyle(.secondary)
            TextField("相册名称（可选）", text: $title).textFieldStyle(.roundedBorder)
            folderRow("JPG 目录（可选）", path: $roots.jpg)
            folderRow("RAW 目录（可选）", path: $roots.raw)
            Text("至少填写一个目录。相同的相对路径和文件名优先配对；其余仅在文件名唯一时配对。").font(.caption).foregroundStyle(.secondary)
            if let problem { Text(problem).foregroundStyle(.orange).font(.caption) }
            HStack { Spacer(); Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("打开并扫描") { do { try store.applyRoots(roots, title: title) } catch { problem = error.localizedDescription } }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(roots.urls.isEmpty)
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
    @ViewState private var location = ""
    @ViewState private var jpgDestination = ""
    @ViewState private var rawDestination = ""
    @ViewState private var plan: [ImportItem] = []
    @ViewState private var planning = false
    @ViewState private var problem: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("导入一次拍摄").font(.title2.weight(.semibold))
            Text("按 YYYYMMDD_地点 分类，分别复制到 JPG 和 RAW 文件夹。").foregroundStyle(.secondary)
            HStack { TextField("来源文件夹或相机存储卡", text: $source); Button("选择…") { if let path = store.chooseDirectory() { source = path } } }.disabled(planning)
            TextField("地点（可选）：留空读取照片信息，无法获取时使用“未知”", text: $location).disabled(planning)
            destinationRow("JPG 存放位置", path: $jpgDestination, fallback: destinationRoots.jpg)
            destinationRow("RAW 存放位置", path: $rawDestination, fallback: destinationRoots.raw)
            Text("存放位置留空时，在来源文件夹同级创建 JPG、RAW；两边使用相同分类文件夹名称。").font(.caption).foregroundStyle(.secondary)
            if planning { ProgressView("正在读取拍摄信息…") }
            if let problem { Text(problem).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            if !plan.isEmpty {
                Divider()
                HStack { Text("导入计划").font(.headline); Spacer(); Text("\(plan.count) 个文件 · \(readableBytes(plan.reduce(0) { $0 + $1.bytes }))").foregroundStyle(.secondary) }
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(plan) { item in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.source.lastPathComponent).font(.system(size: 12, weight: .medium))
                                Text(item.destination.path).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }.frame(height: 190)
                if plan.contains(where: \.fallbackDate) { Label("部分文件没有拍摄时间，将使用文件修改日期。请核对目标日期。", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
            }
            Text("复制后逐文件校验，不覆盖重名文件，来源照片保留。地点优先使用填写内容，其次读取照片地点或在线反查 GPS，失败时归为“未知”。").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction).disabled(planning)
                Spacer()
                if plan.isEmpty {
                    Button("预览导入计划") { makePlan() }.buttonStyle(.borderedProminent).disabled(planning || source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } else {
                    Button("重新规划") { plan = [] }
                    Button("复制并校验") { store.executeImport(plan, roots: destinationRoots); dismiss() }.buttonStyle(.borderedProminent)
                }
            }
        }.textFieldStyle(.roundedBorder).padding(28).frame(width: 680)
        .onChange(of: source) { _, _ in plan = []; problem = nil }
        .onChange(of: location) { _, _ in plan = []; problem = nil }
        .onChange(of: jpgDestination) { _, _ in plan = []; problem = nil }
        .onChange(of: rawDestination) { _, _ in plan = []; problem = nil }
    }
    private var destinationRoots: Roots {
        let parent = URL(fileURLWithPath: source).deletingLastPathComponent()
        return Roots.importDestinations(jpg: jpgDestination.isEmpty ? parent.appendingPathComponent("JPG").path : jpgDestination,
                     raw: rawDestination.isEmpty ? parent.appendingPathComponent("RAW").path : rawDestination)
    }
    private func destinationRow(_ title: String, path: Binding<String>, fallback: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.medium))
            HStack {
                TextField(source.isEmpty ? "可选，默认放在来源文件夹同级" : fallback, text: path)
                Button("选择…") { if let selected = store.chooseDirectory() { path.wrappedValue = selected } }
                if !path.wrappedValue.isEmpty { Button("默认") { path.wrappedValue = "" } }
            }
        }.disabled(planning)
    }
    private func makePlan() {
        planning = true; problem = nil
        let root = destinationRoots; let url = URL(fileURLWithPath: source); let place = location
        Task {
            do { plan = try await Task.detached { try await LibraryService.importPlanResolvingPlaces(source: url, roots: root, location: place) }.value; if plan.isEmpty { problem = "来源目录中没有找到 JPG 或 ARW 文件。" } }
            catch { problem = error.localizedDescription }
            planning = false
        }
    }
}

struct ViewerView: View {
    @EnvironmentObject var store: LibraryStore
    @StateObject private var chrome = ChromeState()
    @ViewState private var fitToken = 0
    @StateObject private var info = InspectorState()
    @ViewState private var editingPhoto: Photo?
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
