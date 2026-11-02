import SwiftUI
import AppKit

enum EditorTab:String,CaseIterable { case adjust="调整",filters="滤镜",crop="裁剪" }

struct EditorSidebar:View {
    @ObservedObject var model:PhotoEditorModel
    let tab:EditorTab
    let manageLibrary:()->Void
    let restore:()->Void
    var body:some View {
        VStack(alignment:.leading,spacing:14) {
            HStack { Text(tab.rawValue).font(.system(size:14,weight:.semibold));Spacer();Button { model.undoChange() } label:{Image(systemName:"arrow.uturn.backward")}.disabled(model.undo.isEmpty).help("撤销");Button { model.redoChange() } label:{Image(systemName:"arrow.uturn.forward")}.disabled(model.redo.isEmpty).help("重做") }.buttonStyle(.borderless)
            ScrollView {
                VStack(alignment:.leading,spacing:16) {
                    switch tab {
                    case .adjust: PhotosAdjustPanel(model:model)
                    case .filters: PhotosFiltersPanel(model:model,library:model.library,manageLibrary:manageLibrary)
                    case .crop: PhotosCropPanel(model:model)
                    }
                }.padding(.trailing,14).padding(.bottom,8)
            }.scrollIndicators(.visible)
            Divider()
            HStack { Button("还原最初 JPG",action:restore).disabled(!model.hasBackup);Spacer();if tab != .crop { Button("还原调整") { model.change { $0=PhotoAdjustments() } }.disabled(!model.dirty) } }.font(.caption)
            Text("保存覆盖 JPG；最初备份保留，RAW 不变。").font(.caption2).foregroundStyle(.secondary)
        }.padding(18).modifier(ArrowPointer())
    }
}

private struct PhotosAdjustPanel:View {
    @ObservedObject var model:PhotoEditorModel
    var body:some View {
        Button { Task { await model.beautify() } } label:{Label("一键美化",systemImage:"wand.and.stars").frame(maxWidth:.infinity)}.controlSize(.large)
        Text(model.enhancementInfo).font(.caption2).foregroundStyle(.secondary)
        ForEach(AdjustmentSection.allCases,id:\.self) { group in PhotosAdjustmentGroup(model:model,group:group) }
        Text("按本机照片 App 的分组组织，图像处理使用公开 API；部分效果与照片 App 有差异。").font(.caption2).foregroundStyle(.secondary)
    }
}

