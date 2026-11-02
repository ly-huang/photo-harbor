import CoreImage

struct BuiltinPhotoFilter: Identifiable, Sendable {
    let id: String
    let name: String
    static let all = [BuiltinPhotoFilter(id:"original",name:"原始状态"),BuiltinPhotoFilter(id:"vivid",name:"鲜明"),BuiltinPhotoFilter(id:"vividWarm",name:"鲜暖色"),BuiltinPhotoFilter(id:"vividCool",name:"鲜冷色"),BuiltinPhotoFilter(id:"dramatic",name:"反差色"),BuiltinPhotoFilter(id:"dramaticWarm",name:"反差暖色"),BuiltinPhotoFilter(id:"dramaticCool",name:"反差冷色"),BuiltinPhotoFilter(id:"mono",name:"单色"),BuiltinPhotoFilter(id:"tonal",name:"银色调"),BuiltinPhotoFilter(id:"noir",name:"黑白")]
    static func apply(_ id:String,to input:CIImage)->CIImage {
        switch id {
        case "mono":return input.applyingFilter("CIPhotoEffectMono")
        case "tonal":return input.applyingFilter("CIPhotoEffectTonal")
        case "noir":return input.applyingFilter("CIPhotoEffectNoir")
        case "vivid","vividWarm","vividCool","dramatic","dramaticWarm","dramaticCool":
            let dramatic=id.hasPrefix("dramatic")
            var image=input.applyingFilter("CIColorControls",parameters:[kCIInputSaturationKey:dramatic ? 0.88:1.22,kCIInputContrastKey:dramatic ? 1.30:1.10,kCIInputBrightnessKey:dramatic ? -0.02:0.01])
            if id.hasSuffix("Warm") || id.hasSuffix("Cool") { image=image.applyingFilter("CITemperatureAndTint",parameters:["inputNeutral":CIVector(x:6500,y:0),"inputTargetNeutral":CIVector(x:id.hasSuffix("Warm") ? 7000:6000,y:0)]) }
            return image
        default:return input
        }
    }
}

