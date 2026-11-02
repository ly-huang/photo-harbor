import SwiftUI
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import Vision

struct PhotoAdjustments: Equatable, Codable, Sendable {
    var exposure = 0.0
    var contrast = 1.0
    var saturation = 1.0
    var temperature = 0.0
    var highlights = 1.0
    var shadows = 0.0
    var sharpness = 0.0
    var brightness = 0.0
    var vibrance = 0.0
    var curve = [CGPoint(x: 0, y: 0), CGPoint(x: 0.25, y: 0.25), CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.75, y: 0.75), CGPoint(x: 1, y: 1)]
    var channelCurves = Array(repeating: ChannelCurves.identity, count: 3)
    var extrapolate = false
    var systemAdjustments: [SystemAdjustment] = []
    var disabledGroups: Set<AdjustmentSection> = []
    var lightAmount = 0.0
    var brilliance = 0.0
    var blackPoint = 0.0
    var colorAmount = 0.0
    var colorCast = 0.0
    var blackWhite = 0.0
    var blackWhiteIntensity = 0.5
    var blackWhiteNeutral = 0.0
    var blackWhiteTone = 0.0
    var blackWhiteGrain = 0.0
    var tint = 0.0
    var whiteBalanceMode = "色温"
    var whiteBalanceSample: [Double]? = nil
    var levels = Array(repeating: LevelAdjustment(), count: 4)
    var definition = 0.0
    var selectiveHues = (0..<6).map{Double($0)/6}
    var selectiveColors = Array(repeating: SelectiveColorAdjustment(), count: 6)
    var sampledSelectiveRGB: [Double]?
    var noiseReduction = 0.0
    var sharpEdges = 0.22
    var sharpFalloff = 0.69
    var vignette = 0.0
    var vignetteRadius = 0.5
    var vignetteSoftness = 0.5
    var corrections: [PhotoCorrection] = []
    var automaticRedEye = false
    var builtinFilter = "original"
    var filterAmount = 1.0
    var presetID = ""
    var flipHorizontal = false
    var flipVertical = false
    var perspectiveVertical = 0.0
    var perspectiveHorizontal = 0.0
    var cropPortrait = false
    var customCropRatio = 1.0
    var portrait = 0.0
    var rotation = 0
    var freeRotation = 0.0
    var crop = "原比例"
    var cropRect: CGRect? = nil
    var lutID = ""
    var lutAmount = 1.0
}

struct EditorInput: Sendable {
    let image: CGImage
    let snapshot: EditSnapshot
    let hasBackup: Bool
    let faces: Int
}

