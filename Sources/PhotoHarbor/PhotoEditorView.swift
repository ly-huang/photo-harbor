import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct PhotoEditorView: View {
    @EnvironmentObject var store: LibraryStore
    @StateObject private var model: PhotoEditorModel
    let photo: Photo
    let close: (Bool) -> Void
    @ViewState private var fitToken = 0
    @ViewState private var before = false
    @ViewState private var confirmDiscard = false
    @ViewState private var confirmRestore = false
    @ViewState private var closeWindow = false
    @StateObject private var chrome = ChromeState()
    @ViewState private var controlsVisible = true
    @ViewState private var comparisonHelp = false
    @ViewState private var tab = EditorTab.adjust
    init(photo: Photo, directory: URL, close: @escaping (Bool) -> Void) {
        self.photo = photo; self.close = close
        _model = StateObject(wrappedValue: PhotoEditorModel(directory: directory))
    }
    var body: some View {
        HStack(spacing: 0) {
            ZStack {
                Color.black
                if let image = before ? model.reference : model.preview {
                    InteractivePhoto(url: photo.preview, fitToken: fitToken, fullScreen: store.viewerFullScreen,
                        navigatorVisible: store.navigatorVisible, overrideImage: image,
                        comparisonImage: model.reference, comparisonEditedImage: model.preview, comparisonActive: false,
                        rotationActive: model.rotationEditing,
                        brushTool: model.activeBrush, brushDiameter: model.brushSize, paint: { model.brush($0) }, painting: { if $0 { model.beginGesture() } else { model.endGesture() } },
                        cropActive: model.cropEditing, cropAspect: model.cropAspect, cropSelection: model.adjustments.cropRect,
                        cropChanged: { rect in model.change { $0.cropRect = rect } }, exit: { requestClose(false) },
                        toggleNavigator: { store.navigatorVisible.toggle() },labels:store.labels(for:photo),labelChanged:{if let label=$0{store.toggleLabel(label,photo:photo)}else{store.clearLabels(photo)}},contextMarkAction:{store.toggleReject(photo)},rejected:store.state.rejected.contains(photo.id), navigatorTopInset: 60, previous: {}, next: {}, mark: {})
                } else { ProgressView("正在读取 JPG…") }
                VStack {
                    ViewThatFits(in: .horizontal) {
                        editorToolbar(compact: false)
                        editorToolbar(compact: true)
                    }.padding(.horizontal, 12).padding(.top, store.viewerFullScreen ? 12 : 40)

                    Spacer()
                    FloatingTools {
                        Button { fitToken += 1 } label: { Label("适应窗口", systemImage: "arrow.down.right.and.arrow.up.left") }
                        Divider().frame(height: 16)
                        EditorModePicker(selection:$tab)
                        Divider().frame(height:16)
                        Button { before.toggle() } label: { Label(before ? "查看编辑后" : "查看编辑前", systemImage: "rectangle.lefthalf.filled") }.disabled(model.loading || model.cropEditing || model.rotationEditing).help("点击切换编辑前后；按住 ⌥ 并移动鼠标临时分割，松开恢复").onHover { comparisonHelp = $0 }
                    }.fixedSize().overlay(alignment: .top) {
                        if comparisonHelp {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("点击：切换编辑前 / 编辑后")
                                Text("按住 ⌥ 并移动鼠标：临时分割对比")
                                Text("松开 ⌥：恢复原视图").foregroundStyle(.secondary)
                            }.font(.caption).padding(12).modifier(PhotoGlass(radius: 10)).fixedSize().offset(y: -84).allowsHitTesting(false)
                        }
                    }.padding(.bottom, 12)
                }.opacity(chrome.visible ? 1 : 0).allowsHitTesting(chrome.visible).accessibilityHidden(!chrome.visible)
            }
            if controlsVisible { EditorSidebar(model: model, tab: tab, manageLibrary: { LUTManagerController.show(directory: store.stateURL.deletingLastPathComponent()) }, restore: { confirmRestore = true })
                .frame(width: 300).padding(.top, store.viewerFullScreen ? 0 : 28)
                .background(.ultraThinMaterial).disabled(model.loading || model.working) }
        }.background(.black)
        .overlay(alignment: .top) { WindowHeaderMaterial().frame(height: store.viewerFullScreen ? 0 : 28).allowsHitTesting(false) }
        .ignoresSafeArea(.container, edges: .top)
        .background(ChromeTracking(state: chrome).frame(width: 0, height: 0))
        .task { await model.open(photo.preview) }
        .onChange(of: model.adjustments) { _, _ in before = false; model.schedulePreview() }
        .onChange(of:tab) { _, selected in
            controlsVisible=true;model.activeBrush=nil
            if selected == .crop { model.beginCrop() } else { if model.cropEditing { model.finishCrop() };if model.rotationEditing { model.finishRotation() } }
        }
        .onReceive(model.library.$photoFilters) { entries in
            if !model.adjustments.presetID.isEmpty && !entries.contains(where:{$0.id==model.adjustments.presetID}) { model.change{$0.presetID=""} }
        }
        .onReceive(model.library.$entries) { entries in
            if !model.adjustments.lutID.isEmpty && !entries.contains(where: { $0.id == model.adjustments.lutID }) { model.change { $0.lutID = "" } }
        }
        .onChange(of: model.rotationEditing) { _, active in if active { before = false }; fitToken += 1 }
        .onChange(of: model.cropEditing) { _, active in if active { before = false }; fitToken += 1; model.schedulePreview() }
        .onChange(of: model.undo.count) { _, _ in store.editorCanUndo = !model.undo.isEmpty }
        .onChange(of: model.redo.count) { _, _ in store.editorCanRedo = !model.redo.isEmpty }
        .onAppear { store.editorActive = true; store.editorCloseRequest = { requestClose(true) }; store.editorUndo = { model.undoChange() }; store.editorRedo = { model.redoChange() } }
        .onDisappear { model.dispose(); store.editorActive = false; store.editorCloseRequest = nil; store.editorUndo = nil; store.editorRedo = nil; store.editorCanUndo = false; store.editorCanRedo = false }
        .alert("操作未完成", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("知道了") { model.error = nil }
        } message: { Text(model.error ?? "") }
        .confirmationDialog("放弃尚未保存的编辑？", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("放弃修改", role: .destructive) { close(closeWindow) }
            Button("继续编辑", role: .cancel) {}
        } message: { Text("原始 JPG 和 ARW 都不会变化。") }
        .confirmationDialog("用最初备份还原 JPG？", isPresented: $confirmRestore, titleVisibility: .visible) {
            Button("还原最初 JPG", role: .destructive) { Task { if await model.restore() { await saved() } } }
            Button("取消", role: .cancel) {}
        } message: { Text("当前 JPG 会被最初的备份替换，未保存调整会丢弃，ARW 保持原样。") }
    }
    private func editorToolbar(compact: Bool) -> some View {
        FloatingTools {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing:5){Text(photo.name).font(.system(size: 13, weight: .semibold)).lineLimit(1);if !store.labels(for:photo).isEmpty{PhotoLabelDots(labels:store.labels(for:photo))}}
                Text(model.rotationEditing ? "旋转中" : (model.cropEditing ? "裁剪中" : (before ? "编辑前" : (model.dirty ? "编辑中 · 未保存" : "编辑 JPG")))).font(.caption2).lineLimit(1)
            }.frame(maxWidth: compact ? 85 : 160, alignment: .leading)
            Divider().frame(height: 22)
            Button { requestClose(false) } label: { Label("返回看图", systemImage: "chevron.left") }.disabled(model.working).help("返回看图")
            if model.rendering || model.working { ProgressView().controlSize(.small) }
            Button { Task { if await model.save() { await saved() } } } label: { Label("保存", systemImage: "square.and.arrow.down") }
                .disabled(model.loading || model.working || !model.dirty || model.preview == nil ).help("保存并覆盖 JPG，首次保留原始备份")
            Divider().frame(height: 22)
            Button { controlsVisible.toggle() } label: { Label(controlsVisible ? "隐藏编辑面板" : "显示编辑面板", systemImage: controlsVisible ? "sidebar.right" : "sidebar.right") }.labelStyle(.iconOnly).help(controlsVisible ? "隐藏编辑面板" : "显示编辑面板")
            NavigatorToggle(visible: $store.navigatorVisible)
            Button { chrome.togglePin() } label: { Label(chrome.pinned ? "自动隐藏工具" : "固定工具", systemImage: chrome.pinned ? "pin.fill" : "pin") }.labelStyle(.iconOnly).help(chrome.pinned ? "工具栏已固定，点击恢复自动隐藏（H）" : "工具栏自动隐藏，点击固定（H）")
            Button { store.viewerController?.window?.toggleFullScreen(nil) } label: { Label(store.viewerFullScreen ? "退出全屏" : "全屏", systemImage: store.viewerFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") }.labelStyle(.iconOnly).help(store.viewerFullScreen ? "退出全屏" : "全屏")
        }.foregroundStyle(.primary).labelStyle(EditorLabelStyle(compact: compact)).fixedSize()
    }
    private func requestClose(_ entireWindow: Bool) {
        guard !model.working else { return }
        closeWindow = entireWindow
        if model.dirty { confirmDiscard = true } else { close(entireWindow) }
    }
    private func saved() async { await store.reloadAfterEditing(photo.preview); close(false) }

}

private struct EditorLabelStyle: LabelStyle {
    let compact: Bool
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) { configuration.icon; if !compact { configuration.title } }
    }
}


private struct EditorModePicker: View {
    @Binding var selection: EditorTab
    var body: some View {
        HStack(spacing: 1) {
            ForEach(EditorTab.allCases,id:\.self) { mode in
                Button { selection=mode } label: {
                    Text(mode.rawValue).font(.system(size:13,weight:.semibold)).padding(.horizontal,13).padding(.vertical,7)
                        .background(selection==mode ? .white.opacity(0.16):.clear,in:Capsule())
                }.buttonStyle(.plain).accessibilityLabel(mode.rawValue).accessibilityAddTraits(selection==mode ? .isSelected:[])
            }
        }.padding(3).background(.white.opacity(0.035),in:Capsule())
    }
}
