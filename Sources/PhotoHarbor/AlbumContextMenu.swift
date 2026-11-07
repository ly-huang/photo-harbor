import AppKit
import SwiftUI

struct AlbumContextMenu: NSViewRepresentable {
    let roots: [URL]
    let canClose: Bool
    let close: () -> Void

    func makeNSView(context: Context) -> MenuView { MenuView() }

    func updateNSView(_ view: MenuView, context: Context) {
        view.roots = roots
        view.canClose = canClose
        view.close = close
    }

    final class MenuView: NSView {
        var roots: [URL] = []
        var canClose = false
        var close: (() -> Void)?

        // Let ordinary clicks pass through to the SwiftUI album row.
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent,
                  event.type == .rightMouseDown ||
                    (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
            else { return nil }
            return super.hitTest(point)
        }

        override func rightMouseDown(with event: NSEvent) { showMenu(for: event) }
        override func mouseDown(with event: NSEvent) { showMenu(for: event) }

        private func showMenu(for event: NSEvent) {
            let menu = NSMenu()
            menu.autoenablesItems = false
            let reveal = NSMenuItem(title: "在 Finder 中显示", action: #selector(revealAlbum), keyEquivalent: "")
            reveal.target = self
            menu.addItem(reveal)
            let closeItem = NSMenuItem(title: "关闭相册", action: #selector(closeAlbum), keyEquivalent: "")
            closeItem.target = self
            closeItem.isEnabled = canClose
            closeItem.toolTip = "只从列表关闭相册，磁盘照片保留。"
            menu.addItem(closeItem)
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }

        @objc private func revealAlbum() { NSWorkspace.shared.activateFileViewerSelecting(roots) }
        @objc private func closeAlbum() { close?() }
    }
}
