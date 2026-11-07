import AppKit
import SwiftUI
import ImageIO

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
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if let request = store?.editorCloseRequest { request(); return false }
        return true
    }
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
    var overrideImage: CGImage? = nil
    var comparisonImage: CGImage? = nil
    var comparisonEditedImage: CGImage? = nil
    var comparisonActive = false
    var rotationActive = false
    var brushTool: CorrectionTool? = nil
    var brushDiameter = 0.035
    var paint: ((CGPoint)->Void)? = nil
    var painting: ((Bool)->Void)? = nil
    var cropActive = false
    var cropAspect: CGFloat? = nil
    var cropSelection: CGRect? = nil
    var cropChanged: ((CGRect) -> Void)? = nil
    var exit: (() -> Void)? = nil
    var evaluate: (() -> Void)? = nil
    var showInfo: (() -> Void)? = nil
    var activated: (() -> Void)? = nil
    var toggleNavigator: (() -> Void)? = nil
    var labels:Set<PhotoLabel>=[]
    var labelChanged:((PhotoLabel?)->Void)?=nil
    var contextMarkAction:(()->Void)?=nil
    var rejected = false
    var navigatorTopInset: CGFloat = 0
    let previous: () -> Void
    let next: () -> Void
    let mark: () -> Void
    func makeNSView(context: Context) -> PhotoCanvas { PhotoCanvas() }
    func updateNSView(_ view: PhotoCanvas, context: Context) {
        view.previous = previous; view.next = next; view.mark = mark
        view.evaluate = evaluate; view.showInfo = showInfo; view.activated = activated
        view.labels=labels;view.labelChanged=labelChanged;view.contextMarkAction=contextMarkAction
        view.toggleNavigator = toggleNavigator; view.rejected = rejected
        view.navigatorTopInset = navigatorTopInset
        view.fullScreen = fullScreen
        view.navigatorVisible = navigatorVisible
        view.exit = exit
        view.comparisonActive = comparisonActive
        if view.rotationActive != rotationActive { view.rotationActive = rotationActive; view.fit(); view.window?.invalidateCursorRects(for: view) }
        view.comparisonEditedImage = comparisonEditedImage.map { NSImage(cgImage: $0, size: .zero) }
        view.comparisonImage = comparisonImage.map { NSImage(cgImage: $0, size: .zero) }
        if view.cropActive != cropActive { view.cropActive = cropActive; view.fit(); view.window?.invalidateCursorRects(for: view) }
        if view.cropDragMode == -1 { view.cropSelection = cropSelection }
        view.brushTool=brushTool;view.brushDiameter=brushDiameter;view.paint=paint;view.painting=painting
        view.cropChanged = cropChanged
        view.cropAspect = cropAspect
        if cropActive || rotationActive { view.splitHeld = false }
        view.needsDisplay = true
        if let overrideImage { view.present(overrideImage) } else if view.url != url { view.load(url) }
        if view.fitToken != fitToken { view.fitToken = fitToken; view.fit() }
    }
    static func dismantleNSView(_ view: PhotoCanvas, coordinator: ()) { view.dispose() }
}