private struct PhotosAdjustmentGroup:View {
    @ObservedObject var model:PhotoEditorModel
    let group:AdjustmentSection
    @ViewState private var expanded=false
    private var changed:Bool { model.adjustments.isChanged(group) }
    private var enabled:Bool { !model.adjustments.disabledGroups.contains(group) }
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            HStack(spacing:7) {
                Button { expanded.toggle() } label:{
                    HStack(spacing:7) {
                        Image(systemName:expanded ? "chevron.down":"chevron.right").font(.system(size:10,weight:.semibold)).frame(width:12)
                        groupIcon.frame(width:16)
                        Text(group.rawValue).font(.system(size:13,weight:.semibold))
                        Spacer(minLength:0)
                    }.frame(maxWidth:.infinity,minHeight:24,alignment:.leading).contentShape(Rectangle())
                }.buttonStyle(.plain).help(expanded ? "收起\(group.rawValue)":"展开\(group.rawValue)")
                if expanded || changed {
                Button { model.change { $0=$0.resetting(group);$0.disabledGroups.remove(group) }; if [.retouch,.redEye].contains(group) { model.activeBrush=nil } } label:{Image(systemName:"arrow.uturn.backward").font(.system(size:12))}.disabled(!changed).help("复原\(group.rawValue)")
                if ![.retouch,.selective,.portrait].contains(group) {
                    Button("自动") { Task { await model.autoAdjust(group) };expanded=true }
                        .font(.system(size:10)).padding(.horizontal,6).padding(.vertical,1)
                        .overlay(Capsule().stroke(.secondary.opacity(0.7),lineWidth:0.7))
                }
                if group != .retouch {
                    Button {
                        if !changed { Task { await model.autoAdjust(group) } }
                        else { model.change { if enabled { $0.disabledGroups.insert(group) } else { $0.disabledGroups.remove(group) } } }
                    } label:{Circle().strokeBorder(changed && enabled ? Color.accentColor:Color.secondary,lineWidth:1.2).background(Circle().fill(changed && enabled ? Color.accentColor.opacity(0.2):.clear)).frame(width:13,height:13)}
                    .accessibilityLabel("\(group.rawValue)调整开关").accessibilityValue(changed && enabled ? "开启":"关闭").help("开关这组调整，保留参数")
                }
                }
            }.buttonStyle(.borderless).padding(.vertical,2)
            if expanded {
                controls.padding(.leading,19)
                SystemAdjustmentControls(model:model,section:group).padding(.leading,19)
            }
            Divider()
        }.onAppear { if group == .light || group == .color { expanded=true } }
    }
    @ViewBuilder private var groupIcon: some View {
        if group == .color {
            Circle().strokeBorder(AngularGradient(colors:[.red,.yellow,.green,.cyan,.blue,.purple,.red],center:.center),lineWidth:1.5).frame(width:14,height:14)
        } else if group == .vignette {
            Circle().fill(RadialGradient(colors:[.clear,.secondary],center:.center,startRadius:1,endRadius:7))
                .overlay(Circle().stroke(.secondary,lineWidth:0.7)).frame(width:14,height:14)
        } else {
            Image(systemName:iconName).font(.system(size:14)).foregroundStyle(.secondary)
        }
    }
    private var iconName:String {
        switch group {
        case .light:return "sun.max"
        case .color:return "circle"
        case .blackWhite:return "circle.lefthalf.filled"
        case .retouch:return "bandage"
        case .redEye:return "eye.slash"
        case .whiteBalance:return "square.fill.on.square.fill"
        case .curves:return "chart.xyaxis.line"
        case .levels:return "slider.vertical.3"
        case .definition:return "circle.dotted.circle"
        case .selective:return "eyedropper"
        case .noise:return "circle.dotted"
        case .sharpen:return "triangle"
        case .vignette:return "circle"
        case .portrait:return "person.crop.circle"
        }
    }
    private func summary(_ key:WritableKeyPath<PhotoAdjustments,Double>,range:ClosedRange<Double>)->some View {
        PhotosSummaryStrip(model:model,group:group,value:Binding(get:{model.adjustments[keyPath:key]},set:{model.adjustments[keyPath:key]=$0;model.adjustments.disabledGroups.remove(group);if group == .blackWhite { model.adjustments.blackWhite=1 }}),range:range)
    }
    @ViewBuilder private var controls:some View {
        switch group {
        case .light: light
        case .color: color
        case .blackWhite: blackWhite
        case .retouch: brush(.retouch)
        case .redEye: brush(.redEye)
        case .whiteBalance: whiteBalance
        case .curves: ToneCurveControls(model:model)
        case .levels: LevelsControls(model:model)
        case .definition: slider("数量",\.definition,0...1)
        case .selective: SelectiveControls(model:model)
        case .noise: slider("数量",\.noiseReduction,0...1)
        case .sharpen: slider("强度",\.sharpness,0...1);slider("边缘",\.sharpEdges,0...1);slider("衰减",\.sharpFalloff,0...1)
        case .vignette: slider("强度",\.vignette,-1...1);slider("半径",\.vignetteRadius,0...1);slider("柔和度",\.vignetteSoftness,0...1)
        case .portrait:
            Text(model.faces>0 ? "检测到 \(model.faces) 个人脸":"未检测到人脸").font(.caption2).foregroundStyle(.secondary)
            slider("自然柔肤",\.portrait,0...1).disabled(model.faces==0)
        }
    }
    private var light:some View { VStack(spacing:12) {
        summary(\.lightAmount,range:-1...1)
        DisclosureGroup("选项") { VStack(spacing:12) { slider("鲜明度",\.brilliance,-1...1);slider("曝光",\.exposure,-2...2);slider("高光",\.highlights,-1...1,offset:1);slider("阴影",\.shadows,-1...1);slider("亮度",\.brightness,-1...1);slider("对比度",\.contrast,-0.5...0.5,offset:1);slider("黑点",\.blackPoint,-1...1) }.padding(.top,8) }.font(.caption)
    } }
    private var color:some View { VStack(spacing:12) { summary(\.colorAmount,range:-1...1);DisclosureGroup("选项") { VStack(spacing:12) { slider("饱和度",\.saturation,-1...1,offset:1);slider("自然饱和度",\.vibrance,-1...1);slider("色偏",\.colorCast,-1...1) }.padding(.top,8) }.font(.caption) } }
    private var blackWhite:some View { VStack(spacing:12) { summary(\.blackWhiteIntensity,range:0...1);DisclosureGroup("选项") { VStack(spacing:12) { slider("强度",\.blackWhiteIntensity,0...1);slider("中性",\.blackWhiteNeutral,-1...1);slider("色调",\.blackWhiteTone,-1...1);slider("颗粒",\.blackWhiteGrain,0...1) }.padding(.top,8) }.font(.caption) } }
    private var whiteBalance:some View { VStack(alignment:.leading,spacing:12) {
        Picker("白平衡",selection:Binding(get:{model.adjustments.whiteBalanceMode},set:{ value in model.change{$0.whiteBalanceMode=value} })) { Text("中性灰色").tag("中性灰色");Text("肤色").tag("肤色");Text("色温").tag("色温") }.labelsHidden()
        Button { model.activeBrush = model.activeBrush == .whiteBalance ? nil:.whiteBalance } label:{Label(model.adjustments.whiteBalanceMode == "肤色" ? "在照片中选取肤色":"在照片中选取中性颜色",systemImage:"eyedropper")}.font(.caption)
        slider("色温",\.temperature,-1...1);slider("色调",\.tint,-1...1)
    } }
    private func brush(_ tool:CorrectionTool)->some View {
        HStack(spacing:8) {
            Button { model.activeBrush = model.activeBrush == tool ? nil:tool } label:{Image(systemName:"paintbrush.pointed").frame(width:20,height:22)}
                .buttonStyle(.borderless).padding(2).background(model.activeBrush==tool ? .white.opacity(0.14):.clear,in:RoundedRectangle(cornerRadius:5))
                .overlay(RoundedRectangle(cornerRadius:5).stroke(.secondary.opacity(0.5),lineWidth:0.7)).help(tool == .retouch ? "修图画笔：单击或涂抹瑕疵":"红眼画笔：单击红眼区域")
            ValueSlider(title:"大小",value:$model.brushSize,range:0.005...0.12,editing:{_ in})
        }
    }
    private func slider(_ title:String,_ key:WritableKeyPath<PhotoAdjustments,Double>,_ range:ClosedRange<Double>,offset:Double=0)->some View {
        PhotosParameterSlider(title:title,value:Binding(get:{model.adjustments[keyPath:key]-offset},set:{model.adjustments[keyPath:key]=$0+offset;model.adjustments.disabledGroups.remove(group)}),range:range,editing:{if $0{model.beginGesture()}else{model.endGesture()}})
    }
}

