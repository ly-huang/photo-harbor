import SwiftUI
import CoreImage

struct ToneCurveControls: View {
    @ObservedObject var model:PhotoEditorModel
    @ViewState private var dragging=false
    @ViewState private var hoveredPicker:CorrectionTool?
    private var channel:Int{model.curveChannel}
    private var points:[CGPoint]{channel==0 ? model.adjustments.curve:model.adjustments.channelCurves[channel-1]}
    private var selected:Int{min(max(0,model.curvePointIndex),points.count-1)}
    private var tint:Color{[Color.white,.red,.green,.blue][channel]}
    private func setPoint(_ i:Int,_ p:CGPoint){if channel==0{model.adjustments.curve[i]=p}else{model.adjustments.channelCurves[channel-1][i]=p};model.adjustments.disabledGroups.remove(.curves)}
    var body:some View {
        VStack(alignment:.leading,spacing:10) {
            HStack {Text("色调曲线").font(.subheadline.weight(.semibold));Spacer();Button("重置当前"){model.change{if channel==0{$0.curve=ChannelCurves.identity;$0.extrapolate=false}else{$0.channelCurves[channel-1]=ChannelCurves.identity}};model.curvePointIndex=2}.font(.caption)}
            Picker("曲线通道",selection:$model.curveChannel){Text("RGB").tag(0);Text("红 R").tag(1);Text("绿 G").tag(2);Text("蓝 B").tag(3)}.pickerStyle(.segmented).labelsHidden()
            HStack(spacing:5) {
                picker(.curveBlack,"黑点","eyedropper",shade:.black)
                picker(.curveGray,"中间调","eyedropper",shade:.gray)
                picker(.curveWhite,"白点","eyedropper",shade:.white)
                Divider().frame(height:18)
                picker(.curvePoint,"取点","scope",shade:.clear)
                Spacer(minLength:0)
                Button {remove(selected)} label:{Image(systemName:"minus.circle")}.disabled(points.count<=2).help("移除当前控制点")
            }.buttonStyle(.borderless)
            if let tool=hoveredPicker ?? model.activeBrush,[.curveBlack,.curveGray,.curveWhite,.curvePoint].contains(tool){Text(pickerHelp(tool)).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)}
            Text(["RGB 整体明暗","红通道 · 红 ↔ 青","绿通道 · 绿 ↔ 品红","蓝通道 · 蓝 ↔ 黄"][channel]).font(.caption.weight(.medium))
            HStack(spacing:6) {
                VStack{Text("亮");Spacer();Text("输出");Spacer();Text("暗")}.font(.system(size:9)).foregroundStyle(.secondary).frame(width:22)
                GeometryReader { geo in
                    let size=CGSize(width:max(1,geo.size.width-12),height:max(1,geo.size.height-12))
                    ZStack {
                        RoundedRectangle(cornerRadius:8).fill(.black.opacity(0.35)).contentShape(Rectangle())
                            .gesture(SpatialTapGesture().onEnded{event in model.insertCurvePoint(CGPoint(x:event.location.x/size.width,y:1-event.location.y/size.height))})
                        HistogramPlot(values:model.histograms[channel],tint:tint).allowsHitTesting(false)
                        Path {p in for i in 1...3 {let x=size.width*CGFloat(i)/4,y=size.height*CGFloat(i)/4;p.move(to:CGPoint(x:x,y:0));p.addLine(to:CGPoint(x:x,y:size.height));p.move(to:CGPoint(x:0,y:y));p.addLine(to:CGPoint(x:size.width,y:y))}}.stroke(.white.opacity(0.13),lineWidth:0.5).allowsHitTesting(false)
                        Path{p in p.move(to:CGPoint(x:0,y:size.height));p.addLine(to:CGPoint(x:size.width,y:0))}.stroke(.white.opacity(0.25),style:StrokeStyle(lineWidth:1,dash:[4,4])).allowsHitTesting(false)
                        Path {p in for i in 0...256 {let x=Double(i)/256,position=CGPoint(x:x*size.width,y:(1-ChannelCurves.value(x,points:points))*size.height);if i==0{p.move(to:position)}else{p.addLine(to:position)}}}.stroke(tint.opacity(0.9),lineWidth:1.3).allowsHitTesting(false)
                        ForEach(points.indices,id:\.self) {i in
                            Circle().fill(selected==i ? Color.accentColor:tint).frame(width:9,height:9).position(x:points[i].x*size.width,y:(1-points[i].y)*size.height)
                                .gesture(DragGesture(minimumDistance:0,coordinateSpace:.named("toneCurve")).onChanged{event in
                                    model.curvePointIndex=i;if !dragging{dragging=true;model.beginGesture()}
                                    let lower=i==0 ? 0:points[i-1].x+0.001,upper=i==points.count-1 ? 1:points[i+1].x-0.001
                                    setPoint(i,CGPoint(x:min(upper,max(lower,event.location.x/size.width)),y:min(1,max(0,1-event.location.y/size.height))))
                                }.onEnded{_ in dragging=false;model.endGesture()})
                                .contextMenu{Button("移除控制点"){remove(i)}.disabled(points.count<=2)}
                                .accessibilityLabel("曲线控制点 \(i+1)")
                        }
                    }.frame(width:size.width,height:size.height).coordinateSpace(name:"toneCurve").padding(6)
                }.frame(height:165)
            }
            LinearGradient(colors:[.black,.white],startPoint:.leading,endPoint:.trailing).frame(height:5).clipShape(Capsule()).padding(.leading,28)
            HStack{Text("输入：暗部");Spacer();Text("中间调");Spacer();Text("高光")}.font(.system(size:9)).foregroundStyle(.secondary).padding(.leading,28)
            Text(String(format:"控制点 %d · 输入 %.0f%% → 输出 %.0f%%",selected+1,points[selected].x*100,points[selected].y*100)).font(.caption).monospacedDigit()
            Text("单击曲线区域添加点；用取点工具选取照片色调；右键控制点可移除，最多 32 点。").font(.caption2).foregroundStyle(.secondary)
            DisclosureGroup("控制点数值") {ForEach(points.indices,id:\.self){i in HStack{Text("\(i+1)").font(.caption2);component(i,axis:0);component(i,axis:1)}}}.font(.caption)
        }
    }
    private func picker(_ tool:CorrectionTool,_ name:String,_ symbol:String,shade:Color)->some View {
        Button {model.activeBrush=model.activeBrush==tool ? nil:tool} label:{HStack(spacing:3){Image(systemName:symbol);if tool != .curvePoint{Circle().fill(shade).overlay(Circle().stroke(.gray,lineWidth:0.5)).frame(width:6,height:6)};Text(name).font(.caption2)}.padding(5).contentShape(Rectangle()).background(model.activeBrush==tool ? .white.opacity(0.16):.clear,in:RoundedRectangle(cornerRadius:5))}
            .accessibilityLabel("曲线\(name)取样").help(pickerHelp(tool)).onHover{hoveredPicker=$0 ? tool:nil}
    }
    private func pickerHelp(_ tool:CorrectionTool)->String {
        switch tool {
        case .curveBlack:return "设置黑点：点击照片中应为最暗的区域，将当前通道的该色调映射到黑色（输出 0%）。"
        case .curveGray:return "设置中间调：点击照片中应为中等明暗的区域，将当前通道的该色调映射到输出 50%。"
        case .curveWhite:return "设置白点：点击照片中应为最亮的区域，将当前通道的该色调映射到白色（输出 100%）。"
        default:return "添加色调控制点：点击照片中的区域，在当前通道曲线上添加对应控制点，再拖动调整明暗。"
        }
    }
    private func remove(_ i:Int){guard points.count>2 else{return};model.change{if channel==0{$0.curve.remove(at:i)}else{$0.channelCurves[channel-1].remove(at:i)}};model.curvePointIndex=max(0,i-1)}
    private func component(_ i:Int,axis:Int)->some View {
        let lower=axis==0 && i>0 ? points[i-1].x+0.001:0,upper=axis==0 && i<points.count-1 ? points[i+1].x-0.001:1
        return VStack(spacing:2){Text(String(format:"%@ %.3f",axis==0 ? "输入":"输出",axis==0 ? points[i].x:points[i].y)).monospacedDigit();GlassSlider(value:Binding(get:{axis==0 ? points[i].x:points[i].y},set:{v in var p=points[i];if axis==0{p.x=v}else{p.y=v};setPoint(i,p)}),range:lower...max(lower,upper),onEditingChanged:{if $0{model.beginGesture()}else{model.endGesture()}})}
    }
}