// Public Core Image approximations of Photos-style adjustment families.
enum PhotosTonePipeline {
    static func blend(_ base:CIImage,_ effect:CIImage,_ amount:Double)->CIImage { base.applyingFilter("CIDissolveTransition",parameters:[kCIInputTargetImageKey:effect,kCIInputTimeKey:min(1,max(0,amount))]).cropped(to:base.extent) }
    static func preColor(_ input:CIImage,_ a:PhotoAdjustments)->CIImage {
        var image=input
        if a.automaticRedEye {
            for filter in input.autoAdjustmentFilters(options:[.enhance:false,.redEye:true,.crop:false,.level:false]) { filter.setValue(image,forKey:kCIInputImageKey);image=filter.outputImage ?? image }
        }
        for mark in a.corrections {
            let center=CGPoint(x:input.extent.minX+mark.point.x*input.extent.width,y:input.extent.minY+(1-mark.point.y)*input.extent.height)
            let radius=max(1,mark.radius*min(input.extent.width,input.extent.height))
            let mask=CIFilter(name:"CIRadialGradient",parameters:["inputCenter":CIVector(cgPoint:center),"inputRadius0":radius*0.6,"inputRadius1":radius,"inputColor0":CIColor.white,"inputColor1":CIColor.black])!.outputImage!.cropped(to:input.extent)
            if mark.tool == .retouch {
                let shift=center.x+radius*3 < input.extent.maxX ? -radius*2.5:radius*2.5
                let source=input.clampedToExtent().transformed(by:CGAffineTransform(translationX:shift,y:0)).cropped(to:input.extent)
                image=source.applyingFilter("CIBlendWithMask",parameters:[kCIInputBackgroundImageKey:image,kCIInputMaskImageKey:mask])
            } else if mark.tool == .redEye {
                let red=image.applyingFilter("CIColorMatrix",parameters:["inputRVector":CIVector(x:8,y:-10.4,z:-10.4,w:0),"inputGVector":CIVector(x:8,y:-10.4,z:-10.4,w:0),"inputBVector":CIVector(x:8,y:-10.4,z:-10.4,w:0)])
                    .applyingFilter("CIColorClamp",parameters:["inputMinComponents":CIVector(x:0,y:0,z:0,w:0),"inputMaxComponents":CIVector(x:1,y:1,z:1,w:1)])
                let combined=red.applyingFilter("CIMultiplyCompositing",parameters:[kCIInputBackgroundImageKey:mask])
                let corrected=image.applyingFilter("CIColorMatrix",parameters:["inputRVector":CIVector(x:0,y:0.5,z:0.5,w:0)])
                image=corrected.applyingFilter("CIBlendWithMask",parameters:[kCIInputBackgroundImageKey:image,kCIInputMaskImageKey:combined])
            }
        }
        return image
    }
    static func advanced(_ input:CIImage,_ a:PhotoAdjustments)->CIImage {
        var image=input
        if a.lightAmount != 0 { image=image.applyingFilter("CIExposureAdjust",parameters:[kCIInputEVKey:a.lightAmount*0.7]) }
        if a.highlights > 1 {
            image=image.applyingFilter("CIToneCurve",parameters:["inputPoint0":CIVector(x:0,y:0),"inputPoint1":CIVector(x:0.25,y:0.25),"inputPoint2":CIVector(x:0.5,y:0.5),"inputPoint3":CIVector(x:0.75,y:0.75+(a.highlights-1)*0.12),"inputPoint4":CIVector(x:1,y:1)])
        }
        if a.brilliance != 0 {
            let effect=image.applyingFilter("CIHighlightShadowAdjust",parameters:["inputHighlightAmount":1-max(0,a.brilliance)*0.35,"inputShadowAmount":a.brilliance*0.4]).applyingFilter("CIColorControls",parameters:[kCIInputContrastKey:1+a.brilliance*0.12,kCIInputBrightnessKey:a.brilliance*0.025])
            image=effect
        }
        if a.blackPoint != 0 {
            let black=a.blackPoint*0.18,scale=1/(1-black)
            image=image.applyingFilter("CIColorMatrix",parameters:["inputRVector":CIVector(x:scale,y:0,z:0,w:0),"inputGVector":CIVector(x:0,y:scale,z:0,w:0),"inputBVector":CIVector(x:0,y:0,z:scale,w:0),"inputBiasVector":CIVector(x:-black*scale,y:-black*scale,z:-black*scale,w:0)])
        }
        if a.colorAmount != 0 { image=image.applyingFilter("CIVibrance",parameters:[kCIInputAmountKey:a.colorAmount*0.5]) }
        if a.colorCast != 0 { image=image.applyingFilter("CIColorMatrix",parameters:["inputBiasVector":CIVector(x:a.colorCast*0.04,y:-a.colorCast*0.025,z:a.colorCast*0.015,w:0)]) }
        if a.tint != 0 { image=image.applyingFilter("CITemperatureAndTint",parameters:["inputNeutral":CIVector(x:6500,y:0),"inputTargetNeutral":CIVector(x:6500,y:a.tint*100)]) }
        if let sample=a.whiteBalanceSample, sample.count==3 { image=image.applyingFilter("CIWhitePointAdjust",parameters:[kCIInputColorKey:CIColor(red:sample[0],green:sample[1],blue:sample[2])]) }
        if a.levels.contains(where:{$0 != LevelAdjustment()}) {
            var table=[Float]();table.reserveCapacity(3072)
            for i in 0..<1024 { let base=a.levels[0].apply(Double(i)/1023);for c in 0..<3 { table.append(Float(a.levels[c+1].apply(base))) } }
            image=image.applyingFilter("CIColorCurves",parameters:["inputCurvesData":table.withUnsafeBytes{Data($0)},"inputCurvesDomain":CIVector(x:0,y:1),"inputColorSpace":CGColorSpace(name:CGColorSpace.sRGB)!])
        }
        if a.selectiveColors.contains(where:{$0 != SelectiveColorAdjustment()}) { image=image.applyingFilter("CIColorCubeWithColorSpace",parameters:["inputCubeDimension":16,"inputCubeData":selectiveCube(a.selectiveColors,hues:a.selectiveHues),"inputColorSpace":CGColorSpace(name:CGColorSpace.sRGB)!]) }
        if a.blackWhite > 0 {
            var effect=image.applyingFilter("CIColorControls",parameters:[kCIInputSaturationKey:0,kCIInputContrastKey:1+(a.blackWhiteIntensity-0.5)*0.8+a.blackWhiteNeutral*0.35])
            if a.blackWhiteTone != 0 { effect=effect.applyingFilter("CIColorMonochrome",parameters:[kCIInputColorKey:CIColor(red:a.blackWhiteTone>0 ? 1:0.8,green:0.9,blue:a.blackWhiteTone>0 ? 0.75:1),kCIInputIntensityKey:abs(a.blackWhiteTone)]) }
            if a.blackWhiteGrain > 0 {
                let noise=grain.transformed(by:CGAffineTransform(scaleX:max(1,image.extent.width/512),y:max(1,image.extent.width/512))).applyingFilter("CIAffineTile").cropped(to:image.extent)
                let textured=noise.applyingFilter("CIOverlayBlendMode",parameters:[kCIInputBackgroundImageKey:effect])
                effect=blend(effect,textured,a.blackWhiteGrain*0.5)
            }
            image=blend(image,effect,a.blackWhite)
        }
        if a.noiseReduction > 0 { image=image.applyingFilter("CINoiseReduction",parameters:["inputNoiseLevel":a.noiseReduction*0.08,"inputSharpness":0.4]) }
        if a.definition > 0 { image=image.applyingFilter("CIUnsharpMask",parameters:[kCIInputRadiusKey:max(1,image.extent.width/100),kCIInputIntensityKey:a.definition*0.8]) }
        if a.vignette != 0 {
            let r=min(image.extent.width,image.extent.height)*(0.15+a.vignetteRadius*0.7),soft=0.05+a.vignetteSoftness*0.9
            let mask=CIFilter(name:"CIRadialGradient",parameters:["inputCenter":CIVector(x:image.extent.midX,y:image.extent.midY),"inputRadius0":r*(1-soft),"inputRadius1":r*(1+soft),"inputColor0":CIColor.white,"inputColor1":CIColor.black])!.outputImage!.cropped(to:image.extent)
            let edge=image.applyingFilter("CIExposureAdjust",parameters:[kCIInputEVKey:-a.vignette*2])
            image=image.applyingFilter("CIBlendWithMask",parameters:[kCIInputBackgroundImageKey:edge,kCIInputMaskImageKey:mask])
        }
        return image.cropped(to:input.extent)
    }
    private static let grain:CIImage = {
        var bytes=[UInt8]();var seed:UInt32=1937
        for _ in 0..<64*64 { seed=1664525 &* seed &+ 1013904223;let n=UInt8((seed>>24)&255);bytes += [n,n,n,255] }
        return CIImage(bitmapData:Data(bytes),bytesPerRow:64*4,size:CGSize(width:64,height:64),format:.RGBA8,colorSpace:CGColorSpace(name:CGColorSpace.sRGB)!)
    }()
    static func selectiveCube(_ values:[SelectiveColorAdjustment],hues:[Double]=(0..<6).map{Double($0)/6})->Data {
        var cube=[Float]();cube.reserveCapacity(16*16*16*4)
        for b in 0..<16 { for g in 0..<16 { for r in 0..<16 {
            let rgb=SIMD3(Double(r)/15,Double(g)/15,Double(b)/15),hsv=toHSV(rgb)
            var hue=hsv.x,saturation=hsv.y,brightness=hsv.z
            for i in 0..<min(values.count,hues.count) {
                let a=values[i],distance=min(abs(hsv.x-hues[i]),1-abs(hsv.x-hues[i])),width=0.04+a.range*0.18
                let weight=distance<width ? (1+cos(distance/width * .pi))/2:0
                hue+=a.hue*weight/6;saturation+=a.saturation*weight*0.5;brightness+=a.brightness*weight*0.3
            }
            let out=toRGB(SIMD3(hue-floor(hue),min(1,max(0,saturation)),min(1,max(0,brightness))))
            cube += [Float(out.x),Float(out.y),Float(out.z),1]
        } } }
        return cube.withUnsafeBytes{Data($0)}
    }
    private static func toHSV(_ v:SIMD3<Double>)->SIMD3<Double> {
        let maxV=max(v.x,v.y,v.z),minV=min(v.x,v.y,v.z),d=maxV-minV
        var h=0.0
        if d>0 { if maxV==v.x { h=(v.y-v.z)/d };if maxV==v.y { h=2+(v.z-v.x)/d };if maxV==v.z { h=4+(v.x-v.y)/d };h=(h/6+1).truncatingRemainder(dividingBy:1) }
        return SIMD3(h,maxV==0 ? 0:d/maxV,maxV)
    }
    private static func toRGB(_ h:SIMD3<Double>)->SIMD3<Double> {
        let c=h.z*h.y,x=c*(1-abs((h.x*6).truncatingRemainder(dividingBy:2)-1)),m=h.z-c
        let v:SIMD3<Double>
        switch Int(h.x*6)%6 { case 0:v=SIMD3(c,x,0);case 1:v=SIMD3(x,c,0);case 2:v=SIMD3(0,c,x);case 3:v=SIMD3(0,x,c);case 4:v=SIMD3(x,0,c);default:v=SIMD3(c,0,x) }
        return v+SIMD3(repeating:m)
    }
}