struct ValueSlider:View {
    let title:String
    @Binding var value:Double
    let range:ClosedRange<Double>
    let editing:(Bool)->Void
    var body:some View { PhotosParameterSlider(title:title,value:$value,range:range,editing:editing) }
}

private struct LevelsControls:View {
    @ObservedObject var model:PhotoEditorModel
    @ViewState private var channel=0
    var body:some View { VStack(spacing:8) {
        Picker("通道",selection:$channel) { Text("RGB").tag(0);Text("红 R").tag(1);Text("绿 G").tag(2);Text("蓝 B").tag(3) }.labelsHidden()
        HistogramPlot(values:model.histograms[channel],tint:[Color.white,.red,.green,.blue][channel]).frame(height:70)
        level("黑点",\.black,0...max(0.001,model.adjustments.levels[channel].white-0.001))
        level("中间调",\.gamma,0.1...3)
        level("白点",\.white,min(0.999,model.adjustments.levels[channel].black+0.001)...1)
        DisclosureGroup("输出色阶") { VStack(spacing:8) { level("输出黑点",\.outputBlack,0...0.99);level("输出白点",\.outputWhite,0.01...1) } }.font(.caption)
    } }
    private func level(_ title:String,_ key:WritableKeyPath<LevelAdjustment,Double>,_ range:ClosedRange<Double>)->some View {
        ValueSlider(title:title,value:Binding(get:{model.adjustments.levels[channel][keyPath:key]},set:{model.adjustments.levels[channel][keyPath:key]=$0;model.adjustments.disabledGroups.remove(.levels)}),range:range,editing:{if $0{model.beginGesture()}else{model.endGesture()}})
    }
}
private struct SelectiveControls:View {
    @ObservedObject var model:PhotoEditorModel
    private var selected:Int{min(model.selectiveIndex,model.adjustments.selectiveColors.count-1)}
    private var hue:Double{model.adjustments.selectiveHues[selected]}
    var body:some View {VStack(spacing:8){
        HStack(spacing:8) {
            Button {model.activeBrush=model.activeBrush == .selectiveColor ? nil:.selectiveColor} label:{Image(systemName:"eyedropper").padding(4).background(model.activeBrush == .selectiveColor ? .white.opacity(0.15):.clear,in:RoundedRectangle(cornerRadius:4))}.buttonStyle(.borderless).help("在照片中选取要调整的颜色").accessibilityLabel("可选颜色取色")
            ForEach(0..<6,id:\.self){i in Button {model.selectiveIndex=i} label:{Circle().fill(Color(hue:model.adjustments.selectiveHues[i],saturation:1,brightness:1)).frame(width:15,height:15).overlay(Circle().stroke(.white,lineWidth:selected==i ? 1.5:0).padding(-2))}.buttonStyle(.plain).accessibilityLabel(["红","黄","绿","青","蓝","品红"][i])}
        }
        if let rgb=model.adjustments.sampledSelectiveRGB,rgb.count==3,model.adjustments.selectiveColors.count>6{
            Button{model.selectiveIndex=6}label:{HStack{Circle().fill(Color(red:rgb[0],green:rgb[1],blue:rgb[2])).frame(width:16,height:16);Text("照片取样颜色");Spacer();if selected==6{Image(systemName:"checkmark")}}}.buttonStyle(.borderless)
        }
        item("色调",\.hue,-1...1,colors:[color(hue-1/6),color(hue),color(hue+1/6)])
        item("饱和度",\.saturation,-1...1,colors:[.gray,color(hue)])
        item("亮度",\.brightness,-1...1,colors:[.black,color(hue),.white])
        item("范围",\.range,0...1,colors:[Color.gray.opacity(0.35),color(hue)])
    }}
    private func color(_ h:Double)->Color{Color(hue:h-floor(h),saturation:1,brightness:1)}
    private func item(_ title:String,_ key:WritableKeyPath<SelectiveColorAdjustment,Double>,_ range:ClosedRange<Double>,colors:[Color])->some View{
        PhotosParameterSlider(title:title,value:Binding(get:{model.adjustments.selectiveColors[selected][keyPath:key]},set:{model.adjustments.selectiveColors[selected][keyPath:key]=$0;model.adjustments.disabledGroups.remove(.selective)}),range:range,editing:{if $0{model.beginGesture()}else{model.endGesture()}},colors:colors)
    }
}

