import SwiftUI
import AppKit

@MainActor final class ChromeState: ObservableObject {
    @Published var visible = true
    @Published var pinned = false
    private var hideTask: Task<Void, Never>?
    func reveal() { hideTask?.cancel(); hideTask = nil; if !visible { visible = true } }
    func scheduleHide() {
        guard visible, !pinned, hideTask == nil else { return }
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard !Task.isCancelled, let self, !self.pinned else { return }
            self.visible = false; self.hideTask = nil
        }
    }
    func togglePin() { pinned.toggle(); if pinned { reveal() } else { scheduleHide() } }
    func pointer(_ event: NSEvent, window: NSWindow) {
        guard let view = window.contentView else { return }
        let point = view.convert(event.locationInWindow, from: nil)
        let top = view.isFlipped ? point.y : view.bounds.height - point.y
        if top < 86 || top > view.bounds.height - 76 { reveal() } else { scheduleHide() }
    }
    func dispose() { hideTask?.cancel(); hideTask = nil }
}

struct ChromeTracking: NSViewRepresentable {
    let state: ChromeState
    var inspector: InspectorState? = nil
    var inspectorEnabled = true
    var inspectorWidth: CGFloat = 280
    func makeNSView(context: Context) -> Tracker { let view = Tracker(); view.state = state; view.inspector = inspector; view.inspectorEnabled = inspectorEnabled; view.inspectorWidth = inspectorWidth; return view }
    func updateNSView(_ view: Tracker, context: Context) { view.state = state; view.inspector = inspector; view.inspectorEnabled = inspectorEnabled; view.inspectorWidth = inspectorWidth }
    static func dismantleNSView(_ view: Tracker, coordinator: ()) { view.stop() }
    final class Tracker: NSView {
        weak var state: ChromeState?
        weak var inspector: InspectorState?
        var inspectorEnabled = true
        var inspectorWidth: CGFloat = 280
        var monitor: Any?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow(); stop()
            guard let window else { return }
            window.acceptsMouseMovedEvents = true
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .keyDown]) { [weak self, weak window] event in
                if let window, event.window === window {
                    if event.type == .keyDown, event.charactersIgnoringModifiers?.lowercased() == "h", event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
                        self?.state?.togglePin(); return nil
                    }
                    if event.type != .keyDown { self?.state?.pointer(event, window: window); self?.inspector?.pointer(event, window: window, enabled: self?.inspectorEnabled ?? false, panelWidth: self?.inspectorWidth ?? 280) }
                }
                return event
            }
            state?.scheduleHide()
        }
        func stop() { if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }; state?.dispose(); inspector?.dispose() }
    }
}

struct WindowTitleHider: NSViewRepresentable {
    func makeNSView(context: Context) -> TitleView { TitleView() }
    func updateNSView(_ view: TitleView, context: Context) { view.configure() }
    final class TitleView: NSView {
        func configure() {
            guard let window else { return }
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.styleMask.remove(.fullSizeContentView)
            window.toolbarStyle = .unifiedCompact
        }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); configure() }
    }
}

struct FloatingTools<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        HStack(spacing: 12) { content }.font(.system(size: 12)).buttonStyle(.borderless)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .modifier(PhotoGlass()).modifier(ArrowPointer())
            .shadow(color: .black.opacity(0.25), radius: 10, y: 3)
    }
}

struct PhotoGlass: ViewModifier {
    var radius: CGFloat = 16
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: radius))
        } else {
            content.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: radius))
        }
    }
}

struct ScoreBadge: View {
    let score: Double
    var body: some View {
        Label(String(format: "%.1f", score), systemImage: "star.fill")
            .font(.caption.weight(.semibold)).monospacedDigit()
            .padding(.horizontal, 9).padding(.vertical, 6)
            .modifier(PhotoGlass(radius: 20)).help("审美参考分，不是客观质量结论")
    }
}

@MainActor final class InspectorState: ObservableObject {
    @Published var visible = false
    @Published var pinned = false
    private var hideTask: Task<Void, Never>?
    func reveal() { hideTask?.cancel(); hideTask = nil; if !visible { visible = true } }
    func togglePin() { pinned.toggle(); if pinned { reveal() } }
    func pointer(_ event: NSEvent, window: NSWindow, enabled: Bool, panelWidth: CGFloat = 280) {
        guard !pinned else { return }
        guard enabled, let view = window.contentView else { visible = false; return }
        let point = view.convert(event.locationInWindow, from: nil)
        pointer(x: point.x, width: view.bounds.width, enabled: enabled, panelWidth: panelWidth)
    }
    func pointer(x: CGFloat, width: CGFloat, enabled: Bool, panelWidth: CGFloat = 280) {
        guard !pinned else { return }
        guard enabled else { visible = false; return }
        if x > width - (visible ? panelWidth + 24 : 24) { reveal() }
        else if visible && hideTask == nil {
            hideTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled, let self, !self.pinned else { return }
                self.visible = false; self.hideTask = nil
            }
        }
    }
    func dispose() { hideTask?.cancel(); hideTask = nil }
}

struct SidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView(); view.material = .sidebar
        view.blendingMode = .behindWindow; view.state = .active; return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

struct ArrowPointer: ViewModifier {
    func body(content: Content) -> some View {
        content.onContinuousHover { phase in
            if case .active = phase { NSCursor.arrow.set() }
        }
    }
}

struct WindowHeaderMaterial: View {
    var body: some View { Rectangle().fill(.ultraThinMaterial) }
}

struct NavigatorToggle: View {
    @Binding var visible: Bool
    var body: some View {
        Button { visible.toggle() } label: {
            Label(visible ? "导航已开启" : "导航已关闭", systemImage: visible ? "rectangle.inset.filled" : "rectangle")
                .labelStyle(.iconOnly).foregroundStyle(.primary)
                .padding(4)
        }.help(visible ? "导航已开启，点击隐藏缩放预览" : "导航已关闭，点击显示缩放预览")
            .accessibilityValue(visible ? "开启" : "关闭")
    }
}
