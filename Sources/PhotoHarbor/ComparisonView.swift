import SwiftUI
import AppKit

@MainActor final class ComparisonController: NSWindowController, NSWindowDelegate {
    private weak var store: LibraryStore?
    init(store: LibraryStore) {
        self.store = store
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 980), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true; window.backgroundColor = .black
        window.title = "拾影 · 图片对比"; window.minSize = NSSize(width: 1000, height: 700)
        window.collectionBehavior = [.fullScreenPrimary]; window.isReleasedWhenClosed = false
        super.init(window: window); window.delegate = self
        window.contentView = NSHostingView(rootView: ComparisonView().environmentObject(store)); window.center()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func windowDidEnterFullScreen(_ notification: Notification) { store?.comparisonFullScreen = true }
    func windowDidExitFullScreen(_ notification: Notification) { store?.comparisonFullScreen = false }
    func windowWillClose(_ notification: Notification) { store?.comparisonFullScreen = false; store?.comparisonController = nil; window?.contentView = nil }
}

struct ComparisonView: View {
    @ViewState private var photoAction: PhotoContextRequest?
    @EnvironmentObject var store: LibraryStore
    @StateObject private var chrome = ChromeState()
    @ViewState private var fitToken = 0
    @ViewState private var assessment: GroupAssessment?
    @ViewState private var analyzing = false
    @ViewState private var activeIndex = 0
    @StateObject private var info = InspectorState()
    private var selected: [Photo] { store.comparisonPhotos }
    private var comparisonInfoWidth: CGFloat { max(320, 100 + CGFloat(selected.count) * 68) }
    var body: some View {
        HStack(spacing: 0) {
            ZStack(alignment: .top) {
                Color(white: 0.035)
                if (2...4).contains(selected.count) {
                    GeometryReader { geometry in
                        let rows = selected.count > 2 ? 2 : 1
                        let height = max(1, (geometry.size.height - CGFloat(rows - 1) * 8) / CGFloat(rows))
                        VStack(spacing: 8) {
                            ForEach(0..<rows, id: \.self) { row in
                                HStack(spacing: 8) {
                                    ForEach(0..<2, id: \.self) { column in
                                        let index = row * 2 + column
                                        if index < selected.count { pane(selected[index], index: index).frame(maxWidth: .infinity) }
                                        else { Color.clear.frame(maxWidth: .infinity) }
                                    }
                                }.frame(height: height)
                            }
                        }
                    }.padding(8)
                } else { ContentUnavailableView("请选择二至四张照片", systemImage: "square.grid.2x2") }
                FloatingTools {
                    Text("对比").font(.system(size: 13, weight: .semibold))
                    Text("\(selected.count) 张").foregroundStyle(.secondary)
                    if analyzing { ProgressView().controlSize(.small) }
                    Spacer(minLength: 12)
                    Button { fitToken += 1 } label: { Label("全部适应", systemImage: "arrow.down.right.and.arrow.up.left") }.help("同时适应全部图片；单张请右键操作")
                    Button { info.togglePin() } label: { Label(info.pinned ? "取消固定评测" : "固定评测", systemImage: "sidebar.right") }.help("靠近窗口右侧查看；固定后不遮挡照片")
                    NavigatorToggle(visible: $store.navigatorVisible)
                    Button { chrome.togglePin() } label: { Label(chrome.pinned ? "自动隐藏工具" : "固定工具", systemImage: chrome.pinned ? "pin.fill" : "pin") }.labelStyle(.iconOnly).help(chrome.pinned ? "工具栏已固定，点击恢复自动隐藏（H）" : "工具栏自动隐藏，点击固定（H）")
                    Button { store.comparisonController?.window?.toggleFullScreen(nil) } label: { Label(store.comparisonFullScreen ? "退出全屏" : "全屏", systemImage: store.comparisonFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") }.labelStyle(.iconOnly).help(store.comparisonFullScreen ? "退出全屏" : "全屏")
                }.fixedSize(horizontal: true, vertical: false).padding(12).padding(.top, store.comparisonFullScreen ? 0 : 28).opacity(chrome.visible ? 1 : 0).allowsHitTesting(chrome.visible).accessibilityHidden(!chrome.visible)
            }
            if info.pinned, !selected.isEmpty {
                ComparisonAssessmentSidebar(photos: selected, assessment: assessment, pinned: true, dismiss: { info.togglePin() })
                    .environmentObject(store).frame(width: comparisonInfoWidth).padding(.top, store.comparisonFullScreen ? 0 : 28)
            }
        }.overlay(alignment: .trailing) {
            if info.visible && !info.pinned, !selected.isEmpty {
                ComparisonAssessmentSidebar(photos: selected, assessment: assessment, pinned: false, dismiss: { info.togglePin() })
                    .environmentObject(store).frame(width: comparisonInfoWidth).modifier(PhotoGlass()).padding(12).padding(.top, store.comparisonFullScreen ? 0 : 28)
            }
        }.overlay(alignment: .top) { WindowHeaderMaterial().frame(height: store.comparisonFullScreen ? 0 : 28).allowsHitTesting(false) }.ignoresSafeArea(.container, edges: .top).frame(minWidth: 1000, minHeight: 700).background(.black).preferredColorScheme(.dark)
            .background(ChromeTracking(state: chrome, inspector: info, inspectorWidth: comparisonInfoWidth).frame(width: 0, height: 0))
        .sheet(item: $photoAction) { PhotoContextSheet(request: $0).environmentObject(store) }
        .task(id: selected.map(\.id)) {
            assessment = nil; analyzing = false; activeIndex = 0
            let captured = selected
            guard (2...4).contains(captured.count) else { return }
            analyzing = true
            let result = await AssessmentService.shared.compareMany(captured.map(\.preview))
            guard !Task.isCancelled else { return }
            assessment = result
            for i in captured.indices { if let stats = result.stats[i] { store.recordAssessment(stats, for: captured[i]) } }
            analyzing = false
        }
    }
    private func pane(_ photo: Photo, index: Int) -> some View {
        InteractivePhoto(url: photo.preview, fitToken: fitToken, fullScreen: store.comparisonFullScreen, navigatorVisible: store.navigatorVisible,
            evaluate: { activeIndex = index; store.assessPhoto(photo); info.reveal() },
            activated: { if activeIndex != index { activeIndex = index } },
            toggleNavigator: { store.navigatorVisible.toggle() }, labels:store.labels(for:photo),labelChanged:{if let label=$0{store.toggleLabel(label,photo:photo)}else{store.clearLabels(photo)}}, rejected: store.state.rejected.contains(photo.id), navigatorTopInset: 44,
            fileAction: store.editorActive || store.busy ? nil : {
                photoAction = PhotoContextRequest(action: $0, photos: [photo])
            }, canDelete: store.trusted && !photo.ambiguous,
            previous: {}, next: {}, mark: { store.toggleReject(photo) })
            .id(photo.id).frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .bottomLeading) {
                HStack(spacing: 7) {
                    Image(systemName: activeIndex == index ? "circle.inset.filled" : "circle").font(.system(size: 8)).foregroundStyle(.secondary)
                    Text("\(index + 1)").font(.caption.bold())
                    Text(photo.name).font(.caption).lineLimit(1)
                    if !store.labels(for:photo).isEmpty{PhotoLabelDots(labels:store.labels(for:photo))}
                    if store.state.rejected.contains(photo.id) { Image(systemName: "trash.fill").foregroundStyle(.red) }
                }.padding(.horizontal, 9).padding(.vertical, 6).modifier(PhotoGlass(radius: 20)).padding(10).allowsHitTesting(false)
            }
            .overlay(alignment: .bottomTrailing) {
                if let score = store.assessments[photo.id]?.aesthetics { ScoreBadge(score: score).padding(10).allowsHitTesting(false) }
            }
            .background(.black).clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.white.opacity(0.10), lineWidth: 1).allowsHitTesting(false))
    }
}

