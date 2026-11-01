import AppKit
import SwiftUI
import ImageIO

private actor PhotoDecoder {
    static let shared = PhotoDecoder()
    func decode(_ url: URL) -> CGImage? {
        guard !Task.isCancelled,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 8000] as CFDictionary),
              !Task.isCancelled else { return nil }
        return image
    }
}

@MainActor final class PhotoViewerController: NSWindowController, NSWindowDelegate {
    private weak var store: LibraryStore?
    init(store: LibraryStore) {
        self.store = store
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1160, height: 800), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "拾影 · 大图查看"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .black
        window.minSize = NSSize(width: 700, height: 500)
        window.collectionBehavior = [.fullScreenPrimary]
        window.isReleasedWhenClosed = false
        window.acceptsMouseMovedEvents = true
        super.init(window: window)
        window.delegate = self
        window.contentView = NSHostingView(rootView: ViewerView().environmentObject(store))
        window.center()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func windowDidEnterFullScreen(_ notification: Notification) { store?.viewerFullScreen = true }
    func windowDidExitFullScreen(_ notification: Notification) { store?.viewerFullScreen = false }
    func windowWillClose(_ notification: Notification) {
        store?.viewerFullScreen = false
        store?.viewer = false
        store?.viewerController = nil
        window?.contentView = nil
    }
}

struct InteractivePhoto: NSViewRepresentable {
    let url: URL
    let fitToken: Int
    let fullScreen: Bool
    var navigatorVisible = true
    var evaluate: (() -> Void)? = nil
    var showInfo: (() -> Void)? = nil
    var activated: (() -> Void)? = nil
    var toggleNavigator: (() -> Void)? = nil
    var rejected = false
    var navigatorTopInset: CGFloat = 0
    let previous: () -> Void
    let next: () -> Void
    let mark: () -> Void
    func makeNSView(context: Context) -> PhotoCanvas { PhotoCanvas() }
    func updateNSView(_ view: PhotoCanvas, context: Context) {
        view.previous = previous; view.next = next; view.mark = mark
        view.evaluate = evaluate; view.showInfo = showInfo; view.activated = activated
        view.toggleNavigator = toggleNavigator; view.rejected = rejected
        view.navigatorTopInset = navigatorTopInset
        view.fullScreen = fullScreen
        view.navigatorVisible = navigatorVisible
        if view.url != url { view.load(url) }
        if view.fitToken != fitToken { view.fitToken = fitToken; view.fit() }
    }
    static func dismantleNSView(_ view: PhotoCanvas, coordinator: ()) { view.dispose() }
}

