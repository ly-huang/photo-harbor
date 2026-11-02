import SwiftUI
import AppKit

struct MainToolbar: NSViewRepresentable {
    @ObservedObject var store: LibraryStore
    func makeNSView(context: Context) -> Installer { let view = Installer(); view.store = store; return view }
    func updateNSView(_ view: Installer, context: Context) { view.store = store; view.install() }
    final class Installer: NSView, NSToolbarDelegate {
        var store: LibraryStore?
        private var installed: NSToolbar?
        private var actionGroup: NSToolbarItemGroup?
        private let actions = NSToolbarItem.Identifier("PhotoHarbor.WindowActions")
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); install() }
        func install() {
            refreshEnabledState()
            guard let window, installed == nil, store != nil else { return }
            let toolbar = NSToolbar(identifier: "PhotoHarbor.MainToolbar")
            toolbar.delegate = self; toolbar.displayMode = .iconOnly
            toolbar.allowsUserCustomization = false
            installed = toolbar; window.toolbar = toolbar; window.toolbarStyle = .unifiedCompact
            window.titleVisibility = .hidden
        }
        func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.flexibleSpace, actions] }
        func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.flexibleSpace, actions] }
        func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
            guard id == actions else { return nil }
            let labels = ["重新扫描", "打开相册", "导入照片", "滤镜 / LUT 管理"]
            let symbols = ["arrow.clockwise", "folder.badge.plus", "square.and.arrow.down", "cube.transparent"]
            let images = zip(symbols, labels).map { symbol, label in
                let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)!
                    .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 16, weight: .regular))!
                image.size = NSSize(width: 18, height: 18)
                // Keep a fixed optical box: toolbar symbol configuration otherwise
                // enlarges SF Symbols independently of the segmented control.
                let fixedImage = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
                    image.draw(in: rect.insetBy(dx: 1, dy: 1)); return true
                }
                fixedImage.isTemplate = true
                fixedImage.accessibilityDescription = label
                return fixedImage
            }
            // Let AppKit lay out both the segmented control and its glass backing.
            // A hosted SwiftUI view used a different vertical alignment from the backing.
            let group = NSToolbarItemGroup(itemIdentifier: id, images: images, selectionMode: .momentary, labels: nil, target: self, action: #selector(performAction(_:)))
            group.label = "照片操作"; group.controlRepresentation = .expanded
            group.autovalidates = false
            for (index, item) in group.subitems.enumerated() {
                item.label = labels[index]; item.toolTip = labels[index]; item.autovalidates = false
            }
            if let control = group.view as? NSSegmentedControl {
                control.controlSize = .regular
                for index in labels.indices { control.setToolTip(labels[index], forSegment: index); control.setWidth(32, forSegment: index); control.setImageScaling(.scaleNone, forSegment: index) }
            }
            actionGroup = group; refreshEnabledState()
            return group
        }
        private func refreshEnabledState() {
            guard let store, let group = actionGroup else { return }
            for (index, item) in group.subitems.enumerated() {
                let enabled = !store.busy && (index != 0 || !store.albums.isEmpty)
                item.isEnabled = enabled
                (group.view as? NSSegmentedControl)?.setEnabled(enabled, forSegment: index)
            }
        }
        @objc private func performAction(_ sender: Any?) {
            guard let store, !store.busy else { return }
            let index = (sender as? NSToolbarItemGroup)?.selectedIndex ?? (sender as? NSSegmentedControl)?.selectedSegment ?? -1
            switch index {
            case 0: if !store.albums.isEmpty { store.scan() }
            case 1: store.settings = true
            case 2: store.importing = true
            case 3: LUTManagerController.show(directory: store.stateURL.deletingLastPathComponent())
            default: break
            }
        }
    }
}