struct AssessmentSidebar: View {
    @EnvironmentObject var store: LibraryStore
    let photo: Photo
    var pinned = false
    let dismiss: () -> Void
    var distances: [AssessmentDistance] = []
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("评测信息").font(.headline); Spacer()
                Button(action: dismiss) { Image(systemName: pinned ? "pin.fill" : "pin") }
                    .buttonStyle(.borderless).help(pinned ? "取消固定，移出后隐藏" : "固定评测信息")
            }
            Text(photo.name).font(.subheadline.weight(.medium)).lineLimit(1)
            Button(store.assessments[photo.id] == nil ? "评测此图片" : "重新评测") { store.assessPhoto(photo) }.disabled(store.assessing.contains(photo.id))
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if store.assessing.contains(photo.id) { ProgressView("正在本机评测…") }
                    if let stats = store.assessments[photo.id] {
                        AssessmentDetails(stats: stats)
                        Divider()
                        Text(stats.metadata.dimensions + " · " + stats.metadata.camera).font(.caption)
                        Text(stats.metadata.exposure + " · " + stats.metadata.shooting).font(.caption).foregroundStyle(.secondary)
                        Text(stats.metadata.date?.formatted(date: .numeric, time: .standard) ?? "无拍摄时间").font(.caption).foregroundStyle(.secondary)
                    } else if let error = store.assessmentErrors[photo.id] { Text(error).font(.caption).foregroundStyle(.orange) }
                    else { Text("评测结果会显示在这里。").font(.caption).foregroundStyle(.secondary) }
                    if !distances.isEmpty {
                        Divider(); Text("与其他图片的相似距离").font(.caption.weight(.semibold))
                        ForEach(distances.indices, id: \.self) { i in let pair = distances[i]; Text(String(format: "%d ↔ %d    %.3f", pair.first + 1, pair.second + 1, pair.value)).font(.caption.monospacedDigit()) }
                        Text("距离越小越相似").font(.caption2).foregroundStyle(.secondary)
                    }
                    Text(readableBytes(photo.bytes)).font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding(18).padding(.top, pinned ? 28 : 0).frame(maxHeight: .infinity).modifier(ArrowPointer()).background { if pinned { Rectangle().fill(.ultraThinMaterial) } }
    }
}

