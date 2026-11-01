import SwiftUI
import AppKit

@main struct PhotoHarborApp: App {
    @NSApplicationDelegateAdaptor(PhotoHarborDelegate.self) private var appDelegate
    @StateObject private var store = LibraryStore()
    var body: some Scene {
        WindowGroup("拾影 Photo Harbor") {
            LibraryView().environmentObject(store)
                .frame(minWidth: 1060, minHeight: 680)
                .preferredColorScheme(.dark)
                .onAppear {
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
        }
        .defaultSize(width: 1380, height: 880)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("导入照片…") { store.importing = true }.keyboardShortcut("i").disabled(store.busy)
                Button("打开相册…") { store.settings = true }.keyboardShortcut("o").disabled(store.busy)
            }
            CommandMenu("照片") {
                Button("重新扫描") { store.scan() }.keyboardShortcut("r").disabled(store.busy)
                Button("查看大图") { if store.focused != nil { store.showViewer() } }.keyboardShortcut(.return, modifiers: [])
                Button("标记 / 取消待删除") { if let photo = store.focused { store.toggleReject(photo) } }.keyboardShortcut(.delete, modifiers: []).disabled(store.focused == nil || store.busy)
                Divider()
                Button("撤销最近一批删除") { store.undoTrash() }.keyboardShortcut("z").disabled(store.busy || store.undoBatches.isEmpty)
                Button("查看删除记录…") { store.history = true }
            }
        }
    }
}