private struct PhotosFiltersPanel:View {
    @ObservedObject var model:PhotoEditorModel
    @ObservedObject var library:LUTLibrary
    let manageLibrary:()->Void
    @ViewState private var showFilters=false
    @ViewState private var showLUT=false
    var body:some View {
        VStack(alignment:.leading,spacing:5) {
            ForEach(BuiltinPhotoFilter.all) { filter in
                Button { model.change{$0.builtinFilter=filter.id;$0.presetID=""} } label:{ HStack(spacing:12) {
                    if let image=model.filterPreviews[filter.id] { Image(nsImage:NSImage(cgImage:image,size:.zero)).resizable().aspectRatio(contentMode:.fill).frame(width:44,height:44).clipped().clipShape(RoundedRectangle(cornerRadius:5)) } else { RoundedRectangle(cornerRadius:5).fill(.white.opacity(0.06)).frame(width:44,height:44) }
                    Text(filter.name).font(.system(size:13));Spacer()
                }.frame(maxWidth:.infinity,alignment:.leading).padding(4).contentShape(Rectangle()).background(model.adjustments.builtinFilter==filter.id && model.adjustments.presetID.isEmpty ? .white.opacity(0.12):.clear,in:RoundedRectangle(cornerRadius:7)) }.buttonStyle(.plain)
            }
            if model.adjustments.builtinFilter != "original" || !model.adjustments.presetID.isEmpty { ValueSlider(title:"强度",value:Binding(get:{model.adjustments.filterAmount},set:{model.adjustments.filterAmount=$0}),range:0...1,editing:gesture).padding(.vertical,8) }
            Text("鲜明 / 反差系列为相册风格近似；黑白系列使用系统公开滤镜。").font(.caption2).foregroundStyle(.secondary).padding(.top,6)
            Divider().padding(.vertical,8)
            HStack {
                Text("我的滤镜与 LUT").font(.subheadline.weight(.semibold));Spacer()
                Button(action:manageLibrary) { Label("管理…",systemImage:"folder") }.font(.caption).help("分别导入和管理 XMP 滤镜或 CUBE LUT")
            }
            HStack(spacing:8) {
                libraryButton(.filter) { showLUT=false;showFilters.toggle() }
                    .popover(isPresented:$showFilters,arrowEdge:.leading) {
                        FilterChoicePopover(model:model,library:library,kind:.filter,manage:{showFilters=false;manageLibrary()})
                    }
                libraryButton(.lut) { showFilters=false;showLUT.toggle() }
                    .popover(isPresented:$showLUT,arrowEdge:.leading) {
                        FilterChoicePopover(model:model,library:library,kind:.lut,manage:{showLUT=false;manageLibrary()})
                    }
            }.padding(.vertical,4)
            if !model.adjustments.lutID.isEmpty { ValueSlider(title:"LUT 强度",value:Binding(get:{model.adjustments.lutAmount},set:{model.adjustments.lutAmount=$0}),range:0...1,editing:gesture) }
        }.task { await model.loadFilterPreviews() }.onChange(of:model.rendering) { _, rendering in if !rendering { Task { await model.loadFilterPreviews() } } }
    }
    private func libraryButton(_ kind:FilterLibraryKind,action:@escaping ()->Void)->some View {
        let selected=kind == .filter ? library.photoFilters.first{$0.id==model.adjustments.presetID}?.name:library.entries.first{$0.id==model.adjustments.lutID}?.name
        return Button(action:action) {
            VStack(alignment:.leading,spacing:6) {
                HStack { Label(kind.rawValue,systemImage:kind == .filter ? "slider.horizontal.3":"cube.transparent");Spacer(minLength:2);Image(systemName:"chevron.down").font(.system(size:8,weight:.semibold)) }.font(.system(size:12,weight:.medium))
                Text(selected ?? "不套用").font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }.frame(maxWidth:.infinity,alignment:.leading).padding(10).contentShape(Rectangle()).modifier(PhotoGlass(radius:9))
        }.buttonStyle(.plain).help("选择\(kind.rawValue)，在气泡内预览和搜索")
    }
    private func gesture(_ active:Bool){if active{model.beginGesture()}else{model.endGesture()}}
}

