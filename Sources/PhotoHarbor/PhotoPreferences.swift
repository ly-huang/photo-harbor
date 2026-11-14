import AppKit
import SwiftUI

enum PhotoCommand: Int, CaseIterable, Identifiable {
    case view, comparisonAdd, compare, assess, reject, finder, export, trash, delete
    case fit, navigator, clearLabels, orange, yellow, green, blue, purple, gray
    case albumFinder, albumClose
    var id: Self { self }

    private static let titles = [
        "查看大图", "加入／移出对比", "对比所选图片", "评测此图片", "标记／取消待删除",
        "在 Finder 中显示照片", "导出照片", "移入废纸篓", "直接删除", "适应窗口",
        "显示／隐藏导航预览", "移除所有颜色标记", "橙色", "黄色", "绿色", "蓝色", "紫色", "灰色",
        "在 Finder 中显示当前相册", "关闭当前相册"
    ]
    var title: String { Self.titles[rawValue] }
    func menuTitle(_ title: String) -> String {
        let binding = shortcut
        return binding.key.isEmpty ? title : "\(title)    \(binding.display)"
    }
    var defaultShortcut: PhotoShortcut {
        switch self {
        case .view: return .init("\r")
        case .reject: return .init("\u{7f}")
        case .fit: return .init("f")
        case .trash: return .init("\u{7f}", .command)
        case .delete: return .init("\u{7f}", [.command, .option])
        case .albumFinder: return .init("f", [.control, .shift])
        case .albumClose: return .init("w", [.control, .shift])
        default:
            // Color commands share the palette's order.
            if let label = label { return .init(String(PhotoLabel.allCases.firstIndex(of: label)! + 1), .control) }
            let key: String
            switch self {
            case .comparisonAdd: key = "b"
            case .compare: key = "c"
            case .assess: key = "a"
            case .finder: key = "f"
            case .export: key = "e"
            case .navigator: key = "n"
            case .clearLabels: key = "0"
            default: return .init("")
            }
            return .init(key, .control)
        }
    }
    private var preferenceKey: String { "photo.shortcut.\(rawValue)" }
    var shortcut: PhotoShortcut {
        guard let data = UserDefaults.standard.data(forKey: preferenceKey),
              let value = try? JSONDecoder().decode(PhotoShortcut.self, from: data) else { return defaultShortcut }
        return value
    }
    func set(_ shortcut: PhotoShortcut) {
        UserDefaults.standard.set(try? JSONEncoder().encode(shortcut), forKey: preferenceKey)
    }
    static func color(_ label: PhotoLabel) -> Self {
        [.orange, .yellow, .green, .blue, .purple, .gray][PhotoLabel.allCases.firstIndex(of: label)!]
    }
    var label: PhotoLabel? { PhotoLabel.allCases.first { Self.color($0) == self } }
    init(fileAction: PhotoContextAction) {
        switch fileAction {
        case .export: self = .export
        case .trash: self = .trash
        case .delete: self = .delete
        }
    }
    var fileAction: PhotoContextAction? { PhotoContextAction.allCases.first { Self(fileAction: $0) == self } }
}

struct PhotoShortcut: Codable, Equatable {
    let key: String
    let modifiers: UInt
    var flags: NSEvent.ModifierFlags { .init(rawValue: modifiers) }
    var display: String {
        if key.isEmpty { return "未设置" }
        let symbols: [(NSEvent.ModifierFlags, String)] = [(.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
        let name = ["\r": "↩", "\u{7f}": "⌫"][key] ?? key.uppercased()
        return symbols.filter { flags.contains($0.0) }.map(\.1).joined() + name
    }
    init(_ key: String, _ flags: NSEvent.ModifierFlags = []) {
        self.key = key
        self.modifiers = flags.rawValue
    }
    init?(event: NSEvent) {
        guard let key = event.charactersIgnoringModifiers?.lowercased(), key.count == 1 else { return nil }
        self.init(key, event.modifierFlags.intersection([.control, .option, .command, .shift]))
    }
    var canRecord: Bool {
        if flags.contains(.command), flags.subtracting([.command, .shift]).isEmpty,
           ["q", "w", "z", "a", "x", "c", "v", "i", "o", "r", ",", "0", "s", "m", "h"].contains(key) { return false }
        return !flags.intersection([.command, .option, .control]).isEmpty
            || ["\r", "\u{7f}", "f"].contains(key) && flags.isEmpty
    }
    func apply(to item: NSMenuItem) {
        item.keyEquivalent = key
        item.keyEquivalentModifierMask = flags
    }
}

struct PhotoShortcutMonitor: NSViewRepresentable {
    let handle: (NSEvent) -> Bool
    func makeNSView(context: Context) -> Monitor { Monitor() }
    func updateNSView(_ view: Monitor, context: Context) { view.handle = handle }
    static func dismantleNSView(_ view: Monitor, coordinator: ()) { view.stop() }

    final class Monitor: NSView {
        var handle: ((NSEvent) -> Bool)?
        var token: Any?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard let window else { return }
            token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak window] event in
                guard let window, event.window === window, window.attachedSheet == nil else { return event }
                return self?.handle?(event) == true ? nil : event
            }
        }
        func stop() {
            if let token { NSEvent.removeMonitor(token); self.token = nil }
        }
    }
}