actor PhotoEditEngine {
    private let context: CIContext
    init(softwareRendering: Bool = false) {
        context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, .outputColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, .useSoftwareRenderer: softwareRendering])
    }
    private var sourceURL: URL?
    private var expected: EditSnapshot?
    private var previewInput: CIImage?
    private var faces: [CGRect] = []
    private var referenceKey: PhotoAdjustments?
    private var referenceCache: CGImage?
    private var presetCache: [String:PhotoAdjustments] = [:]
    private var thumbnailsKey: PhotoAdjustments?
    private var thumbnailsCache: [String:CGImage] = [:]
    private var cubeCache: [String: CubeLUT] = [:]
    func open(_ url: URL) throws -> EditorInput {
        let snapshot = try EditPersistence.snapshot(url)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetType(source) as String? == "public.jpeg",
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 1800] as CFDictionary) else { throw LibraryError.message("无法解码 JPG。") }
        let input = CIImage(cgImage: image)
        if let detector = CIDetector(ofType: CIDetectorTypeFace, context: context, options: [CIDetectorAccuracy: CIDetectorAccuracyLow]) {
            faces = detector.features(in: input).map { CGRect(x: $0.bounds.minX / input.extent.width, y: $0.bounds.minY / input.extent.height, width: $0.bounds.width / input.extent.width, height: $0.bounds.height / input.extent.height) }
        } else { faces = [] }
        guard try EditPersistence.snapshot(url) == snapshot else { throw LibraryError.message("照片读取期间已变化。") }
        sourceURL = url; expected = snapshot; previewInput = input; referenceKey = nil; referenceCache = nil; thumbnailsKey = nil; thumbnailsCache = [:]; importedThumbnailKey=nil; importedThumbnailCache.removeAll();stripCache.removeAll()
        let backup = try EditPersistence.record(url, current: snapshot) != nil
        return EditorInput(image: image, snapshot: snapshot, hasBackup: backup, faces: faces.count)
    }
    private func cube(_ entry: LUTEntry?, directory: URL) throws -> CubeLUT? {
        guard let entry else { return nil }
        if let cached = cubeCache[entry.id] { return cached }
        let parsed = try LUTStorage.load(entry, in: directory)
        if cubeCache.count >= 4 { cubeCache.removeAll() }
        cubeCache[entry.id] = parsed; return parsed
    }
    func preview(_ adjustments: PhotoAdjustments, lut: LUTEntry?, directory: URL, preset: ImportedPhotoFilter? = nil) throws -> CGImage {
        guard let input = previewInput else { throw LibraryError.message("照片尚未加载。") }
        let output = process(input, adjustments: adjustments, lut: try cube(lut, directory: directory), preset: try imported(preset,directory:directory))
        guard let image = context.createCGImage(output, from: output.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) else { throw LibraryError.message("无法渲染编辑预览。") }
        return image
    }
    func save(_ adjustments: PhotoAdjustments, lut: LUTEntry?, directory: URL, preset: ImportedPhotoFilter? = nil) throws {
        guard let url = sourceURL, let expected else { throw LibraryError.message("照片尚未加载。") }
        guard try EditPersistence.snapshot(url) == expected else { throw LibraryError.message("照片已在其他程序修改，请重新打开编辑。") }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw LibraryError.message("无法读取完整 JPG。") }
        var properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] ?? [:]
        let orientation = (properties[kCGImagePropertyOrientation as String] as? NSNumber)?.int32Value ?? 1
        let input = CIImage(cgImage: image).oriented(forExifOrientation: orientation)
        let colorCube = try lut.map { try LUTStorage.load($0, in: directory) }
        let recipe = try preset.map { try PhotoFilterStorage.load($0,in:directory.deletingLastPathComponent().appendingPathComponent("Filters")) }
        let output = process(input, adjustments: adjustments, lut: colorCube, preset: recipe)
        guard let rendered = context.createCGImage(output, from: output.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) else { throw LibraryError.message("无法渲染完整 JPG。") }
        properties[kCGImagePropertyOrientation as String] = 1
        properties[kCGImagePropertyPixelWidth as String] = rendered.width
        properties[kCGImagePropertyPixelHeight as String] = rendered.height
        properties[kCGImageDestinationLossyCompressionQuality as String] = 0.96
        var exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        exif[kCGImagePropertyExifPixelXDimension as String] = rendered.width; exif[kCGImagePropertyExifPixelYDimension as String] = rendered.height
        properties[kCGImagePropertyExifDictionary as String] = exif
        var tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        tiff[kCGImagePropertyTIFFOrientation as String] = 1; properties[kCGImagePropertyTIFFDictionary as String] = tiff
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { throw LibraryError.message("无法创建 JPG 输出。") }
        CGImageDestinationAddImage(destination, rendered, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw LibraryError.message("无法编码 JPG。") }
        self.expected = try EditPersistence.save(data as Data, to: url, expected: expected)
    }
    func restore() throws {
        guard let url = sourceURL, let expected else { throw LibraryError.message("照片尚未加载。") }
        self.expected = try EditPersistence.restore(url, expected: expected)
    }
    func reference(_ a: PhotoAdjustments) throws -> CGImage {
        guard let input = previewInput else { throw LibraryError.message("照片尚未加载。") }
        var geometry = PhotoAdjustments(); geometry.rotation = a.rotation; geometry.freeRotation = a.freeRotation; geometry.crop = a.crop; geometry.cropRect = a.cropRect; geometry.flipHorizontal=a.flipHorizontal;geometry.flipVertical=a.flipVertical;geometry.perspectiveVertical=a.perspectiveVertical;geometry.perspectiveHorizontal=a.perspectiveHorizontal;geometry.cropPortrait=a.cropPortrait;geometry.customCropRatio=a.customCropRatio
        if referenceKey == geometry, let referenceCache { return referenceCache }
        let output = process(input, adjustments: geometry, lut: nil)
        guard let image = context.createCGImage(output, from: output.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) else { throw LibraryError.message("无法渲染编辑前预览。") }
        referenceKey = geometry; referenceCache = image
        return image
    }
    func enhancement() throws -> PhotoAdjustments {
        guard let input = previewInput else { throw LibraryError.message("照片尚未加载。") }
        var a = PhotoAdjustments()
        a.systemAdjustments = try input.autoAdjustmentFilters(options: [.enhance: true, .redEye: false, .crop: false, .level: false]).map(SystemAdjustment.capture)
        for group in a.systemAdjustments {
            func value(_ key: String, _ fallback: Double) -> Double { group.parameters.first { $0.id == key }?.values.first ?? fallback }
            switch group.name {
            case "CIExposureAdjust": a.exposure = value(kCIInputEVKey, 0)
            case "CIColorControls": a.brightness = value(kCIInputBrightnessKey, 0); a.contrast = value(kCIInputContrastKey, 1); a.saturation = value(kCIInputSaturationKey, 1)
            case "CIHighlightShadowAdjust": a.highlights = value("inputHighlightAmount", 1); a.shadows = value("inputShadowAmount", 0)
            case "CISharpenLuminance": a.sharpness = value(kCIInputSharpnessKey, 0)
            case "CIVibrance": a.vibrance = value(kCIInputAmountKey, 0)
            case "CIToneCurve":
                for i in 0..<5 { if let values = group.parameters.first(where: { $0.id == "inputPoint\(i)" })?.values, values.count == 2 { a.curve[i] = CGPoint(x: values[0], y: values[1]) } }
                a.extrapolate = value("inputExtrapolate", 0) != 0
            default: break
            }
        }
        return a
    }
    func recommendedCrop(_ a: PhotoAdjustments) throws -> (CGRect, Bool) {
        guard let input = previewInput else { throw LibraryError.message("照片尚未加载。") }
        var geometry=a;geometry.cropRect=nil;geometry.crop="原比例"
        let oriented=ImageGeometryPlan(size:input.extent.size,adjustments:geometry).apply(input)
        guard let image = context.createCGImage(oriented, from: oriented.extent) else { throw LibraryError.message("无法读取构图预览。") }
        let request = VNGenerateAttentionBasedSaliencyImageRequest()
        var subject: CGRect?
        if (try? VNImageRequestHandler(cgImage: image).perform([request])) != nil {
            let bounds = request.results?.first?.salientObjects?.map(\.boundingBox)
            if let union = bounds?.reduce(CGRect.null, { $0.union($1) }), !union.isNull {
                subject = CGRect(x: union.minX, y: 1 - union.maxY, width: union.width, height: union.height)
            }
        }
        return (EditorGeometry.recommendation(subject: subject, size: oriented.extent.size), subject != nil)
    }
    private func blend(_ original: CIImage, _ effect: CIImage, amount: Double) -> CIImage {
        original.applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: effect, kCIInputTimeKey: amount]).cropped(to: original.extent)
    }
    private func imported(_ entry:ImportedPhotoFilter?,directory:URL)throws->PhotoAdjustments? {
        guard let entry else{return nil};if let cache=presetCache[entry.id]{return cache}
        let value=try PhotoFilterStorage.load(entry,in:directory.deletingLastPathComponent().appendingPathComponent("Filters"))
        if presetCache.count>=8{presetCache.removeAll()};presetCache[entry.id]=value;return value
    }
    func filterThumbnails(_ requested:PhotoAdjustments)throws->[String:CGImage] {
        guard let input=previewInput else{return [:]}
        var a=requested;a.builtinFilter="original";a.presetID="";a.lutID="";a.filterAmount=1;a.lutAmount=1
        if thumbnailsKey==a{return thumbnailsCache}
        let base=process(input,adjustments:a,lut:nil),factor=min(128/base.extent.width,96/base.extent.height)
        let small=base.transformed(by:CGAffineTransform(scaleX:factor,y:factor))
        var results:[String:CGImage]=[:]
        for filter in BuiltinPhotoFilter.all { let output=BuiltinPhotoFilter.apply(filter.id,to:small);results[filter.id]=context.createCGImage(output,from:output.extent,format:.RGBA8,colorSpace:CGColorSpace(name:CGColorSpace.sRGB)!) }
        thumbnailsKey=a;thumbnailsCache=results;return results
    }
    private var importedThumbnailKey: PhotoAdjustments?
    private var importedThumbnailCache: [String: CGImage] = [:]
    func libraryThumbnail(_ requested: PhotoAdjustments, directory: URL, lut: LUTEntry? = nil, preset: ImportedPhotoFilter? = nil) throws -> CGImage? {
        try Task.checkCancellation()
        guard let input=previewInput else{return nil}
        var a=requested;a.builtinFilter="original";a.presetID="";a.lutID="";a.filterAmount=1;a.lutAmount=1
        if importedThumbnailKey != a { importedThumbnailCache.removeAll();importedThumbnailKey=a }
        let key=(lut == nil ? "xmp:" : "cube:")+(lut?.id ?? preset?.id ?? "")
        if let cached=importedThumbnailCache[key]{return cached}
        let factor=min(128/input.extent.width,96/input.extent.height)
        let small=input.transformed(by:CGAffineTransform(scaleX:factor,y:factor))
        let output=process(small,adjustments:a,lut:try cube(lut,directory:directory),preset:try imported(preset,directory:directory))
        let image=context.createCGImage(output,from:output.extent,format:.RGBA8,colorSpace:CGColorSpace(name:CGColorSpace.sRGB)!)
        if importedThumbnailCache.count>=64 { importedThumbnailCache.removeAll() }
        importedThumbnailCache[key]=image;return image
    }
    private var stripCache: [AdjustmentSection:(PhotoAdjustments,[CGImage])] = [:]
    func adjustmentStrip(_ group:AdjustmentSection, adjustments requested:PhotoAdjustments) throws -> [CGImage] {
        try Task.checkCancellation()
        guard let input=previewInput else{return []}
        var base=requested.resetting(group);base.builtinFilter="original";base.lutID="";base.presetID=""
        if let cached=stripCache[group],cached.0==base{return cached.1}
        let factor=min(96/input.extent.width,64/input.extent.height),small=input.transformed(by:CGAffineTransform(scaleX:factor,y:factor))
        var images:[CGImage]=[]
        for i in 0..<7 {
            var a=base;let fraction=Double(i)/6
            switch group {
            case .light:a.lightAmount=fraction*2-1
            case .color:a.colorAmount=fraction*2-1
            case .blackWhite:a.blackWhite=1;a.blackWhiteIntensity=fraction
            default:break
            }
            let output=process(small,adjustments:a,lut:nil)
            if let image=context.createCGImage(output,from:output.extent,format:.RGBA8,colorSpace:CGColorSpace(name:CGColorSpace.sRGB)!){images.append(image)}
        }
        stripCache[group]=(base,images);return images
    }
    private func configureCurve(_ filter: CIFilter, adjustments a: PhotoAdjustments) {
        for (i, point) in a.curve.enumerated() { filter.setValue(CIVector(x: point.x, y: point.y), forKey: "inputPoint\(i)") }
        if filter.inputKeys.contains("inputExtrapolate") { filter.setValue(a.extrapolate, forKey: "inputExtrapolate") }
    }
    private func process(_ original: CIImage, adjustments requested: PhotoAdjustments, lut: CubeLUT?, preset: PhotoAdjustments? = nil) -> CIImage {
        let a=requested.enabledParameters
        var image = PhotosTonePipeline.preColor(original,a)
        let systemNames = Set(a.systemAdjustments.map(\.name))
        for group in a.systemAdjustments {
            if group.name == "CIToneCurve" && a.curve.count != 5 { continue }
            guard let filter = group.makeFilter() else { continue }
            switch group.name {
            case "CIExposureAdjust": filter.setValue(a.exposure, forKey: kCIInputEVKey)
            case "CIColorControls": filter.setValue(a.brightness, forKey: kCIInputBrightnessKey); filter.setValue(a.contrast, forKey: kCIInputContrastKey); filter.setValue(a.saturation, forKey: kCIInputSaturationKey)
            case "CIHighlightShadowAdjust": filter.setValue(min(1,a.highlights), forKey: "inputHighlightAmount"); filter.setValue(a.shadows, forKey: "inputShadowAmount")
            case "CISharpenLuminance": filter.setValue(a.sharpness, forKey: kCIInputSharpnessKey)
            case "CIVibrance": filter.setValue(a.vibrance, forKey: kCIInputAmountKey)
            case "CIToneCurve": configureCurve(filter, adjustments: a)
            default: break
            }
            filter.setValue(image, forKey: kCIInputImageKey)
            if let output = filter.outputImage { image = output.cropped(to: image.extent) }
        }
        if !systemNames.contains("CIExposureAdjust"), a.exposure != 0 { image = image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: a.exposure]) }
        if !systemNames.contains("CIColorControls") { image = image.applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: a.contrast, kCIInputSaturationKey: a.saturation, kCIInputBrightnessKey: a.brightness]) }
        if !systemNames.contains("CIVibrance"), a.vibrance != 0 { image = image.applyingFilter("CIVibrance", parameters: [kCIInputAmountKey: a.vibrance]) }
        if a.curve.count != 5 { image=image.applyingFilter("CIColorCurves",parameters:["inputCurvesData":ChannelCurves.table([a.curve,a.curve,a.curve]),"inputCurvesDomain":CIVector(x:0,y:1),"inputColorSpace":CGColorSpace(name:CGColorSpace.sRGB)!]) }
        if a.curve.count == 5, !systemNames.contains("CIToneCurve"), a.curve != PhotoAdjustments().curve || a.extrapolate {
            if let curve = CIFilter(name: "CIToneCurve") { configureCurve(curve, adjustments: a); curve.setValue(image, forKey: kCIInputImageKey); image = curve.outputImage ?? image }
        }
        if a.temperature != 0 { image = image.applyingFilter("CITemperatureAndTint", parameters: ["inputNeutral": CIVector(x: 6500, y: 0), "inputTargetNeutral": CIVector(x: 6500 + a.temperature * 2500, y: 0)]) }
        if !systemNames.contains("CIHighlightShadowAdjust"), a.highlights != 1 || a.shadows != 0 { image = image.applyingFilter("CIHighlightShadowAdjust", parameters: ["inputHighlightAmount": min(1,a.highlights), "inputShadowAmount": a.shadows]) }
        if a.channelCurves.contains(where: { $0 != ChannelCurves.identity }) {
            image = image.applyingFilter("CIColorCurves", parameters: ["inputCurvesData": ChannelCurves.table(a.channelCurves), "inputCurvesDomain": CIVector(x: 0, y: 1), "inputColorSpace": CGColorSpace(name: CGColorSpace.sRGB)!])
        }
        if a.portrait > 0, !faces.isEmpty {
            var mask = CIImage(color: .black).cropped(to: image.extent)
            for face in faces {
                let rect = CGRect(x: image.extent.minX + face.minX * image.extent.width, y: image.extent.minY + face.minY * image.extent.height, width: face.width * image.extent.width, height: face.height * image.extent.height)
                let ellipse = CIFilter(name: "CIRadialGradient", parameters: ["inputCenter": CIVector(x: 0, y: 0), "inputRadius0": 0.55, "inputRadius1": 1.0, "inputColor0": CIColor.white, "inputColor1": CIColor.black])!.outputImage!
                    .transformed(by: CGAffineTransform(scaleX: rect.width * 0.6, y: rect.height * 0.65)).transformed(by: CGAffineTransform(translationX: rect.midX, y: rect.midY)).cropped(to: image.extent)
                mask = ellipse.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: mask])
            }
            let softened = image.applyingFilter("CINoiseReduction", parameters: ["inputNoiseLevel": 0.02 + a.portrait * 0.03, "inputSharpness": 0.5])
                .applyingFilter("CIColorControls", parameters: [kCIInputBrightnessKey: a.portrait * 0.025])
            let effect = softened.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: image, kCIInputMaskImageKey: mask])
            image = blend(image, effect, amount: a.portrait)
        }
        if !systemNames.contains("CISharpenLuminance"), a.sharpness > 0 { image = image.applyingFilter("CIUnsharpMask", parameters: [kCIInputIntensityKey: a.sharpness*(1-a.sharpFalloff*0.35), kCIInputRadiusKey:0.5+a.sharpEdges*2.5]) }
        image = PhotosTonePipeline.advanced(image,a)
        if a.builtinFilter != "original" { image = blend(image,BuiltinPhotoFilter.apply(a.builtinFilter,to:image),amount:a.filterAmount) }
        if let preset { image = blend(image,process(image,adjustments:preset,lut:nil),amount:a.filterAmount) }
        if let lut, a.lutAmount > 0 {
            let scale = SIMD3<Float>(repeating: 1) / (lut.maximum - lut.minimum)
            let normalized = image.applyingFilter("CIColorMatrix", parameters: ["inputRVector": CIVector(x: CGFloat(scale.x), y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: CGFloat(scale.y), z: 0, w: 0), "inputBVector": CIVector(x: 0, y: 0, z: CGFloat(scale.z), w: 0), "inputBiasVector": CIVector(x: CGFloat(-lut.minimum.x * scale.x), y: CGFloat(-lut.minimum.y * scale.y), z: CGFloat(-lut.minimum.z * scale.z), w: 0)])
            let effect = normalized.applyingFilter("CIColorCubeWithColorSpace", parameters: ["inputCubeDimension": lut.dimension, "inputCubeData": lut.data, "inputColorSpace": CGColorSpace(name: CGColorSpace.sRGB)!])
            image = blend(image, effect, amount: a.lutAmount)
        }
        return ImageGeometryPlan(size:image.extent.size,adjustments:a).apply(image)
    }
}