private struct PhotosCropPanel:View {
    @ObservedObject var model:PhotoEditorModel
    @ViewState private var width=16.0
    @ViewState private var height=9.0
    private let aspects=["原比例","自由裁剪","1:1","16:9","4:5","5:7","4:3","3:5","3:2","自定义"]
    var body:some View {
        VStack(alignment:.leading,spacing:14) {
            HStack { Button { model.rotateQuarter(-1) } label:{Image(systemName:"rotate.left")}.help("向左旋转 90°");Button { model.rotateQuarter(1) } label:{Image(systemName:"rotate.right")}.help("向右旋转 90°");Spacer();Menu { Button("水平翻转"){model.change{$0.flipHorizontal.toggle()}};Button("垂直翻转"){model.change{$0.flipVertical.toggle()}} } label:{Label("翻转",systemImage:"arrow.left.and.right.righttriangle.left.righttriangle.right")} }.font(.caption)
            geometryRuler("校正",key:\.freeRotation,scale:1,unit:"°")
            geometryRuler("垂直",key:\.perspectiveVertical,scale:45)
            geometryRuler("水平",key:\.perspectiveHorizontal,scale:45)
            Divider();Text("宽高比").font(.system(size:13,weight:.semibold))
            ForEach(aspects,id:\.self) { aspect in
                Button { model.setCropRatio(aspect) } label:{HStack { Text(aspect=="1:1" ? "正方形":(aspect=="原比例" ? "原始宽高比":(aspect=="自由裁剪" ? "自由格式":aspect)));Spacer();if model.adjustments.crop==aspect{Image(systemName:"checkmark").font(.caption)} }.frame(maxWidth:.infinity,alignment:.leading).padding(.horizontal,8).padding(.vertical,6).contentShape(Rectangle()).background(model.adjustments.crop==aspect ? .white.opacity(0.10):.clear,in:RoundedRectangle(cornerRadius:5))}.buttonStyle(.plain).font(.system(size:12))
            }
            if model.adjustments.crop=="自定义" { HStack { TextField("宽",value:$width,format:.number);Text(":");TextField("高",value:$height,format:.number) }.textFieldStyle(.roundedBorder).onChange(of:width){_,_ in updateRatio()}.onChange(of:height){_,_ in updateRatio()} }
            Picker("方向",selection:Binding(get:{model.adjustments.cropPortrait},set:{ v in model.change{$0.cropPortrait=v};model.setCropRatio(model.adjustments.crop) })) { Text("横排").tag(false);Text("竖排").tag(true) }.pickerStyle(.segmented)
            HStack { Button("自动") { Task{await model.recommendCrop()} };Spacer();Button("还原"){model.change{$0.rotation=0;$0.freeRotation=0;$0.flipHorizontal=false;$0.flipVertical=false;$0.perspectiveVertical=0;$0.perspectiveHorizontal=0;$0.cropRect=EditorGeometry.unit;$0.crop="原比例"};model.beginCrop()} }
            Text("拖动四角或边缘裁剪，框内移动。").font(.caption2).foregroundStyle(.secondary)
        }
    }
    private func geometryRuler(_ title:String,key:WritableKeyPath<PhotoAdjustments,Double>,scale:Double,unit:String="")->some View {
        VStack(spacing:8) {
            HStack { Text(title).font(.system(size:13,weight:.semibold));Spacer();Text(String(format:"%.1f",model.adjustments[keyPath:key]*scale)+unit).monospacedDigit().font(.caption) }
            RotationRuler(angle:Binding(get:{model.adjustments[keyPath:key]*scale},set:{model.adjustments[keyPath:key]=$0/scale}),editing:gesture,title:title).frame(height:42).padding(.horizontal,8)
        }
    }
    private func gesture(_ active:Bool){if active{model.beginGesture()}else{model.endGesture()}}
    private func updateRatio(){guard width.isFinite,height.isFinite,width>0,height>0,width/height>=0.1,width/height<=10 else{return};model.change{$0.customCropRatio=width/height};model.setCropRatio("自定义")}
}

