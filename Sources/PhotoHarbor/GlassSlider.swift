import SwiftUI

/// Horizontal fine adjustment with a compact vertical glass thumb.
struct GlassSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var onEditingChanged: (Bool) -> Void = { _ in }
    @Environment(\.isEnabled) private var enabled
    @ViewState private var dragging = false
    var body: some View {
        GeometryReader { geometry in
            let width = max(1, geometry.size.width - 8)
            let fraction = min(1, max(0, (value - range.lowerBound) / max(0.000001, range.upperBound - range.lowerBound)))
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.12)).frame(height: 3)
                Capsule().fill(Color.accentColor.opacity(0.75)).frame(width: width * fraction + 4, height: 3)
                thumb.frame(width: 6, height: 16).offset(x: width * fraction + 1)
            }.frame(height: 24).contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { event in
                    guard enabled else { return }
                    if !dragging { dragging = true; onEditingChanged(true) }
                    value = range.lowerBound + min(1, max(0, (event.location.x - 4) / width)) * (range.upperBound - range.lowerBound)
                }.onEnded { _ in if dragging { dragging = false; onEditingChanged(false) } })
        }.frame(height: 24).opacity(enabled ? 1 : 0.4)
        .focusable(enabled).focusEffectDisabled()
        .onKeyPress(.leftArrow) { adjust(-1); return .handled }
        .onKeyPress(.rightArrow) { adjust(1); return .handled }
        .accessibilityRepresentation { Slider(value: $value, in: range, onEditingChanged: onEditingChanged) }
    }
    @ViewBuilder private var thumb: some View {
        if #available(macOS 26.0, *) {
            RoundedRectangle(cornerRadius: 3).fill(.white.opacity(0.24)).glassEffect(.regular, in: RoundedRectangle(cornerRadius: 3))
                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(.white.opacity(0.55), lineWidth: 0.5))
        } else {
            RoundedRectangle(cornerRadius: 3).fill(.ultraThinMaterial).overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(.white.opacity(0.55), lineWidth: 0.5))
        }
    }
    private func adjust(_ direction: Double) {
        guard enabled else { return }
        onEditingChanged(true)
        value = min(range.upperBound, max(range.lowerBound, value + direction * (range.upperBound - range.lowerBound) / 200))
        onEditingChanged(false)
    }
}
