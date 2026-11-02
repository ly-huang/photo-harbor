import SwiftUI

/// Photos-style parameter bar: label/value are inside the draggable surface.
struct PhotosParameterSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var editing: (Bool)->Void = { _ in }
    var colors:[Color]?=nil
    @Environment(\.isEnabled) private var enabled
    @ViewState private var dragging=false
    private var effectiveRange: ClosedRange<Double> { min(range.lowerBound,value)...max(range.upperBound,value) }
    var body: some View {
        GeometryReader { geometry in
            let fraction=(value-effectiveRange.lowerBound)/max(0.000001,effectiveRange.upperBound-effectiveRange.lowerBound)
            ZStack(alignment:.leading) {
                if let colors { LinearGradient(colors:colors,startPoint:.leading,endPoint:.trailing).opacity(0.42).clipShape(RoundedRectangle(cornerRadius:5)) } else { RoundedRectangle(cornerRadius:5).fill(.white.opacity(0.065)) }
                Rectangle().fill(.white.opacity(dragging ? 0.6:0.28)).frame(width:3).offset(x:max(0,min(geometry.size.width-3,geometry.size.width*fraction)))
                HStack { Text(title);Spacer();Text(String(format:"%.2f",value)).monospacedDigit() }.font(.system(size:12)).padding(.horizontal,9)
            }.contentShape(Rectangle()).gesture(DragGesture(minimumDistance:0).onChanged { event in
                guard enabled else{return};if !dragging{dragging=true;editing(true)}
                value=effectiveRange.lowerBound+min(1,max(0,event.location.x/max(1,geometry.size.width)))*(effectiveRange.upperBound-effectiveRange.lowerBound)
            }.onEnded { _ in if dragging{dragging=false;editing(false)} })
        }.frame(height:27).opacity(enabled ? 1:0.4).focusable(enabled).focusEffectDisabled()
        .onKeyPress(.leftArrow){step(-1);return .handled}.onKeyPress(.rightArrow){step(1);return .handled}
        .accessibilityRepresentation { Slider(value:$value,in:effectiveRange,onEditingChanged:editing).accessibilityLabel(title) }
        .help("左右拖动调整\(title)，方向键精调")
    }
    private func step(_ direction:Double){guard enabled else{return};editing(true);value=min(effectiveRange.upperBound,max(effectiveRange.lowerBound,value+direction*(effectiveRange.upperBound-effectiveRange.lowerBound)/200));editing(false)}
}

struct PhotosSummaryStrip: View {
    @ObservedObject var model:PhotoEditorModel
    let group:AdjustmentSection
    @Binding var value:Double
    let range:ClosedRange<Double>
    @ViewState private var images:[CGImage]=[]
    @ViewState private var dragging=false
    var body:some View {
        GeometryReader { geometry in
            ZStack(alignment:.leading) {
                HStack(spacing:0) { ForEach(Array(images.enumerated()),id:\.offset) { _,image in
                    Image(nsImage:NSImage(cgImage:image,size:.zero)).resizable().aspectRatio(contentMode:.fill).frame(width:geometry.size.width/CGFloat(max(1,images.count)),height:44).clipped()
                } }.frame(maxWidth:.infinity,maxHeight:.infinity).background(.white.opacity(0.07))
                Rectangle().fill(.white).frame(width:2).shadow(color:.black.opacity(0.6),radius:1).offset(x:max(1,min(geometry.size.width-3,geometry.size.width*(value-range.lowerBound)/(range.upperBound-range.lowerBound))))
            }.clipShape(RoundedRectangle(cornerRadius:5)).contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance:0).onChanged { event in
                    if !dragging{dragging=true;model.beginGesture()}
                    value=range.lowerBound+min(1,max(0,event.location.x/max(1,geometry.size.width)))*(range.upperBound-range.lowerBound)
                }.onEnded{_ in if dragging{dragging=false;model.endGesture()} })
        }.frame(height:44).padding(.vertical,4)
        .task(id:model.rendering) { if !model.rendering { images=(try? await model.adjustmentStrip(group)) ?? [] } }
        .accessibilityRepresentation { Slider(value:$value,in:range,onEditingChanged:{if $0{model.beginGesture()}else{model.endGesture()}}).accessibilityLabel(group.rawValue) }
        .help("左右拖动预览条调整\(group.rawValue)")
    }
}