final class PhotoCanvas: NSView {
    var exit: (() -> Void)?
    private var presented: CGImage?
    var comparisonImage: NSImage?
    var comparisonEditedImage: NSImage?
    var splitHeld = false
    var isComparing: Bool { comparisonActive || splitHeld }
    var brushTool: CorrectionTool?
    var brushDiameter = 0.035
    var brushPoint: CGPoint?
    var paint: ((CGPoint)->Void)?
    var painting: ((Bool)->Void)?
    private var paintingStroke = false
    var rotationActive = false
    var comparisonActive = false
    var comparisonX: CGFloat?
    var cropActive = false
    var cropAspect: CGFloat?
    var cropSelection: CGRect?
    var cropChanged: ((CGRect) -> Void)?
    var cropStart = CGPoint.zero
    var cropInitial = CGRect.zero
    var cropDragMode = -1
    var editingImageRect: CGRect { ViewerGeometry.imageRect(viewport: bounds.size, fitSize: fitSize, zoom: zoom, offset: offset) }
    var previous: (() -> Void)?
    var next: (() -> Void)?
    var mark: (() -> Void)?
    var evaluate: (() -> Void)?
    var showInfo: (() -> Void)?
    var activated: (() -> Void)?
    var toggleNavigator: (() -> Void)?
    var labels:Set<PhotoLabel>=[]
    var labelChanged:((PhotoLabel?)->Void)?
    var contextMarkAction:(()->Void)?
    var rejected = false
    var navigatorTopInset: CGFloat = 0
    var url: URL?
    var fitToken = 0
    var fullScreen = false { didSet { if oldValue != fullScreen { needsDisplay = true } } }
    var navigatorVisible = true { didSet { if oldValue != navigatorVisible { needsDisplay = true } } }
    private var image: NSImage?
    private var navigatorImage: NSImage?
    private var navigatorSource: CGImage?
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
    override func accessibilityValue() -> Any? {
        var value = "适应比例 \(Int(zoom * 100))%" + (showsNavigator ? "，全图导航已显示" : "")
        if cropActive, let r = cropSelection { value += String(format: "，裁剪框 X %.1f%% Y %.1f%% 宽 %.1f%% 高 %.1f%%", r.minX * 100, r.minY * 100, r.width * 100, r.height * 100) }
        if isComparing { value += "，分割对比：左侧编辑前，右侧编辑后" }
        return value
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); window?.makeFirstResponder(self) }
    func load(_ url: URL) {
        loading?.cancel(); self.url = url; image = nil; navigatorImage = nil; navigatorSource = nil; fit()
        loading = Task { @MainActor [weak self] in
            // Decode away from the UI thread, retaining EXIF orientation for RAW/JPG.
            let decoded = await ViewerImageCache.shared.decode(url)
            guard !Task.isCancelled, let self, self.url == url else { return }
            self.loading = nil
            self.image = decoded.map { NSImage(cgImage: $0, size: .zero) }
            self.navigatorSource = decoded
            self.needsDisplay = true
        }
    }
    func present(_ image: CGImage) {
        guard presented !== image else { return }
        presented = image; loading?.cancel()
        self.image = NSImage(cgImage: image, size: .zero)
        self.navigatorSource = nil
        self.navigatorImage = self.image
        clampOffset(); needsDisplay = true
    }
    func dispose() { loading?.cancel() }
    func fit() {
        zoom = 1; offset = .zero; navigatorDragging = false
        needsDisplay = true
        refreshPointer()
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
        let base = isComparing ? (comparisonEditedImage ?? image) : image
        base.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        drawEditing(in: rect)
        if showsNavigator && !cropActive && !rotationActive && brushTool == nil { drawNavigator(image) }
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
        if let decoded = navigatorSource {
            navigatorSource = nil
            let factor = min(400 / CGFloat(decoded.width), 270 / CGFloat(decoded.height))
            let width = max(1, Int(CGFloat(decoded.width) * factor))
            let height = max(1, Int(CGFloat(decoded.height) * factor))
            if let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                context.interpolationQuality = .medium
                context.draw(decoded, in: CGRect(x: 0, y: 0, width: width, height: height))
                navigatorImage = context.makeImage().map { NSImage(cgImage: $0, size: .zero) }
            }
        }
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
    private func canPan(at point: CGPoint) -> Bool {
        image != nil && ViewerGeometry.canPan(at: point, imageRect: editingImageRect, viewport: bounds.size, zoom: zoom, headerInset: fullScreen ? 0 : 28)
    }
    private func pointer(at point: CGPoint) -> NSCursor {
        guard image != nil, bounds.contains(point), point.y >= (fullScreen ? 0 : 28), editingImageRect.contains(point) else { return .arrow }
        if cropActive || brushTool != nil || rotationActive || isComparing { return editingCursor }
        return canPan(at: point) ? (dragging || spaceHeld ? .closedHand : .openHand) : .arrow
    }
    private func refreshPointer() {
        window?.invalidateCursorRects(for: self)
        guard let window, let root = window.contentView else { return }
        let location = window.mouseLocationOutsideOfEventStream
        let hit = root.hitTest(root.convert(location, from: nil))
        (hit === self ? pointer(at: convert(location, from: nil)) : .arrow).set()
    }
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
        var region = editingImageRect.intersection(bounds)
        let header = fullScreen ? CGFloat(0) : 28
        region = region.intersection(CGRect(x: 0, y: header, width: bounds.width, height: max(0, bounds.height - header)))
        if !region.isNull { addCursorRect(region, cursor: pointer(at: CGPoint(x: region.midX, y: region.midY))) }
    }
    override func cursorUpdate(with event: NSEvent) {
        guard let root = window?.contentView else { return }
        let hit = root.hitTest(root.convert(event.locationInWindow, from: nil))
        if hit === self { pointer(at: convert(event.locationInWindow, from: nil)).set() }
        else { NSCursor.arrow.set() }
    }
    override func mouseExited(with event: NSEvent) { splitHeld = false; brushPoint=nil; needsDisplay = true; NSCursor.arrow.set() }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        activated?()
        let point = convert(event.locationInWindow, from: nil)
        if brushTool != nil { paintingStroke=true;painting?(true);paintAt(point);return }
        if rotationActive { return }
        if cropActive { beginCrop(at: point); NSCursor.crosshair.set(); return }
        if isComparing { comparisonX = point.x; needsDisplay = true }
        if showsNavigator && thumbnailRect.insetBy(dx: -8, dy: -8).contains(point) {
            navigatorDragging = true
            let viewport = navigatorViewport
            navigatorGrab = viewport.contains(point) ? NSPoint(x: (point.x - viewport.midX) / thumbnailRect.width, y: (point.y - viewport.midY) / thumbnailRect.height) : .zero
            moveNavigator(to: point); NSCursor.closedHand.set(); return
        }
        if event.clickCount == 2 { fit(); return }
        guard canPan(at: point) else { NSCursor.arrow.set(); return }
        dragging = true; NSCursor.closedHand.set()
    }
    override func mouseDragged(with event: NSEvent) {
        if paintingStroke { paintAt(convert(event.locationInWindow,from:nil));return }
        if splitHeld { comparisonX = convert(event.locationInWindow, from: nil).x; needsDisplay = true; return }
        if cropActive { dragCrop(to: convert(event.locationInWindow, from: nil)); return }
        if navigatorDragging { moveNavigator(to: convert(event.locationInWindow, from: nil)); return }
        guard dragging else { return }
        offset.x += event.deltaX; offset.y += event.deltaY
        clampOffset(); needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) { if paintingStroke { paintingStroke=false;painting?(false) };if cropActive { finishCrop(); cropDragMode = -1 }; dragging = false; navigatorDragging = false; refreshPointer() }
    override func mouseMoved(with event: NSEvent) {
        if brushTool != nil { brushPoint=convert(event.locationInWindow,from:nil);needsDisplay=true;return }
        updateSplit(flags: event.modifierFlags, point: convert(event.locationInWindow, from: nil))
        if rotationActive { return }
        if cropActive { return }
        if spaceHeld && !navigatorDragging && canPan(at: convert(event.locationInWindow, from: nil)) {
            offset.x += event.deltaX; offset.y += event.deltaY
            clampOffset(); needsDisplay = true; NSCursor.closedHand.set()
        }
        refreshPointer()
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
if labelChanged != nil {
            let parent=NSMenuItem(title:"颜色标记",action:nil,keyEquivalent:""),submenu=NSMenu()
            for (i,label) in PhotoLabel.allCases.enumerated(){
                let item=NSMenuItem(title:label.rawValue,action:#selector(contextLabel(_:)),keyEquivalent:"");item.target=self;item.tag=i;item.state=labels.contains(label) ? .on:.off
                item.attributedTitle=label.menuTitle;submenu.addItem(item)
            }
            submenu.addItem(.separator());let clear=NSMenuItem(title:"移除所有颜色标记",action:#selector(contextLabel(_:)),keyEquivalent:"");clear.target=self;clear.tag = -1;clear.isEnabled = !labels.isEmpty;submenu.addItem(clear);parent.submenu=submenu;menu.addItem(parent)
        }
        add(rejected ? "取消待删除" : "标记待删除", #selector(contextMark))
        add(navigatorVisible ? "隐藏导航预览" : "显示导航预览", #selector(contextNavigator))
        return menu
    }
    @objc private func contextLabel(_ item:NSMenuItem){labelChanged?(item.tag>=0 ? PhotoLabel.allCases[item.tag]:nil)}
    @objc private func contextFit() { fit() }
    @objc private func contextEvaluate() { evaluate?() }
    @objc private func contextInfo() { showInfo?() }
    @objc private func contextMark() { if let contextMarkAction{contextMarkAction()}else{mark?()} }
    @objc private func contextNavigator() { if let toggleNavigator { toggleNavigator() } else { navigatorVisible.toggle() } }
    private func paintAt(_ point:CGPoint) {
        let r=editingImageRect;guard r.contains(point),r.width>0,r.height>0 else{return}
        brushPoint=point;paint?(CGPoint(x:(point.x-r.minX)/r.width,y:(point.y-r.minY)/r.height));needsDisplay=true
    }
    private func updateSplit(flags: NSEvent.ModifierFlags, point: CGPoint) {
        let held = flags.contains(.option) && comparisonImage != nil && !cropActive && !rotationActive && brushTool == nil
        if held != splitHeld || held { splitHeld = held; comparisonX = point.x; needsDisplay = true }
    }
    override func flagsChanged(with event: NSEvent) {
        updateSplit(flags: event.modifierFlags, point: convert(window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil))
    }
    override func keyDown(with event: NSEvent) {
        let characters = event.charactersIgnoringModifiers?.lowercased()
        if characters == "f", event.modifierFlags.intersection([.command, .control, .option]).isEmpty { fit(); return }
        if characters == "0", event.modifierFlags.contains(.command) { fit(); return }
        switch event.keyCode {
        case 49: spaceHeld = true; refreshPointer()
        case 51, 117: if !event.isARepeat { mark?() }
        case 123: previous?()
        case 124: next?()
        case 3: fit()
        case 29 where event.modifierFlags.contains(.command): fit()
        case 53:
            if let exit { exit(); return }
            if window?.styleMask.contains(.fullScreen) == true { window?.toggleFullScreen(nil) }
            else { window?.close() }
        default: super.keyDown(with: event)
        }
    }
    override func keyUp(with event: NSEvent) { if event.keyCode == 49 { spaceHeld = false; refreshPointer() } else { super.keyUp(with: event) } }
    override func scrollWheel(with event: NSEvent) {
        if cropActive || rotationActive { return }
        guard image != nil else { return }
        anchor = convert(event.locationInWindow, from: nil)
        // Ignore synthesized inertia: zoom follows input immediately and stops on release.
        guard event.momentumPhase.isEmpty else { return }
        changeZoom(to: zoom * exp(event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 0.008 : 0.055)))
    }
    override func magnify(with event: NSEvent) {
        if cropActive || rotationActive { return }
        anchor = convert(event.locationInWindow, from: nil)
        changeZoom(to: zoom * (1 + event.magnification))
    }
    private func changeZoom(to value: CGFloat) {
        let updated = min(20, max(1, value))
        offset = ViewerGeometry.zoomOffset(offset: offset, anchor: anchor, viewport: bounds.size, ratio: updated / zoom)
        zoom = updated; clampOffset(); needsDisplay = true
        refreshPointer()
    }
}