extension NSEvent {
    var photoCommand: PhotoCommand? {
        guard let shortcut = PhotoShortcut(event: self) else { return nil }
        return PhotoCommand.allCases.first { $0.shortcut == shortcut }
    }
}

extension View {
    func photoHint(_ command: PhotoCommand) -> some View {
        help("\(command.title)  \(command.shortcut.display)")
    }
}

struct PhotoPreferences: View {
    @AppStorage("photo.thumbnailMiB") private var thumbnails = 512
    @AppStorage("photo.viewerMiB") private var viewer = 1024
    @AppStorage("photo.storageTimeout") private var markTimeout = 60
    @AppStorage("photo.deletionStallTimeout") private var deletionStallTimeout = 90
    private final class ShortcutEditor: ObservableObject {
        @Published var recording: PhotoCommand?
        @Published var message = ""
        @Published var revision = 0
    }
    @StateObject private var editor = ShortcutEditor()

    var body: some View {
        TabView {
            Form {
                Picker("缩略图缓存（MiB）", selection: $thumbnails) {
                    ForEach([0, 128, 256, 512, 1024, 2048], id: \.self) { Text("\($0)").tag($0) }
                }
                Picker("大图缓存（MiB）", selection: $viewer) {
                    ForEach([0, 256, 512, 1024, 2048, 4096], id: \.self) { Text("\($0)").tag($0) }
                }
                Picker("单张照片标记等待上限", selection: $markTimeout) {
                    ForEach([30, 60, 90, 120, 180], id: \.self) { Text("\($0) 秒").tag($0) }
                }
                Picker("删除无进展提醒", selection: $deletionStallTimeout) {
                    ForEach([30, 60, 90, 120, 180, 300, 600], id: \.self) { Text("\($0) 秒").tag($0) }
                }
                Text("每张照片的标记单独计时。批量删除有进展时可继续，停滞后暂停后续操作，并等待已提交的操作返回。")
                    .foregroundStyle(.secondary)
                Text("缓存设为 0 可停用。")
                    .foregroundStyle(.secondary)
            }.formStyle(.grouped)
                .onChange(of: thumbnails) { _, value in ImageCache.shared.setLimit(value) }
                .onChange(of: viewer) { _, value in Task { await ViewerImageCache.shared.setMaximumBytes(value * 1024 * 1024) } }
                .tabItem { Label("存储", systemImage: "internaldrive") }
            VStack(alignment: .leading) {
                Text(editor.message.isEmpty ? "点击快捷键后按下新组合键。按 Esc 取消。" : editor.message).foregroundStyle(.secondary)
                ScrollView {
                    Grid(alignment: .leading, horizontalSpacing: 15, verticalSpacing: 8) {
                        ForEach(PhotoCommand.allCases) { command in
                            GridRow {
                                Text(command.title)
                                Button(editor.recording == command ? "请按键…" : command.shortcut.display) {
                                    editor.recording = command
                                    editor.message = ""
                                }.frame(minWidth: 100)
                                Button("清除") { assign(.init(""), to: command) }
                                Button("默认") { assign(command.defaultShortcut, to: command) }
                            }
                        }
                    }.id(editor.revision).padding(4)
                }
                Button("恢复全部默认快捷键") {
                    for command in PhotoCommand.allCases { command.set(command.defaultShortcut) }
                    editor.recording = nil
                    editor.message = ""
                    editor.revision += 1
                }
            }.padding(16)
                .background(PhotoShortcutMonitor(handle: capture))
                .tabItem { Label("快捷键", systemImage: "keyboard") }
        }.frame(width: 560, height: 440)
    }

    private func capture(_ event: NSEvent) -> Bool {
        guard let recording = editor.recording else { return false }
        if event.keyCode == 53 { editor.recording = nil; return true }
        guard let shortcut = PhotoShortcut(event: event), shortcut.canRecord else {
            editor.message = "请选择可用的组合键，并避开系统菜单快捷键。"
            return true
        }
        assign(shortcut, to: recording)
        return true
    }
    private func assign(_ shortcut: PhotoShortcut, to command: PhotoCommand) {
        if !shortcut.key.isEmpty, let other = PhotoCommand.allCases.first(where: { $0 != command && $0.shortcut == shortcut }) {
            editor.message = "这个快捷键已用于「\(other.title)」。"
            return
        }
        command.set(shortcut)
        editor.recording = nil
        editor.message = ""
        editor.revision += 1
    }
}
