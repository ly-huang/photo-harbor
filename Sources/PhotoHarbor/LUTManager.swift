import SwiftUI
import AppKit
import UniformTypeIdentifiers

@MainActor final class LUTManagerController: NSWindowController, NSWindowDelegate {
    private static var shared: LUTManagerController?
    static func show(directory: URL, kind: FilterLibraryKind? = nil) {
        let library=LUTLibrary.shared(directory:directory.appendingPathComponent("LUTs"))
        if let kind { library.selectedKind=kind }
        if let existing = shared, existing.window != nil { existing.showWindow(nil); existing.window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 500), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "滤镜 / LUT 管理"; window.minSize = NSSize(width: 420, height: 360); window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua); window.titlebarAppearsTransparent = true
        let controller = LUTManagerController(window: window); window.delegate = controller
        window.contentView = NSHostingView(rootView: LUTManagerView(library: LUTLibrary.shared(directory: directory.appendingPathComponent("LUTs"))))
        shared = controller; window.center(); controller.showWindow(nil); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func windowWillClose(_ notification: Notification) { Self.shared = nil }
}

private struct ManagedFilter: Identifiable {
    let lut: LUTEntry?
    let preset: ImportedPhotoFilter?
    var id: String { (lut == nil ? "xmp:" : "cube:") + (lut?.id ?? preset!.id) }
    var name: String { lut?.name ?? preset!.name }
    var kind: String { lut == nil ? "XMP" : "CUBE" }
    var warnings: [String] { preset?.warnings ?? [] }
    @MainActor func rename(in library: LUTLibrary, to name: String) throws {
        if let lut { try library.rename(lut, to: name) }; if let preset { try library.rename(preset, to: name) }
    }
    @MainActor func remove(from library: LUTLibrary) throws {
        if let lut { try library.remove(lut) }; if let preset { try library.remove(preset) }
    }
}

private struct LUTManagerView: View {
    @ObservedObject var library: LUTLibrary
    @ViewState private var search = ""
    @ViewState private var drafts: [LUTImportItem] = []
    @ViewState private var showingImport = false
    @ViewState private var error: String?
    @ViewState private var removing: ManagedFilter?
    @ViewState private var renaming: ManagedFilter?
    var allEntries: [ManagedFilter] { (library.entries.map { ManagedFilter(lut: $0, preset: nil) } + library.photoFilters.map { ManagedFilter(lut: nil, preset: $0) }).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }
    var categoryEntries: [ManagedFilter] { allEntries.filter { library.selectedKind == .filter ? $0.preset != nil : $0.lut != nil } }
    var visible: [ManagedFilter] { categoryEntries.filter { search.isEmpty || $0.name.localizedStandardContains(search) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) { Text("滤镜 / LUT 库").font(.title2.weight(.semibold)); Text("\(library.entries.count) 个 LUT，\(library.photoFilters.count) 个 XMP 滤镜").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button(action: chooseFiles) { Label(library.selectedKind == .filter ? "导入滤镜…":"导入 LUT…", systemImage: "square.and.arrow.down") }
            }
            Picker("库类型",selection:$library.selectedKind) {
                Text("滤镜（\(library.photoFilters.count)）").tag(FilterLibraryKind.filter)
                Text("LUT（\(library.entries.count)）").tag(FilterLibraryKind.lut)
            }.pickerStyle(.segmented)
            Text(library.selectedKind == .filter ? "XMP：曝光、色彩、曲线等参数预设。" : "CUBE：颜色映射表，用于统一调色风格。").font(.caption).foregroundStyle(.secondary)
            HStack { Image(systemName: "magnifyingglass").foregroundStyle(.secondary); TextField("搜索滤镜或 LUT", text: $search).textFieldStyle(.plain); if !search.isEmpty { Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless).help("清空搜索") } }.padding(10).modifier(PhotoGlass(radius: 10))
            if categoryEntries.isEmpty {
                ContentUnavailableView(library.selectedKind == .filter ? "导入你的第一个滤镜":"导入你的第一个 LUT", systemImage: "cube.transparent", description: Text("支持 \(library.selectedKind.formatDescription)，导入时可命名，原文件保留。"))
            } else if visible.isEmpty {
                ContentUnavailableView.search(text: search)
            } else {
                List(visible) { entry in
                    HStack(spacing: 12) {
                        Image(systemName: "cube.transparent").font(.title3).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.name).lineLimit(1).truncationMode(.middle).help(entry.name)
                            Text(entry.kind).font(.caption2).foregroundStyle(.secondary)
                            if !entry.warnings.isEmpty { DisclosureGroup("兼容性说明") { ForEach(entry.warnings, id: \.self) { Text($0).font(.caption2).foregroundStyle(.secondary) } }.font(.caption) }
                        }
                        Spacer(minLength: 8)
                        Button { renaming = entry } label: { Image(systemName: "pencil") }.buttonStyle(.borderless).help("重命名 \(entry.name)").accessibilityLabel("重命名 \(entry.name)")
                        Button { removing = entry } label: { Image(systemName: "trash") }.buttonStyle(.borderless).help("移除 \(entry.name)").accessibilityLabel("移除 \(entry.name)")
                    }.padding(.vertical, 8).listRowBackground(Color.white.opacity(0.025))
                    .contextMenu { Button("重命名…") { renaming = entry }; Button("从库中移除…", role: .destructive) { removing = entry } }
                }.listStyle(.inset).scrollContentBackground(.hidden).background(.black.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            }
            Text(search.isEmpty ? "从库中移除只影响库内副本，已保存照片不变。" : "找到 \(visible.count) / \(categoryEntries.count) 项").font(.caption).foregroundStyle(.secondary)
        }.padding(22).frame(minWidth: 400, minHeight: 300)
        .background(Color(red: 0.09, green: 0.10, blue: 0.115)).background(.ultraThinMaterial)
        .preferredColorScheme(.dark).tint(Color(red: 0.51, green: 0.72, blue: 0.96))
        .sheet(isPresented: $showingImport) { LUTImportView(library: library, initial: drafts) }
        .sheet(item: $renaming) { entry in LUTRenameView(entry: entry, library: library) }
        .alert("操作未完成", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("知道了") { error = nil } } message: { Text(error ?? "") }
        .confirmationDialog("从库中移除这一项？", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
            Button("移到废纸篓", role: .destructive) { if let entry = removing { do { try entry.remove(from: library) } catch { self.error = error.localizedDescription } }; removing = nil }
            Button("取消", role: .cancel) { removing = nil }
        } message: { Text(removing?.name ?? "") }
    }
    private func chooseFiles() {
        let panel = NSOpenPanel(); panel.title = library.selectedKind == .filter ? "选择 XMP 滤镜预设":"选择 CUBE LUT"; panel.canChooseDirectories = false; panel.allowsMultipleSelection = true; panel.appearance = NSAppearance(named: .darkAqua)
        panel.allowedContentTypes = [UTType(filenameExtension: library.selectedKind.fileExtension) ?? .data]
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            if response == .OK { drafts = panel.urls.map { url in
                let clean=url.deletingPathExtension().lastPathComponent.components(separatedBy:CharacterSet.controlCharacters.union(CharacterSet(charactersIn:"/:"))).joined(separator:" ").trimmingCharacters(in:.whitespacesAndNewlines)
                return LUTImportItem(url:url,name:String((clean.isEmpty ? "未命名":clean).prefix(80)))
            }; showingImport = true }
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: completion) }
        else { panel.begin(completionHandler: completion) }
    }
}