private struct ImportedFilterRow: View {
    @ObservedObject var model: PhotoEditorModel
    var lut: LUTEntry? = nil
    var preset: ImportedPhotoFilter? = nil
    @ViewState private var image: CGImage?
    @ViewState private var error: String?
    private var selected: Bool { lut.map{model.adjustments.lutID==$0.id} ?? (model.adjustments.presetID==preset?.id) }
    private var name: String { lut?.name ?? preset?.name ?? "" }
    var body: some View {
        VStack(alignment:.leading,spacing:6) {
            Button {
                model.change { if let lut { $0.lutID=lut.id } else if let preset { $0.presetID=preset.id;$0.builtinFilter="original" } }
            } label: {
                HStack(spacing:12) {
                    Group {
                        if let image { Image(nsImage:NSImage(cgImage:image,size:.zero)).resizable().aspectRatio(contentMode:.fill) }
                        else { RoundedRectangle(cornerRadius:5).fill(.white.opacity(0.06)).overlay(Image(systemName:error==nil ? "photo":"exclamationmark.triangle").foregroundStyle(.secondary)) }
                    }.frame(width:44,height:44).clipped().clipShape(RoundedRectangle(cornerRadius:5))
                    Text(name).font(.system(size:13)).lineLimit(2).multilineTextAlignment(.leading);Spacer(minLength:0)
                    if selected { Image(systemName:"checkmark").font(.caption) }
                }.frame(maxWidth:.infinity,alignment:.leading).padding(4).contentShape(Rectangle()).background(selected ? .white.opacity(0.12):.clear,in:RoundedRectangle(cornerRadius:7))
            }.buttonStyle(.plain).help(error ?? name)
            if selected,let preset,!preset.warnings.isEmpty {
                DisclosureGroup("兼容性说明") { ForEach(preset.warnings,id:\.self){Text($0).font(.caption2).foregroundStyle(.secondary)} }.font(.caption).padding(.horizontal,6)
            }
        }.task(id:model.rendering) {
            guard !model.rendering else{return}
            do { image=try await model.libraryPreview(lut:lut,preset:preset);error=nil } catch { if !Task.isCancelled{self.error=error.localizedDescription} }
        }
    }
}