@MainActor final class PhotoEditorModel: ObservableObject {
    @Published var adjustments = PhotoAdjustments()
    @Published var histograms = Array(repeating:[Double](repeating:0,count:256),count:4)
    var histogram:[Double]{histograms[0]}
    @Published var filterPreviews: [String:CGImage] = [:]
    @Published var curveChannel=0
    @Published var curvePointIndex=2
    @Published var selectiveIndex=0
    @Published var systemControlTemplates:[SystemAdjustment]=[]
    @Published var activeBrush: CorrectionTool?
    @Published var brushSize = 0.035
    @Published var cropEditing = false
    @Published var rotationEditing = false
    var enhancementInfo: String { adjustments.systemAdjustments.isEmpty ? "一键增强会同步下方参数与曲线。" : "已同步：" + adjustments.systemAdjustments.map(\.title).joined(separator: "、") }
    @Published var cropInfo = "拖动框选，拖动框内移动，拖动四角调整。"
    @Published var reference: CGImage?
    @Published var original: CGImage?
    @Published var preview: CGImage?
    @Published var loading = true
    @Published var working = false
    @Published var rendering = false
    @Published var error: String?
    @Published var hasBackup = false
    @Published var faces = 0
    @Published var undo: [PhotoAdjustments] = []
    @Published var redo: [PhotoAdjustments] = []
    let engine = PhotoEditEngine()
    let library: LUTLibrary
    private var renderTask: Task<Void, Never>?
    private var gestureStart: PhotoAdjustments?
    private var generation = 0
    var dirty: Bool { adjustments != PhotoAdjustments() }
    init(directory: URL) { library = LUTLibrary.shared(directory: directory.appendingPathComponent("LUTs", isDirectory: true)) }
    func open(_ url: URL) async {
        do {
            let input = try await engine.open(url)
            histograms=PhotoHistogram.channels(input.image); original = input.image; reference = input.image; preview = input.image; hasBackup = input.hasBackup; faces = input.faces
            let suggestion=(try? await engine.enhancement()) ?? PhotoAdjustments()
            systemControlTemplates=suggestion.systemAdjustments.filter{!$0.additional.isEmpty}.map(\.neutralTemplate)
            if !systemControlTemplates.contains(where:{$0.name=="CIHighlightShadowAdjust"}),let filter=CIFilter(name:"CIHighlightShadowAdjust"),let template=try? SystemAdjustment.capture(filter){systemControlTemplates.append(template)}
        } catch { self.error = error.localizedDescription }
        loading = false
    }
    func beginGesture() { gestureStart = adjustments }
    // SwiftUI may query an old binding after undo removes the corresponding recipe.
    // Resolve stable IDs on every access; never retain indexes into mutable recipes.
    func systemValue(_ group:SystemAdjustment,_ parameter:SystemParameter,_ component:Int)->Double {
        let values=adjustments.systemAdjustments.first{$0.name==group.name}?.parameters.first{$0.id==parameter.id}?.values ?? parameter.values
        return values.indices.contains(component) ? values[component]:0
    }
    func setSystemValue(_ value:Double,group:SystemAdjustment,parameter:SystemParameter,component:Int) {
        guard value.isFinite,parameter.values.indices.contains(component) else{return}
        if !adjustments.systemAdjustments.contains(where:{$0.name==group.name}){adjustments.systemAdjustments.append(group)}
        guard let g=adjustments.systemAdjustments.firstIndex(where:{$0.name==group.name}),let p=adjustments.systemAdjustments[g].parameters.firstIndex(where:{$0.id==parameter.id}),adjustments.systemAdjustments[g].parameters[p].values.indices.contains(component) else{return}
        adjustments.systemAdjustments[g].parameters[p].values[component]=value
        adjustments.disabledGroups.remove(group.section)
    }
    func endGesture() { if let before = gestureStart, before != adjustments { undo.append(before); redo.removeAll() }; gestureStart = nil }
    func change(_ update: (inout PhotoAdjustments) -> Void) { let before = adjustments; update(&adjustments); if before != adjustments { if gestureStart == nil {undo.append(before)}; redo.removeAll() } }
    func undoChange() { guard let prior = undo.popLast() else { return }; redo.append(adjustments); adjustments = prior }
    func redoChange() { guard let next = redo.popLast() else { return }; undo.append(adjustments); adjustments = next }
    func schedulePreview() {
        generation += 1
        guard renderTask == nil else { return }
        renderTask = Task { [weak self] in
            guard let self else { return }
            self.rendering = true
            while !Task.isCancelled {
                let token = self.generation
                var parameters = self.adjustments
                if self.cropEditing { parameters.crop = "原比例"; parameters.cropRect = nil }
                do {
                    let entry = self.library.entries.first { $0.id == parameters.lutID }
                    guard parameters.lutID.isEmpty || entry != nil else { throw LibraryError.message("所选 LUT 已不在库中，请重新选择。") }
                    let preset=self.library.photoFilters.first { $0.id==parameters.presetID }
                    guard parameters.presetID.isEmpty || preset != nil else { throw LibraryError.message("所选 XMP 滤镜已从库中移除。") }
                    let image = try await self.engine.preview(parameters, lut: entry, directory: self.library.directory,preset:preset)
                    let reference = try await self.engine.reference(parameters)
                    guard !Task.isCancelled else { break }
                    // Publish a complete aligned pair while coalescing newer input; continuous
                    // dragging must not postpone every preview until the mouse stops.
                    self.reference = reference; self.preview = image; self.histograms=PhotoHistogram.channels(image)
                } catch {
                    if !Task.isCancelled && self.generation == token { self.error = error.localizedDescription }
                }
                if self.generation == token { break }
                try? await Task.sleep(nanoseconds: 16_000_000)
            }
            self.rendering = false; self.renderTask = nil
        }
    }
    func loadFilterPreviews() async { do { filterPreviews=try await engine.filterThumbnails(adjustments) } catch { self.error=error.localizedDescription } }
    func libraryPreview(lut: LUTEntry? = nil, preset: ImportedPhotoFilter? = nil) async throws -> CGImage? {
        try await engine.libraryThumbnail(adjustments,directory:library.directory,lut:lut,preset:preset)
    }
    func adjustmentStrip(_ group:AdjustmentSection) async throws -> [CGImage] { try await engine.adjustmentStrip(group,adjustments:adjustments) }
    func beautify() async { await enhance(portrait:faces>0) }
    func autoAdjust(_ group:AdjustmentSection) async {
        if [.light,.color,.curves,.whiteBalance].contains(group) {
            working=true;defer{working=false}
            do {
                let suggestion=try await engine.enhancement()
                change { a in
                    a.disabledGroups.remove(group)
                    switch group {
                    case .light:a.exposure=suggestion.exposure;a.contrast=suggestion.contrast;a.highlights=suggestion.highlights;a.shadows=suggestion.shadows;a.brightness=suggestion.brightness
                    case .color:a.saturation=suggestion.saturation;a.vibrance=suggestion.vibrance
                    case .curves:a.curve=suggestion.curve;a.extrapolate=suggestion.extrapolate
                    case .whiteBalance:
                        a.temperature=0;a.tint=0;a.whiteBalanceSample=nil
                        a.systemAdjustments.removeAll{["CITemperatureAndTint","CIWhitePointAdjust"].contains($0.name)}
                        a.systemAdjustments += suggestion.systemAdjustments.filter{["CITemperatureAndTint","CIWhitePointAdjust"].contains($0.name)}
                    default:break
                    }
                }
            } catch { self.error=error.localizedDescription }
            return
        }
        change { a in
            a.disabledGroups.remove(group)
            switch group {
            case .blackWhite:a.blackWhite=1
            case .redEye:a.automaticRedEye=true
            case .whiteBalance:a.temperature=0;a.tint=0
            case .levels:a.levels[0].black=0.02;a.levels[0].white=0.98
            case .definition:a.definition=0.3
            case .noise:a.noiseReduction=0.3
            case .sharpen:a.sharpness=0.4
            case .vignette:a.vignette=0.25
            default:break
            }
        }
    }
    func insertCurvePoint(_ point:CGPoint){
        let points=curveChannel==0 ? adjustments.curve:adjustments.channelCurves[curveChannel-1]
        let result=CurveEditing.inserting(point,in:points)
        change{if curveChannel==0{$0.curve=result.points}else{$0.channelCurves[curveChannel-1]=result.points};$0.disabledGroups.remove(.curves)}
        curvePointIndex=result.index
    }
    func brush(_ displayPoint:CGPoint) {
        guard let tool=activeBrush,let original else{return}
        let size=CGSize(width:original.width,height:original.height),plan=ImageGeometryPlan(size:size,adjustments:adjustments),point=plan.originalPoint(displayPoint)
        if [.curveBlack,.curveGray,.curveWhite,.curvePoint,.selectiveColor].contains(tool) {
            guard let rgb=EditorPixelSampler.rgb(original,point:point) else{return}
            let color=NSColor(srgbRed:rgb[0],green:rgb[1],blue:rgb[2],alpha:1)
            if tool == .selectiveColor {
                let hue=color.hueComponent
                change{a in
                    if a.selectiveColors.count==6{a.selectiveColors.append(SelectiveColorAdjustment());a.selectiveHues.append(hue)}
                    a.selectiveHues[6]=hue;a.sampledSelectiveRGB=rgb.map(Double.init);a.disabledGroups.remove(.selective)
                };selectiveIndex=6
            } else {
                let x=curveChannel==0 ? rgb[0]*0.2126+rgb[1]*0.7152+rgb[2]*0.0722:rgb[curveChannel-1]
                let points=curveChannel==0 ? adjustments.curve:adjustments.channelCurves[curveChannel-1]
                let y=tool == .curveBlack ? 0:(tool == .curveGray ? 0.5:(tool == .curveWhite ? 1:ChannelCurves.value(x,points:points)))
                insertCurvePoint(CGPoint(x:x,y:y))
            }
            activeBrush=nil;return
        }
        if tool == .whiteBalance {
            let rep=NSBitmapImageRep(cgImage:original)
            guard let color=rep.colorAt(x:min(original.width-1,Int(point.x*Double(original.width))),y:min(original.height-1,Int(point.y*Double(original.height))))?.usingColorSpace(.sRGB) else{return}
            let skin=adjustments.whiteBalanceMode == "肤色"; let target: [Double]=skin ? [1,0.82,0.7]:[1,1,1]
            change { $0.whiteBalanceSample=[max(0.02,color.redComponent/target[0]),max(0.02,color.greenComponent/target[1]),max(0.02,color.blueComponent/target[2])];$0.disabledGroups.remove(.whiteBalance) };activeBrush=nil
        } else {
            let radius=brushSize*min(plan.size.width,plan.size.height)/min(size.width,size.height)/2
            let mark=PhotoCorrection(tool:tool,point:point,radius:radius)
            if let last=adjustments.corrections.last,last.tool==tool,hypot(last.point.x-point.x,last.point.y-point.y)<radius*0.3{return}
            adjustments.corrections.append(mark);adjustments.disabledGroups.remove(tool == .retouch ? .retouch:.redEye)
        }
    }
    func enhance(portrait:Bool=false) async {
        working = true; defer { working = false }
        do {
            let suggestion = try await engine.enhancement()
            change { a in
                a.exposure = suggestion.exposure; a.contrast = suggestion.contrast; a.saturation = suggestion.saturation
                a.highlights = suggestion.highlights; a.shadows = suggestion.shadows; a.sharpness = suggestion.sharpness
                a.brightness = suggestion.brightness; a.vibrance = suggestion.vibrance; a.curve = suggestion.curve; a.extrapolate = suggestion.extrapolate; a.systemAdjustments = suggestion.systemAdjustments; a.disabledGroups.subtract([.light,.color,.curves,.sharpen,.whiteBalance])
                if portrait{a.portrait=0.25;a.disabledGroups.remove(.portrait)}
            }
        } catch { self.error = error.localizedDescription }
    }
    private var rotationEntry: PhotoAdjustments?
    func beginRotation() {
        guard !rotationEditing else { return }
        if cropEditing { finishCrop() }
        rotationEntry = adjustments; rotationEditing = true
    }
    func setFreeRotation(_ degrees: Double) {
        adjustments.freeRotation = min(45, max(-45, degrees))
        adjustments.cropRect = nil; adjustments.crop = "原比例"
    }
    func rotateQuarter(_ direction: Int) {
        change { $0.rotation = ($0.rotation + direction + 4) % 4; $0.cropRect = nil; $0.crop = "原比例" }
    }
    func finishRotation() { rotationEditing = false; rotationEntry = nil }
    func cancelRotation() {
        if let entry = rotationEntry { change { $0.rotation = entry.rotation; $0.freeRotation = entry.freeRotation; $0.crop = entry.crop; $0.cropRect = entry.cropRect } }
        rotationEditing = false; rotationEntry = nil
    }
    private var cropEntry: (String, CGRect?)?
    private func rememberCrop() { if !cropEditing { cropEntry = (adjustments.crop, adjustments.cropRect) } }
    var cropAspect: CGFloat? {
        guard let original else{return nil}
        var geometry=adjustments;geometry.cropRect=nil;geometry.crop="原比例"
        let size=ImageGeometryPlan(size:CGSize(width:original.width,height:original.height),adjustments:geometry).size
        let imageRatio=size.width/size.height
        return adjustments.cropRatio(imageAspect:imageRatio).map{$0/imageRatio}
    }
    func beginCrop() {
        guard !cropEditing else { return }
        if rotationEditing { finishRotation() }
        rememberCrop()
        if adjustments.cropRect == nil {
            let rect = cropAspect.map { EditorGeometry.aspectFit(EditorGeometry.unit, normalizedAspect: $0) } ?? EditorGeometry.unit
            change { $0.cropRect = rect }
        }
        cropEditing = true
    }
    func setCropRatio(_ ratio: String) {
        let before = adjustments
        adjustments.crop = ratio
        if let aspect = cropAspect { adjustments.cropRect = EditorGeometry.aspectFit(EditorGeometry.unit, normalizedAspect: aspect) }
        if adjustments != before { undo.append(before); redo.removeAll() }
    }
    func finishCrop() { cropEditing = false; cropEntry = nil }
    func cancelCrop() {
        if let entry = cropEntry { change { $0.crop = entry.0; $0.cropRect = entry.1 } }
        cropEditing = false; cropEntry = nil
    }
    func recommendCrop() async {
        rememberCrop()
        working = true; defer { working = false }
        do {
            let (rect, detected) = try await engine.recommendedCrop(adjustments)
            change { $0.cropRect = rect; $0.crop = "自由裁剪" }; cropEditing = true
            cropInfo = detected ? "按显著主体推荐，仍可拖动微调；切回调整或滤镜可预览裁剪结果。" : "未识别明显主体，使用保守构图；可拖动微调。"
        } catch { self.error = error.localizedDescription }
    }
    func save() async -> Bool {
        working = true; defer { working = false }
        do {
            let entry = library.entries.first { $0.id == adjustments.lutID }
            guard adjustments.lutID.isEmpty || entry != nil else { throw LibraryError.message("所选 LUT 已不在库中。") }
            let preset=library.photoFilters.first { $0.id==adjustments.presetID }
            guard adjustments.presetID.isEmpty || preset != nil else { throw LibraryError.message("所选 XMP 滤镜已从库中移除。") }
            try await engine.save(adjustments, lut: entry, directory: library.directory,preset:preset)
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func restore() async -> Bool {
        working = true; defer { working = false }
        do { try await engine.restore(); return true }
        catch { self.error = error.localizedDescription; return false }
    }
    func dispose() { renderTask?.cancel() }
}