private struct LUTImportView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var library: LUTLibrary
    @ViewState private var items: [LUTImportItem]
    @ViewState private var importing = false
    @ViewState private var error: String?
    init(library: LUTLibrary, initial: [LUTImportItem]) { self.library = library; _items = ViewState(initialValue: initial) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(items.first?.url.pathExtension.lowercased() == "xmp" ? "导入滤镜":"导入 LUT").font(.title2.weight(.semibold))
            Text("为 \(items.count) 个文件设置名称；相同内容复用已有条目和名称。").font(.caption).foregroundStyle(.secondary)
            Text("无固定数量上限；XMP 单文件最多 2 MB，CUBE 最多 32 MB、三维网格 2–64。失败项会单独保留，成功项正常入库。").font(.caption2).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach($items) { $item in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(item.url.lastPathComponent).font(.caption).foregroundStyle(.secondary).lineLimit(1).help(item.url.lastPathComponent)
                            TextField("名称", text: $item.name).textFieldStyle(.roundedBorder).accessibilityLabel("\(item.url.lastPathComponent) 的名称")
                        }
                    }
                }.padding(2)
            }.frame(maxHeight: 280).disabled(importing)
            if importing{ProgressView(value:Double(library.importCompleted),total:Double(max(1,library.importTotal)));Text("已处理 \(library.importCompleted) / \(library.importTotal)").font(.caption)}
            if let error { Text(error).font(.caption).foregroundStyle(.orange).lineLimit(5).textSelection(.enabled) }
            HStack { Button("取消") { dismiss() }.disabled(importing); Spacer(); if importing { ProgressView().controlSize(.small) }; Button("导入到库") { importItems() }.keyboardShortcut(.defaultAction).disabled(importing || items.isEmpty) }
        }.padding(24).frame(width: 460).background(.ultraThinMaterial).preferredColorScheme(.dark)
    }
    private func importItems() {
        importing = true
        Task {
            let result=await library.importNamed(items)
            if result.failures.isEmpty{dismiss()}else{
                items=result.failures.map(\.item)
                error="成功处理 \(result.succeeded) 个，失败 \(result.failures.count) 个。下方保留失败项，可修改名称后重试。\n"+result.failures.prefix(5).map(\.message).joined(separator:"\n")
            };importing=false
        }
    }
}

private struct LUTRenameView: View {
    @Environment(\.dismiss) private var dismiss
    let entry: ManagedFilter
    @ObservedObject var library: LUTLibrary
    @ViewState private var name: String
    @ViewState private var error: String?
    init(entry: ManagedFilter, library: LUTLibrary) { self.entry = entry; self.library = library; _name = ViewState(initialValue: entry.name) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("重命名").font(.title2.weight(.semibold))
            TextField("名称", text: $name).textFieldStyle(.roundedBorder)
            Text("仅更新库内名称，文件内容与已编辑照片不变。").font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).font(.caption).foregroundStyle(.orange) }
            HStack { Button("取消") { dismiss() }; Spacer(); Button("保存名称") { do { try entry.rename(in: library, to: name); dismiss() } catch { self.error = error.localizedDescription } }.keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 380).background(.ultraThinMaterial).preferredColorScheme(.dark)
    }
}