private struct FilterChoicePopover:View {
    @ObservedObject var model:PhotoEditorModel
    @ObservedObject var library:LUTLibrary
    let kind:FilterLibraryKind
    let manage:()->Void
    @ViewState private var search=""
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            HStack { Text(kind == .filter ? "我的滤镜":"LUT 库").font(.headline);Spacer();Text("\(kind == .filter ? library.photoFilters.count:library.entries.count)").font(.caption).foregroundStyle(.secondary) }
            TextField(kind == .filter ? "搜索滤镜":"搜索 LUT",text:$search).textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVStack(spacing:5) {
                    Button { model.change { if kind == .filter{$0.presetID=""}else{$0.lutID=""} } } label:{HStack{Text("不套用");Spacer()}.padding(8).frame(maxWidth:.infinity,alignment:.leading).contentShape(Rectangle())}.buttonStyle(.plain)
                    if kind == .filter {
                        ForEach(library.photoFilters.filter{search.isEmpty || $0.name.localizedStandardContains(search)}) { ImportedFilterRow(model:model,preset:$0) }
                    } else {
                        ForEach(library.entries.filter{search.isEmpty || $0.name.localizedStandardContains(search)}) { ImportedFilterRow(model:model,lut:$0) }
                    }
                    if kind == .filter ? library.photoFilters.isEmpty:library.entries.isEmpty { Text("库中暂无内容，点击下方管理导入。").font(.caption).foregroundStyle(.secondary).padding(.vertical,20) }
                }.padding(.trailing,10)
            }.frame(height:300)
            Divider()
            Button { library.selectedKind=kind;manage() } label:{Label("管理\(kind.rawValue)…",systemImage:"folder")}.font(.caption)
        }.padding(16).frame(width:300).background(.ultraThinMaterial).preferredColorScheme(.dark)
    }
}
