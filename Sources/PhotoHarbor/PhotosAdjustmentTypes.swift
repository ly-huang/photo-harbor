import Foundation

// The grouping and neutral control values follow the macOS Photos editor.
enum AdjustmentSection: String, Codable, CaseIterable, Sendable {
    case light = "光效", color = "颜色", blackWhite = "黑白", retouch = "修图", redEye = "消除红眼", whiteBalance = "白平衡", curves = "曲线", levels = "色阶", definition = "清晰度", selective = "可选颜色", noise = "噪点消除", sharpen = "锐化", vignette = "晕影", portrait = "人物美化"
}
struct LevelAdjustment: Equatable, Codable, Sendable {
    var black = 0.0, white = 1.0, gamma = 1.0, outputBlack = 0.0, outputWhite = 1.0
    func apply(_ value: Double) -> Double { outputBlack + pow(min(1, max(0, (value - black) / max(0.001, white - black))), 1 / gamma) * (outputWhite - outputBlack) }
}
struct SelectiveColorAdjustment: Equatable, Codable, Sendable { var hue = 0.0, saturation = 0.0, brightness = 0.0, range = 1.0 }
enum CorrectionTool: String, Codable, Sendable { case retouch, redEye, whiteBalance, curveBlack, curveGray, curveWhite, curvePoint, selectiveColor }
struct PhotoCorrection: Equatable, Codable, Sendable { let tool: CorrectionTool; let point: CGPoint; let radius: Double }

extension PhotoAdjustments {
    func cropRatio(imageAspect: CGFloat) -> CGFloat? {
        if crop == "自由裁剪" { return nil }
        if crop == "原比例" { return imageAspect }
        let ratios: [String: CGFloat] = ["1:1": 1, "4:5": 4/5, "5:7": 5/7, "4:3": 4/3, "3:5": 3/5, "3:2": 1.5, "16:9": 16/9, "自定义": customCropRatio]
        guard let value = ratios[crop], value > 0 else { return nil }
        return cropPortrait ? min(value, 1/value) : max(value, 1/value)
    }
    func isChanged(_ section: AdjustmentSection) -> Bool {
        let clean = resetting(section)
        return clean != self
    }
    func resetting(_ section: AdjustmentSection) -> PhotoAdjustments {
        var a = self, d = PhotoAdjustments()
        d.disabledGroups = disabledGroups
        switch section {
        case .light: a.lightAmount=0;a.brilliance=0;a.exposure=0;a.highlights=1;a.shadows=0;a.brightness=0;a.contrast=1;a.blackPoint=0;a.systemAdjustments.removeAll { ["CIExposureAdjust","CIHighlightShadowAdjust"].contains($0.name) }
        case .color: a.colorAmount=0;a.saturation=1;a.vibrance=0;a.colorCast=0;a.systemAdjustments.removeAll { ["CIVibrance","CIColorControls"].contains($0.name) }
        case .blackWhite: a.blackWhite=0;a.blackWhiteIntensity=0.5;a.blackWhiteNeutral=0;a.blackWhiteTone=0;a.blackWhiteGrain=0
        case .retouch: a.corrections.removeAll { $0.tool == .retouch }
        case .redEye: a.corrections.removeAll { $0.tool == .redEye };a.automaticRedEye=false
        case .whiteBalance: a.temperature=0;a.tint=0;a.whiteBalanceSample=nil;a.whiteBalanceMode="色温";a.systemAdjustments.removeAll { ["CITemperatureAndTint","CIWhitePointAdjust"].contains($0.name) }
        case .curves: a.curve=d.curve;a.channelCurves=d.channelCurves;a.extrapolate=false;a.systemAdjustments.removeAll { $0.name == "CIToneCurve" }
        case .levels: a.levels=d.levels
        case .definition: a.definition=0
        case .selective: a.selectiveColors=d.selectiveColors;a.selectiveHues=d.selectiveHues;a.sampledSelectiveRGB=nil
        case .noise: a.noiseReduction=0
        case .sharpen: a.sharpness=0;a.sharpEdges=d.sharpEdges;a.sharpFalloff=d.sharpFalloff;a.systemAdjustments.removeAll { $0.name == "CISharpenLuminance" }
        case .vignette: a.vignette=0;a.vignetteRadius=d.vignetteRadius;a.vignetteSoftness=d.vignetteSoftness
        case .portrait: a.portrait=0
        }
        a.systemAdjustments.removeAll{$0.section==section}
        return a
    }
    var enabledParameters: PhotoAdjustments { disabledGroups.reduce(self) { $0.resetting($1) } }
}

import CoreGraphics

enum PhotoHistogram {
    /// Luminance, red, green, blue; sampled from the actual rendered preview.
    static func channels(_ image:CGImage)->[[Double]] {
        var pixels=[UInt8](repeating:0,count:128*128*4),bins=Array(repeating:[Double](repeating:0,count:256),count:4)
        let drawn=pixels.withUnsafeMutableBytes { memory -> Bool in
            guard let context=CGContext(data:memory.baseAddress,width:128,height:128,bitsPerComponent:8,bytesPerRow:128*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else{return false}
            context.draw(image,in:CGRect(x:0,y:0,width:128,height:128));return true
        }
        guard drawn else{return bins}
        for i in stride(from:0,to:pixels.count,by:4) where pixels[i+3]>0 {
            let r=Int(pixels[i]),g=Int(pixels[i+1]),b=Int(pixels[i+2])
            let redLuma=Double(r)*0.2126, greenLuma=Double(g)*0.7152, blueLuma=Double(b)*0.0722
            let lumaIndex=min(255,Int(redLuma+greenLuma+blueLuma))
            bins[0][lumaIndex] += 1.0
            bins[1][r]+=1;bins[2][g]+=1;bins[3][b]+=1
        }
        return bins.map { values in let peak=max(1,values.max() ?? 1);return values.map{$0/peak} }
    }
    static func values(_ image:CGImage)->[Double]{channels(image)[0]}
}

enum EditorPixelSampler {
    static func rgb(_ image:CGImage,point:CGPoint)->[CGFloat]? {
        let x=min(image.width-1,max(0,Int(point.x*CGFloat(image.width))))
        let y=min(image.height-1,max(0,Int(point.y*CGFloat(image.height))))
        guard let pixel=image.cropping(to:CGRect(x:x,y:y,width:1,height:1)) else{return nil}
        var bytes=[UInt8](repeating:0,count:4)
        let success=bytes.withUnsafeMutableBytes {memory->Bool in
            guard let context=CGContext(data:memory.baseAddress,width:1,height:1,bitsPerComponent:8,bytesPerRow:4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else{return false}
            context.draw(pixel,in:CGRect(x:0,y:0,width:1,height:1));return true
        }
        return success ? bytes.prefix(3).map{CGFloat($0)/255}:nil
    }
}
