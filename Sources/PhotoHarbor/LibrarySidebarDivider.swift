import AppKit
import SwiftUI

struct LibrarySidebarDivider: NSViewRepresentable {
    let onDrag: (CGFloat) -> Void
    let onEnd: (CGFloat) -> Void

    func makeNSView(context: Context) -> Handle { Handle() }

    func updateNSView(_ view: Handle, context: Context) {
        view.onDrag = onDrag
        view.onEnd = onEnd
    }

    final class Handle: NSView {
        var onDrag: ((CGFloat) -> Void)?
        var onEnd: ((CGFloat) -> Void)?
        private var startX: CGFloat?

        override func resetCursorRects() {
            super.resetCursorRects()
            addCursorRect(bounds, cursor: resizeCursor)
        }

        private var resizeCursor: NSCursor {
            if #available(macOS 15, *) { return .columnResize }
            return .resizeLeftRight
        }

        override func mouseDown(with event: NSEvent) {
            startX = event.locationInWindow.x
        }

        override func mouseDragged(with event: NSEvent) {
            guard let startX else { return }
            onDrag?(event.locationInWindow.x - startX)
        }

        override func mouseUp(with event: NSEvent) {
            guard let startX else { return }
            self.startX = nil
            onEnd?(event.locationInWindow.x - startX)
        }
    }
}