struct AssessmentDetails: View {
    let stats: PhotoAssessment
    var compact = false
    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 5 : 9) {
            HStack {
                Text("审美参考").font(.caption.weight(.semibold))
                Spacer()
                if let score = stats.aesthetics { ScoreBadge(score: score) }
                else { Text("不可用").font(.headline) }
            }
            if !compact { Text(stats.aestheticsNote).font(.caption2).foregroundStyle(.secondary) }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: compact ? 4 : 2), alignment: .leading, spacing: 7) {
                metric("细节强度", String(format: "%.1f", stats.detailEnergy))
                metric("暗部近黑", String(format: "%.1f%%", stats.darkPercent))
                metric("高光近白", String(format: "%.1f%%", stats.brightPercent))
                metric("平均亮度", String(format: "%.0f%%", stats.meanBrightness))
            }
            HistogramView(values: stats.histogram).frame(height: compact ? 22 : 32)
            if !compact { Text("审美分为本机模型参考，细节强度不等于对焦准确率。").font(.caption2).foregroundStyle(.secondary) }
        }
    }
    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) { Text(title).font(.caption2).foregroundStyle(.secondary); Text(value).font(.caption.monospacedDigit()) }
    }
}
struct HistogramView: View {
    let values: [Double]
    var body: some View {
        Canvas { context, size in
            let maxValue = max(values.max() ?? 0, 0.0001)
            for (index, value) in values.enumerated() {
                let width = size.width / CGFloat(max(values.count, 1))
                let height = size.height * value / maxValue
                context.fill(Path(CGRect(x: CGFloat(index) * width, y: size.height - height, width: max(1, width - 1), height: height)), with: .color(.gray))
            }
        }.accessibilityLabel("亮度直方图：左侧暗部，右侧高光")
    }
}