final class PhotoCanvas: NSView {
    var previous: (() -> Void)?
    var next: (() -> Void)?
    var mark: (() -> Void)?
    var evaluate: (() -> Void)?
    var showInfo: (() -> Void)?
    var activated: (() -> Void)?
    var toggleNavigator: (() -> Void)?
    var rejected = false
    var navigatorTopInset: CGFloat = 0
    var url: URL?
    var fitToken = 0
    var fullScreen = false { didSet { if oldValue != fullScreen { needsDisplay = true } } }
    var navigatorVisible = true { didSet { if oldValue != navigatorVisible { needsDisplay = true } } }
    private var image: NSImage?
    private var navigatorImage: NSImage?
    private var loading: Task<Void, Never>?
    private var zoom: CGFloat = 1
    private var offset = NSPoint.zero
    private var anchor = NSPoint.zero
    private var navigatorDragging = false
    private var navigatorGrab = NSPoint.zero
    private var dragging = false
    private var spaceHeld = false
    private var tracking: NSTrackingArea?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .image }
    override func accessibilityLabel() -> String? { "照片画布" }
    override func accessibilityValue() -> Any? { "适应比例 \(Int(zoom * 100))%" + (showsNavigator ? "，全图导航已显示" : "") }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); window?.makeFirstResponder(self) }
    func load(_ url: URL) {
        loading?.cancel(); self.url = url; image = nil; navigatorImage = nil; fit()
        loading = Task { @MainActor [weak self] in
            // Decode away from the UI thread, retaining EXIF orientation for RAW/JPG.
            let decoded = await PhotoDecoder.shared.decode(url)
            guard !Task.isCancelled, let self, self.url == url else { return }
            self.loading = nil
            self.image = decoded.map { NSImage(cgImage: $0, size: .zero) }
            // Cache a small navigator raster once, avoiding repeated full-photo
            // downsampling during every wheel or drag event.
            if let decoded {
                let factor = min(400 / CGFloat(decoded.width), 270 / CGFloat(decoded.height))
                let w = max(1, Int(CGFloat(decoded.width) * factor)), h = max(1, Int(CGFloat(decoded.height) * factor))
                if let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                    context.interpolationQuality = .medium
                    context.draw(decoded, in: CGRect(x: 0, y: 0, width: w, height: h))
                    self.navigatorImage = context.makeImage().map { NSImage(cgImage: $0, size: .zero) }
                }
            }
            self.needsDisplay = true
        }
    }
    func dispose() { loading?.cancel() }
    func fit() {
        zoom = 1; offset = .zero; navigatorDragging = false
        needsDisplay = true
    }
    private var fitSize: NSSize {
        guard let size = image?.size, size.width > 0, size.height > 0 else { return .zero }
        let factor = min(bounds.width / size.width, bounds.height / size.height)
        return NSSize(width: size.width * factor, height: size.height * factor)
    }
    private func clampOffset() {
        let size = fitSize
        let x = max(0, (size.width * zoom - bounds.width) / 2)
        let y = max(0, (size.height * zoom - bounds.height) / 2)
        offset.x = min(max(offset.x, -x), x); offset.y = min(max(offset.y, -y), y)
    }
    override func layout() { super.layout(); clampOffset(); needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: bounds).addClip()
        NSColor.black.setFill(); bounds.fill()
        guard let image else {
            let text = loading == nil ? "无法预览这张照片" : "正在读取照片…"
            (text as NSString).draw(at: NSPoint(x: max(15, bounds.midX - 65), y: bounds.midY), withAttributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.secondaryLabelColor])
            return
        }
        let rect = ViewerGeometry.imageRect(viewport: bounds.size, fitSize: fitSize, zoom: zoom, offset: offset)
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        if showsNavigator { drawNavigator(image) }
    }
    private var showsNavigator: Bool { navigatorVisible && zoom > 1.001 && image != nil }
    private var thumbnailRect: NSRect {
        let size = image?.size ?? NSSize(width: 1, height: 1)
        let scale = min(200 / max(size.width, 1), 135 / max(size.height, 1))
        return NSRect(x: 20, y: 20 + navigatorTopInset, width: size.width * scale, height: size.height * scale)
    }
    private var navigatorViewport: NSRect {
        let normalized = ViewerGeometry.visibleRegion(viewport: bounds.size, fitSize: fitSize, zoom: zoom, offset: offset)
        let thumbnail = thumbnailRect
        return NSRect(x: thumbnail.minX + normalized.minX * thumbnail.width,
                      y: thumbnail.minY + normalized.minY * thumbnail.height,
                      width: normalized.width * thumbnail.width, height: normalized.height * thumbnail.height)
    }
    private func drawNavigator(_ image: NSImage) {
        let image = navigatorImage ?? image
        let thumbnail = thumbnailRect
        let panel = thumbnail.insetBy(dx: -8, dy: -8)
        NSColor.black.withAlphaComponent(0.72).setFill()
        NSBezierPath(roundedRect: panel, xRadius: 8, yRadius: 8).fill()
        image.draw(in: thumbnail, from: .zero, operation: .sourceOver, fraction: 0.5, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.medium])
        let viewport = navigatorViewport
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: viewport).addClip()
        image.draw(in: thumbnail, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.medium])
        NSGraphicsContext.restoreGraphicsState()
        NSColor.white.setStroke()
        let outline = NSBezierPath(rect: viewport.insetBy(dx: 0.75, dy: 0.75)); outline.lineWidth = 1.5; outline.stroke()
    }
    private func moveNavigator(to point: NSPoint) {
        let thumbnail = thumbnailRect
        let normalized = NSPoint(x: (point.x - thumbnail.minX) / thumbnail.width - navigatorGrab.x,
                                 y: (point.y - thumbnail.minY) / thumbnail.height - navigatorGrab.y)
        offset = ViewerGeometry.offsetForCenter(normalized, fitSize: fitSize, zoom: zoom)
        clampOffset(); needsDisplay = true
    }
    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: .zero, options: [.activeInKeyWindow, .inVisibleRect, .cursorUpdate, .mouseEnteredAndExited, .mouseMoved], owner: self)
        addTrackingArea(tracking!); super.updateTrackingAreas()
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func cursorUpdate(with event: NSEvent) {
        guard let root = window?.contentView else { return }
        let hit = root.hitTest(root.convert(event.locationInWindow, from: nil))
        if hit === self { (dragging ? NSCursor.closedHand : NSCursor.openHand).set() }
        else { NSCursor.arrow.set() }
    }
    override func mouseExited(with event: NSEvent) { NSCursor.arrow.set() }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        activated?()
        let point = convert(event.locationInWindow, from: nil)
        if showsNavigator && thumbnailRect.insetBy(dx: -8, dy: -8).contains(point) {
            navigatorDragging = true
            let viewport = navigatorViewport
            navigatorGrab = viewport.contains(point) ? NSPoint(x: (point.x - viewport.midX) / thumbnailRect.width, y: (point.y - viewport.midY) / thumbnailRect.height) : .zero
            moveNavigator(to: point); NSCursor.closedHand.set(); return
        }
        if event.clickCount == 2 { fit(); return }
        dragging = true; NSCursor.closedHand.set()
    }
    override func mouseDragged(with event: NSEvent) {
        if navigatorDragging { moveNavigator(to: convert(event.locationInWindow, from: nil)); return }
        offset.x += event.deltaX; offset.y += event.deltaY
        clampOffset(); needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) { dragging = false; navigatorDragging = false; NSCursor.openHand.set() }
    override func mouseMoved(with event: NSEvent) {
        if spaceHeld && !navigatorDragging {
            offset.x += event.deltaX; offset.y += event.deltaY
            clampOffset(); needsDisplay = true; NSCursor.closedHand.set()
        }
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        window?.makeFirstResponder(self); activated?()
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self; menu.addItem(item)
        }
        add("适应窗口", #selector(contextFit))
        if evaluate != nil { add("评测此图片", #selector(contextEvaluate)) }
        if showInfo != nil { add("查看评测信息", #selector(contextInfo)) }
        menu.addItem(.separator())
        add(rejected ? "取消待删除" : "标记待删除", #selector(contextMark))
        add(navigatorVisible ? "隐藏导航预览" : "显示导航预览", #selector(contextNavigator))
        return menu
    }
    @objc private func contextFit() { fit() }
    @objc private func contextEvaluate() { evaluate?() }
    @objc private func contextInfo() { showInfo?() }
    @objc private func contextMark() { mark?() }
    @objc private func contextNavigator() { if let toggleNavigator { toggleNavigator() } else { navigatorVisible.toggle() } }
    override func keyDown(with event: NSEvent) {
        let characters = event.charactersIgnoringModifiers?.lowercased()
        if characters == "f", event.modifierFlags.intersection([.command, .control, .option]).isEmpty { fit(); return }
        if characters == "0", event.modifierFlags.contains(.command) { fit(); return }
        switch event.keyCode {
        case 49: spaceHeld = true; NSCursor.openHand.set()
        case 51, 117: if !event.isARepeat { mark?() }
        case 123: previous?()
        case 124: next?()
        case 3: fit()
        case 29 where event.modifierFlags.contains(.command): fit()
        case 53:
            if window?.styleMask.contains(.fullScreen) == true { window?.toggleFullScreen(nil) }
            else { window?.close() }
        default: super.keyDown(with: event)
        }
    }
    override func keyUp(with event: NSEvent) { if event.keyCode == 49 { spaceHeld = false; NSCursor.openHand.set() } else { super.keyUp(with: event) } }
    override func scrollWheel(with event: NSEvent) {
        guard image != nil else { return }
        anchor = convert(event.locationInWindow, from: nil)
        // Ignore synthesized inertia: zoom follows input immediately and stops on release.
        guard event.momentumPhase.isEmpty else { return }
        changeZoom(to: zoom * exp(event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 0.008 : 0.055)))
    }
    override func magnify(with event: NSEvent) {
        anchor = convert(event.locationInWindow, from: nil)
        changeZoom(to: zoom * (1 + event.magnification))
    }
    private func changeZoom(to value: CGFloat) {
        let updated = min(20, max(1, value))
        offset = ViewerGeometry.zoomOffset(offset: offset, anchor: anchor, viewport: bounds.size, ratio: updated / zoom)
        zoom = updated; clampOffset(); needsDisplay = true
    }
}
