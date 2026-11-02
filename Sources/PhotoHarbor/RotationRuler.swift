import SwiftUI
import AppKit

struct RotationRuler: NSViewRepresentable {
    @Binding var angle: Double
    let editing: (Bool) -> Void
    var title = "旋转角度"
    func makeNSView(context: Context) -> AngleRulerView { AngleRulerView() }
    func updateNSView(_ view: AngleRulerView, context: Context) { view.rulerTitle=title;view.toolTip="左右拖动调整\(title)；滚轮和方向键精调；双击归零";view.angle = angle; view.changed = { angle = $0 }; view.editing = editing; view.needsDisplay = true }
    static func dismantleNSView(_ view: AngleRulerView, coordinator: ()) { view.finish() }
}

final class AngleRulerView: NSView {
    var rulerTitle = "旋转角度"
    var angle = 0.0
    var changed: ((Double) -> Void)?
    var editing: ((Bool) -> Void)?
    private var startX: CGFloat = 0
    private var startAngle = 0.0
    private var interacting = false
    private var wheelEnd: DispatchWorkItem?
    private let pointsPerDegree: CGFloat = 6
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override init(frame frameRect: NSRect) { super.init(frame: frameRect); focusRingType = .none; toolTip = "左右拖动刻度调平；滚轮和方向键精调；双击归零" }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .slider }
    override func accessibilityLabel() -> String? { rulerTitle + "刻度尺" }
    override func accessibilityValue() -> Any? { angle }
    override func accessibilityMinValue() -> Any? { -45.0 }
    override func accessibilityMaxValue() -> Any? { 45.0 }
    override func setAccessibilityValue(_ value: Any?) { if let n = value as? NSNumber { begin(); set(n.doubleValue); finish() } }
    override func accessibilityPerformIncrement() -> Bool { step(0.1); return true }
    override func accessibilityPerformDecrement() -> Bool { step(-0.1); return true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.withAlphaComponent(0.13).setStroke()
        let baseline = NSBezierPath(); baseline.move(to: CGPoint(x: 0, y: 13)); baseline.line(to: CGPoint(x: bounds.width, y: 13)); baseline.lineWidth = 0.5; baseline.stroke()
        for degree in -45...45 {
            let x = bounds.midX + (CGFloat(degree) - angle) * pointsPerDegree
            guard x > 4 && x < bounds.width - 4 else { continue }
            let major = degree % 15 == 0, medium = degree % 5 == 0
            let fade = max(0.15, 1 - abs(x - bounds.midX) / max(1, bounds.midX))
            NSColor.white.withAlphaComponent((major ? 0.8 : 0.5) * fade).setStroke()
            let tick = NSBezierPath(); tick.move(to: CGPoint(x: x, y: major ? 0 : (medium ? 4 : 8))); tick.line(to: CGPoint(x: x, y: 14)); tick.lineWidth = 1; tick.stroke()
            if major { let text = "\(degree)" as NSString; text.draw(at: CGPoint(x: x - 8, y: 23), withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor]) }
        }
        NSColor.controlAccentColor.setFill(); NSBezierPath(roundedRect: CGRect(x: bounds.midX - 1, y: 0, width: 2, height: 19), xRadius: 1, yRadius: 1).fill()
    }
    private func begin() { wheelEnd?.cancel(); if !interacting { interacting = true; editing?(true) } }
    func finish() { wheelEnd?.cancel(); wheelEnd = nil; if interacting { interacting = false; editing?(false) } }
    private func set(_ value: Double, snap: Bool = false) { angle = min(45, max(-45, snap && abs(value) < 0.15 ? 0 : value)); changed?(angle); needsDisplay = true }
    private func step(_ delta: Double) { begin(); set(angle + delta); finish() }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self); begin()
        if event.clickCount == 2 { set(0); finish(); return }
        startX = convert(event.locationInWindow, from: nil).x; startAngle = angle
    }
    override func mouseDragged(with event: NSEvent) { let x = convert(event.locationInWindow, from: nil).x; set(startAngle + Double((startX - x) / pointsPerDegree), snap: true) }
    override func mouseUp(with event: NSEvent) { finish() }
    override func scrollWheel(with event: NSEvent) {
        guard event.momentumPhase.isEmpty else { return }
        begin(); let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
        set(angle + Double(delta) * (event.hasPreciseScrollingDeltas ? 0.02 : 0.1))
        let end = DispatchWorkItem { [weak self] in self?.finish() }; wheelEnd = end; DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: end)
    }
    override func keyDown(with event: NSEvent) { if event.keyCode == 123 { step(-0.1) } else if event.keyCode == 124 { step(0.1) } else { super.keyDown(with: event) } }
}