struct SystemAdjustmentControls: View {
    @ObservedObject var model: PhotoEditorModel
    var section:AdjustmentSection?=nil
    var body: some View {
        ForEach(model.systemControlTemplates.filter{section==nil || $0.section==section}) { group in
            if !group.additional.isEmpty {
                VStack(alignment:.leading,spacing:8) {
                  if group.name != "CIHighlightShadowAdjust"{Text(group.title).font(.caption.weight(.semibold))}
                  VStack(alignment: .leading, spacing: 12) {
                    Divider()
                    if group.name=="CIHighlightShadowAdjust"{Text("局部对比半径仅在光效中的高光或阴影偏离默认值时生效，单独调整半径不会改变照片。").font(.caption2).foregroundStyle(.secondary)}
                    ForEach(group.additional) { p in
                            if p.kind == .boolean {
                                Toggle(p.title, isOn: Binding(get: { model.systemValue(group,p,0) != 0 }, set: { value in model.beginGesture();model.setSystemValue(value ? 1:0,group:group,parameter:p,component:0);model.endGesture() })).font(.caption)
                            } else {
                                ForEach(p.values.indices, id: \.self) { component in
                                    let title = p.title + (p.values.count > 1 ? " · " + (p.kind == .color ? ["红", "绿", "蓝", "透明"][component] : ["X", "Y", "Z", "W"][min(component, 3)]) : "")
                                    VStack(spacing: 5) {
                                        HStack { Text(title); Spacer(); Text(String(format: "%.3f", model.systemValue(group,p,component))).monospacedDigit().foregroundStyle(.secondary) }.font(.caption)
                                        GlassSlider(value: Binding(get: { model.systemValue(group,p,component) }, set: { model.setSystemValue($0,group:group,parameter:p,component:component) }), range: p.lower...max(p.lower + 0.001, p.upper), onEditingChanged: { if $0 { model.beginGesture() } else { model.endGesture() } }).accessibilityLabel(title)
                                    }
                                }
                            }
                    }
                  }
                }
            }
        }
    }
}

struct HistogramPlot:View {
    let values:[Double]
    var tint:Color = .white
    var body:some View {
        GeometryReader { geometry in
            Path { p in
                let width=geometry.size.width/CGFloat(max(1,values.count))
                for (i,value) in values.enumerated() where value>0 {
                    // A square-root display keeps less frequent tones visible beside peaks.
                    let height=max(1,sqrt(value)*geometry.size.height*0.9)
                    p.addRect(CGRect(x:CGFloat(i)*width,y:geometry.size.height-height,width:max(0.8,width),height:height))
                }
            }.fill(tint.opacity(0.35))
        }.accessibilityLabel("当前照片通道直方图").allowsHitTesting(false)
    }
}
