import CoreImage

struct SystemParameter: Equatable, Codable, Sendable, Identifiable {
    enum Kind: String, Codable, Sendable { case scalar, boolean, vector, color }
    let id: String
    let title: String
    let kind: Kind
    var values: [Double]
    let lower: Double
    let upper: Double
}
struct SystemAdjustment: Equatable, Codable, Sendable, Identifiable {
    var id: String { name }
    let name: String
    let title: String
    var parameters: [SystemParameter]
    static let names = ["CIFaceBalance":"人脸色彩平衡", "CIVibrance": "自然饱和度", "CIToneCurve": "色调曲线", "CIHighlightShadowAdjust": "高光与阴影", "CIColorControls": "色彩控制", "CIExposureAdjust": "曝光", "CISharpenLuminance": "锐化", "CIColorMatrix": "色彩矩阵", "CIWhitePointAdjust": "白点调整", "CITemperatureAndTint": "色温与色调"]
    static let parameterNames = ["inputAmount": "强度", "inputRadius": "局部对比半径", "inputExtrapolate": "延伸曲线", "inputNeutral": "中性色温 / 色调", "inputTargetNeutral": "目标色温 / 色调", "inputColor": "颜色", "inputRVector": "红色通道", "inputGVector": "绿色通道", "inputBVector": "蓝色通道", "inputAVector": "透明通道", "inputBiasVector": "通道偏移"]
    // These parameters share the ordinary adjustment controls rather than duplicate sliders.
    static let mapped: [String: Set<String>] = ["CIVibrance": ["inputAmount"], "CIToneCurve": ["inputPoint0", "inputPoint1", "inputPoint2", "inputPoint3", "inputPoint4", "inputExtrapolate"], "CIExposureAdjust": ["inputEV"], "CIColorControls": ["inputBrightness", "inputContrast", "inputSaturation"], "CIHighlightShadowAdjust": ["inputHighlightAmount", "inputShadowAmount"], "CISharpenLuminance": ["inputSharpness"]]
    var additional: [SystemParameter] { parameters.filter { !(Self.mapped[name] ?? []).contains($0.id) } }
    var section:AdjustmentSection {
        switch name {
        case "CIFaceBalance":return .portrait
        case "CIHighlightShadowAdjust","CIExposureAdjust":return .light
        case "CITemperatureAndTint","CIWhitePointAdjust":return .whiteBalance
        case "CIToneCurve":return .curves
        case "CISharpenLuminance":return .sharpen
        default:return .color
        }
    }
    var neutralTemplate:SystemAdjustment {
        var result=self
        let defaults=CIFilter(name:name);defaults?.setDefaults()
        let neutral=defaults.flatMap{try? Self.capture($0)}
        for i in result.parameters.indices {
            if !result.parameters[i].id.hasPrefix("inputOrig"),let p=neutral?.parameters.first(where:{$0.id==result.parameters[i].id}),p.values.count==result.parameters[i].values.count{result.parameters[i].values=p.values}
            if name=="CIFaceBalance" && result.parameters[i].id=="inputStrength"{result.parameters[i].values=[0]}
        }
        return result
    }
    static func capture(_ filter: CIFilter) throws -> SystemAdjustment {
        var parameters: [SystemParameter] = []
        for key in filter.inputKeys where key != kCIInputImageKey {
            guard let value = filter.value(forKey: key) else { continue }
            let attr = filter.attributes[key] as? [String: Any] ?? [:]
            let faceNames=["inputOrigI":"原始色度 I","inputOrigQ":"原始色度 Q","inputStrength":"强度","inputWarmth":"暖色倾向"]
            let title = (filter.name=="CIFaceBalance" ? faceNames[key]:nil) ?? parameterNames[key] ?? (attr[kCIAttributeDisplayName] as? String ?? key)
            let kind: SystemParameter.Kind, values: [Double]
            if let number = value as? NSNumber {
                kind = (attr[kCIAttributeType] as? String == kCIAttributeTypeBoolean) ? .boolean : .scalar; values = [number.doubleValue]
            } else if let vector = value as? CIVector {
                kind = .vector; values = (0..<vector.count).map { Double(vector.value(at: $0)) }
            } else if let color = value as? CIColor {
                kind = .color; values = [Double(color.red), Double(color.green), Double(color.blue), Double(color.alpha)]
            } else { throw LibraryError.message("系统增强参数「\(filter.name).\(key)」尚不支持编辑，未应用本次增强。") }
            guard values.allSatisfy(\.isFinite) else { throw LibraryError.message("系统返回了无效的增强参数。") }
            let minValue = (attr[kCIAttributeSliderMin] as? NSNumber)?.doubleValue ?? (attr[kCIAttributeMin] as? NSNumber)?.doubleValue ?? min(-1, values.min() ?? -1)
            let maxValue = (attr[kCIAttributeSliderMax] as? NSNumber)?.doubleValue ?? (attr[kCIAttributeMax] as? NSNumber)?.doubleValue ?? max(1, values.max() ?? 1)
            parameters.append(SystemParameter(id: key, title: title, kind: kind, values: values, lower: min(minValue, values.min() ?? minValue), upper: max(maxValue, values.max() ?? maxValue)))
        }
        return SystemAdjustment(name: filter.name, title: names[filter.name] ?? filter.name, parameters: parameters)
    }
    func makeFilter() -> CIFilter? {
        guard let filter = CIFilter(name: name) else { return nil }
        for p in parameters {
            switch p.kind {
            case .scalar, .boolean: filter.setValue(p.values[0], forKey: p.id)
            case .vector: filter.setValue(CIVector(values: p.values.map { CGFloat($0) }, count: p.values.count), forKey: p.id)
            case .color: filter.setValue(CIColor(red: CGFloat(p.values[0]), green: CGFloat(p.values[1]), blue: CGFloat(p.values[2]), alpha: CGFloat(p.values[3])), forKey: p.id)
            }
        }
        return filter
    }
}