struct ComparisonAssessmentSidebar: View {
    @EnvironmentObject var store: LibraryStore
    let photos: [Photo]
    let assessment: GroupAssessment?
    let pinned: Bool
    let dismiss: () -> Void
    private var columns: [GridItem] {
        [GridItem(.fixed(66), alignment: .leading)] + photos.map { _ in GridItem(.flexible(), alignment: .center) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("评测对比").font(.headline)
                Text("\(photos.count) 张").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(action: dismiss) { Image(systemName: pinned ? "pin.fill" : "pin") }
                    .buttonStyle(.borderless).help(pinned ? "取消固定，移出后隐藏" : "固定评测对比")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                        Text("图片").font(.caption).foregroundStyle(.secondary)
                        ForEach(Array(photos.enumerated()), id: \.element.id) { index, photo in
                            VStack(spacing: 4) {
                                Text("\(index + 1)").font(.caption.bold())
                                Text(photo.name).font(.system(size: 9)).lineLimit(1).minimumScaleFactor(0.7).help(photo.name)
                            }
                        }
                        row("审美参考") { stats in stats.aesthetics.map { String(format: "%.1f", $0) } ?? "不可用" }
                        row("细节强度") { String(format: "%.1f", $0.detailEnergy) }
                        row("暗部近黑") { String(format: "%.1f%%", $0.darkPercent) }
                        row("高光近白") { String(format: "%.1f%%", $0.brightPercent) }
                        row("平均亮度") { String(format: "%.0f%%", $0.meanBrightness) }
                        Text("亮度分布").font(.caption2).foregroundStyle(.secondary)
                        ForEach(photos) { photo in
                            if let stats = store.assessments[photo.id] { HistogramView(values: stats.histogram).frame(height: 28) }
                            else { Text("—").foregroundStyle(.secondary) }
                        }
                    }
                    Text("审美为本机模型参考分，细节强度不代表对焦准确率。").font(.caption2).foregroundStyle(.secondary)
                    Divider()
                    HStack {
                        Text("相似距离").font(.caption.weight(.semibold)); Spacer()
                        Text("越小越相似").font(.caption2).foregroundStyle(.secondary)
                    }
                    if let pairs = assessment?.distances, !pairs.isEmpty {
                        ForEach(pairs.indices, id: \.self) { index in
                            let pair = pairs[index]
                            HStack {
                                Text("\(pair.first + 1) ↔ \(pair.second + 1)")
                                Spacer(); Text(String(format: "%.3f", pair.value)).monospacedDigit()
                            }.font(.caption)
                        }
                    } else { Text("相似信息暂不可用").font(.caption).foregroundStyle(.secondary) }
                    Divider()
                    ForEach(Array(photos.enumerated()), id: \.element.id) { index, photo in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(index + 1)  \(photo.name)").font(.caption.weight(.medium))
                                if let stats = store.assessments[photo.id] {
                                    Text(stats.metadata.exposure + " · " + stats.metadata.shooting).font(.caption2).foregroundStyle(.secondary)
                                } else if let error = store.assessmentErrors[photo.id] { Text(error).font(.caption2).foregroundStyle(.orange) }
                            }
                            Spacer()
                            if store.assessing.contains(photo.id) { ProgressView().controlSize(.small) }
                            else {
                                Button { store.assessPhoto(photo) } label: { Image(systemName: "sparkles") }
                                    .buttonStyle(.borderless).help("评测 \(photo.name)")
                            }
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding(18).frame(maxHeight: .infinity).modifier(ArrowPointer())
            .background { if pinned { Rectangle().fill(.ultraThinMaterial) } }
    }
    @ViewBuilder private func row(_ name: String, value: @escaping (PhotoAssessment) -> String) -> some View {
        Text(name).font(.caption2).foregroundStyle(.secondary)
        ForEach(photos) { photo in
            if let stats = store.assessments[photo.id] {
                Text(value(stats)).font(.system(size: 12, weight: name == "审美参考" ? .semibold : .regular)).monospacedDigit()
            } else { Text(store.assessing.contains(photo.id) ? "评测中" : "—").font(.caption2).foregroundStyle(.secondary) }
        }
    }
}
