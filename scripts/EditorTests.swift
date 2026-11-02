import Foundation
import AppKit
import ImageIO
import CoreImage
import SwiftUI
import UniformTypeIdentifiers

@main struct EditorTests {
    static func jpeg(_ url: URL, color: NSColor, orientation: Int = 1) throws {
        let context = CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(color.cgColor); context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, [kCGImagePropertyOrientation: orientation, kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:01:02 03:04:05"], kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFModel: "EditorFixture"]] as CFDictionary)
        precondition(CGImageDestinationFinalize(destination))
        try (data as Data).write(to: url)
    }
    static func require(_ value: @autoclosure () throws -> Bool) rethrows { let result = try value(); precondition(result) }
    static func expectFailure(_ work: () throws -> Void) {
        do { try work(); preconditionFailure("Unsafe operation accepted") } catch {}
    }
    @MainActor static func main() async throws {
        let unresolved = FileManager.default.temporaryDirectory.appendingPathComponent("PhotoHarborEditor-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: unresolved, withIntermediateDirectories: true)
        let root = canonicalURL(unresolved)
        defer { try? FileManager.default.removeItem(at: root) }
        let jpg = root.appendingPathComponent("A.JPG"), raw = root.appendingPathComponent("A.ARW")
        try jpeg(jpg, color: .red); try Data("RAW fixture".utf8).write(to: raw)
        let original = try Data(contentsOf: jpg), rawData = try Data(contentsOf: raw)
        let edited = root.appendingPathComponent("edit.JPG"); try jpeg(edited, color: .blue)
        let blue = try Data(contentsOf: edited)
        let initial = try EditPersistence.snapshot(jpg)
        try jpeg(jpg, color: .green)
        expectFailure { _ = try EditPersistence.save(blue, to: jpg, expected: initial) }
        try require(try Data(contentsOf: jpg) != blue)
        try original.write(to: jpg)
        _ = try EditPersistence.save(blue, to: jpg, expected: EditPersistence.snapshot(jpg))
        try require(try Data(contentsOf: jpg) == blue)
        _ = try EditPersistence.save(original, to: jpg, expected: EditPersistence.snapshot(jpg))
        _ = try EditPersistence.save(blue, to: jpg, expected: EditPersistence.snapshot(jpg))
        _ = try EditPersistence.restore(jpg, expected: EditPersistence.snapshot(jpg))
        try require(try Data(contentsOf: jpg) == original)
        try require(try Data(contentsOf: raw) == rawData)
        print("PASS overwrite checks external changes, first backup survives repeated saves, exact restore and RAW retention")
        let backup = EditPersistence.backupURL(jpg)
        try Data("corrupt".utf8).write(to: backup)
        expectFailure { _ = try EditPersistence.restore(jpg, expected: EditPersistence.snapshot(jpg)) }
        try require(try Data(contentsOf: jpg) == original)
        let linked = root.appendingPathComponent("linked.JPG")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: jpg)
        expectFailure { _ = try EditPersistence.snapshot(linked) }
        print("PASS corrupted backup and symlink rejection leave source intact")
        let cube = "LUT_3D_SIZE 2\n0 0 0\n1 0 0\n0 1 0\n1 1 0\n0 0 1\n1 0 1\n0 1 1\n1 1 1\n"
        let parsed = try CubeLUT.parse(Data(cube.utf8))
        precondition(parsed.dimension == 2 && parsed.data.count == 8 * 16)
        expectFailure { _ = try CubeLUT.parse(Data("LUT_3D_SIZE 64\n0 0 0".utf8)) }
        expectFailure { _ = try CubeLUT.parse(Data(cube.replacingOccurrences(of: "1 1 1", with: "nan 1 1").utf8)) }
        expectFailure { _ = try CubeLUT.parse(Data("LUT_1D_SIZE 2\n0 0 0\n1 1 1".utf8)) }
        print("PASS cube validation, identity ordering, missing rows and invalid numbers")
        let lutSource = root.appendingPathComponent("identity.cube"), library = root.appendingPathComponent("LUTs")
        try Data(cube.utf8).write(to: lutSource)
        let entry = try LUTStorage.add(lutSource, to: library)
        _ = try LUTStorage.add(lutSource, to: library)
        precondition(LUTStorage.entries(in: library).count == 1)
        _ = try LUTStorage.load(entry, in: library)
        try FileManager.default.removeItem(at: lutSource)
        _ = try LUTStorage.load(entry, in: library)
        let domainCube = "DOMAIN_MIN -1 -1 -1\nDOMAIN_MAX 2 2 2\n" + cube
        let domain = try CubeLUT.parse(Data(domainCube.utf8))
        precondition(domain.minimum.x == -1 && domain.maximum.z == 2)
        print("PASS LUT import deduplicates, retains an independent copy and supports input domains")
        let renderURL = root.appendingPathComponent("render.JPG")
        try jpeg(renderURL, color: NSColor(srgbRed: 0.8, green: 0.2, blue: 0.1, alpha: 1))
        let renderOriginal = try Data(contentsOf: renderURL)
        let engine = PhotoEditEngine(softwareRendering: true)
        let opened = try await engine.open(renderURL)
        precondition(opened.image.width == 64 && opened.image.height == 48)
        func pixel(_ image: CGImage) -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: 4)
            bytes.withUnsafeMutableBytes { memory in
                let context = CGContext(data: memory.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            }
            return bytes
        }
        let baseImage = try await engine.preview(PhotoAdjustments(), lut: nil, directory: library)
        let identityImage = try await engine.preview(PhotoAdjustments(), lut: entry, directory: library)
        let basePixel = pixel(baseImage), identityPixel = pixel(identityImage)
        for i in 0..<3 { precondition(abs(Int(basePixel[i]) - Int(identityPixel[i])) < 5) }
        var adjustments = PhotoAdjustments(); adjustments.exposure = -1
        let darker = try await engine.preview(adjustments, lut: nil, directory: library)
        precondition(pixel(darker)[0] < basePixel[0])
        adjustments.rotation = 1; adjustments.crop = "1:1"
        try await engine.save(adjustments, lut: nil, directory: library)
        let saved = CGImageSourceCreateWithURL(renderURL as CFURL, nil)!
        let savedImage = CGImageSourceCreateImageAtIndex(saved, 0, nil)!
        precondition(savedImage.width == 48 && savedImage.height == 48)
        try await engine.restore()
        try require(try Data(contentsOf: renderURL) == renderOriginal)
        precondition(Metadata.read(renderURL).camera == "EditorFixture")
        let orientedURL = root.appendingPathComponent("oriented.JPG")
        try jpeg(orientedURL, color: .blue, orientation: 6)
        let orientedEngine = PhotoEditEngine(softwareRendering: true)
        let orientedInput = try await orientedEngine.open(orientedURL)
        precondition(orientedInput.image.width == 48 && orientedInput.image.height == 64)
        var orientedAdjustment = PhotoAdjustments(); orientedAdjustment.exposure = -0.5
        try await orientedEngine.save(orientedAdjustment, lut: nil, directory: library)
        let orientedSource = CGImageSourceCreateWithURL(orientedURL as CFURL, nil)!
        let orientedProperties = CGImageSourceCopyPropertiesAtIndex(orientedSource, 0, nil)! as NSDictionary
        precondition(orientedProperties[kCGImagePropertyOrientation] as? Int == 1)
        precondition(Metadata.read(orientedURL).camera == "EditorFixture" && Metadata.read(orientedURL).date != nil)
        let interruptURL = root.appendingPathComponent("interrupted.JPG")
        try jpeg(interruptURL, color: .red)
        let interruptOriginal = try Data(contentsOf: interruptURL)
        _ = try EditPersistence.save(blue, to: interruptURL, expected: EditPersistence.snapshot(interruptURL))
        let recordURL = EditPersistence.backupURL(interruptURL).deletingPathExtension().appendingPathExtension("json")
        var pending = try JSONDecoder().decode(EditBackupRecord.self, from: Data(contentsOf: recordURL))
        pending.pendingDigest = pending.savedDigest; pending.savedDigest = EditPersistence.hash(interruptOriginal)
        try JSONEncoder().encode(pending).write(to: recordURL)
        _ = try EditPersistence.restore(interruptURL, expected: EditPersistence.snapshot(interruptURL))
        try require(try Data(contentsOf: interruptURL) == interruptOriginal)
        let linkedDirectoryURL = root.appendingPathComponent("nested/photo.JPG")
        try FileManager.default.createDirectory(at: linkedDirectoryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try jpeg(linkedDirectoryURL, color: .red)
        try FileManager.default.createSymbolicLink(at: EditPersistence.backupURL(linkedDirectoryURL).deletingLastPathComponent(), withDestinationURL: library)
        expectFailure { _ = try EditPersistence.save(blue, to: linkedDirectoryURL, expected: EditPersistence.snapshot(linkedDirectoryURL)) }
        print("PASS software preview, identity LUT pixels, exposure, full-size save, EXIF orientation/date, interrupted record recovery and backup-directory symlink rejection")
        let selection = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        precondition(EditorGeometry.pixels(selection, in: CGRect(x: 0, y: 0, width: 80, height: 60)) == CGRect(x: 20, y: 15, width: 40, height: 30))
        let asymmetric = EditorGeometry.pixels(CGRect(x: 0, y: 0, width: 0.5, height: 0.25), in: CGRect(x: 0, y: 0, width: 80, height: 60))
        precondition(asymmetric.minY == 45 && asymmetric.height == 15)
        precondition(EditorGeometry.valid(CGRect(x: 0, y: 0, width: -1, height: 1)) == nil)
        precondition(EditorGeometry.valid(CGRect(x: 0, y: 0, width: CGFloat.nan, height: 1)) == nil)
        let subject = CGRect(x: 0.04, y: 0.2, width: 0.3, height: 0.5)
        for size in [CGSize(width: 600, height: 400), CGSize(width: 400, height: 600)] {
            let crop = EditorGeometry.recommendation(subject: subject, size: size)
            precondition(EditorGeometry.unit.contains(crop) && crop.contains(subject))
        }
        let freeURL = root.appendingPathComponent("free.JPG")
        try jpeg(freeURL, color: .red)
        let freeOriginal = try Data(contentsOf: freeURL), freeEngine = PhotoEditEngine(softwareRendering: true)
        _ = try await freeEngine.open(freeURL)
        var free = PhotoAdjustments(); free.cropRect = selection; free.exposure = -1
        let freePreview = try await freeEngine.preview(free, lut: nil, directory: library)
        let freeReference = try await freeEngine.reference(free)
        precondition(freePreview.width == 32 && freePreview.height == 24 && freeReference.width == freePreview.width && freeReference.height == freePreview.height)
        precondition(pixel(freePreview)[0] < pixel(freeReference)[0])
        try await freeEngine.save(free, lut: nil, directory: library)
        let freeSource = CGImageSourceCreateWithURL(freeURL as CFURL, nil)!
        let freeSaved = CGImageSourceCreateImageAtIndex(freeSource, 0, nil)!
        precondition(freeSaved.width == 32 && freeSaved.height == 24)
        try await freeEngine.restore()
        try require(try Data(contentsOf: freeURL) == freeOriginal)
        let automatic = try await freeEngine.enhancement()
        precondition(automatic.exposure.isFinite && automatic.shadows.isFinite)
        let autoPreview = try await freeEngine.preview(automatic, lut: nil, directory: library)
        precondition(autoPreview.width == 64 && autoPreview.height == 48)
        print("PASS free crop top-left coordinates, bounded recommendations, aligned comparison reference, cropped save/restore and readable enhancement parameters")

        // Recreating the system's actual recipe must preserve its output, rather than estimate slider values.
        let nativeSource = CGImageSourceCreateWithURL(freeURL as CFURL, nil)!
        var native = CIImage(cgImage: CGImageSourceCreateImageAtIndex(nativeSource, 0, nil)!)
        let nativeFilters = native.autoAdjustmentFilters(options: [.enhance: true, .redEye: false, .crop: false, .level: false])
        for filter in nativeFilters { filter.setValue(native, forKey: kCIInputImageKey); native = filter.outputImage ?? native }
        let nativeContext = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, .outputColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, .useSoftwareRenderer: true])
        let nativeImage = nativeContext.createCGImage(native, from: native.extent)!
        for i in 0..<3 { precondition(abs(Int(pixel(nativeImage)[i]) - Int(pixel(autoPreview)[i])) <= 3) }
        for name in ["CITemperatureAndTint", "CIWhitePointAdjust", "CIColorMatrix", "CIToneCurve"] {
            let filter = CIFilter(name: name)!
            let snapshot = try SystemAdjustment.capture(filter)
            let rebuilt = try SystemAdjustment.capture(snapshot.makeFilter()!)
            precondition(snapshot == rebuilt)
        }
        var curveOnly = PhotoAdjustments(); curveOnly.curve[2].y = 0.1
        let curvePreview = try await freeEngine.preview(curveOnly, lut: nil, directory: library)
        let plainReference = try await freeEngine.reference(curveOnly)
        precondition(pixel(curvePreview) != pixel(plainReference))
        print("PASS full system recipe preserves native enhancement output; scalar/vector/color/boolean roundtrip and independent curve editing")

        let renamed = try LUTStorage.rename(entry, to: "  自定义影调  ", in: library)
        precondition(renamed.id == entry.id && renamed.name == "自定义影调")
        _ = try LUTStorage.load(renamed, in: library)
        let reimport = root.appendingPathComponent("reimport.cube"); try Data(cube.utf8).write(to: reimport)
        let dedup = try LUTStorage.add(reimport, to: library, name: "不应替换已有名称")
        precondition(dedup.name == "自定义影调")
        expectFailure { _ = try LUTStorage.rename(renamed, to: "  ", in: library) }
        expectFailure { _ = try LUTStorage.rename(renamed, to: "bad/name", in: library) }
        expectFailure { _ = try LUTStorage.rename(renamed, to: String(repeating: "长", count: 81), in: library) }
        let namedSource = root.appendingPathComponent("named.cube"); try Data(("# distinct\n" + cube).utf8).write(to: namedSource)
        let named = try LUTStorage.add(namedSource, to: library, name: "导入时命名")
        precondition(named.name == "导入时命名")
        expectFailure { _ = try LUTStorage.rename(named, to: "自定义影调", in: library) }
        let manyLibrary = root.appendingPathComponent("many-LUTs")
        for index in 0..<240 {
            let source = root.appendingPathComponent("batch.cube")
            try Data(("# synthetic \(index)\n" + cube).utf8).write(to: source)
            _ = try LUTStorage.add(source, to: manyLibrary, name: String(format: "合成 LUT %03d", index) + (index % 20 == 0 ? String(repeating: "长名称", count: 12) : ""))
        }
        let many = LUTStorage.entries(in: manyLibrary)
        precondition(many.count == 240 && Set(many.map(\.id)).count == 240)
        let last = many.last!; let renamedLast = try LUTStorage.rename(last, to: "最后一项已重命名", in: manyLibrary)
        precondition(LUTStorage.entries(in: manyLibrary).contains { $0.name == renamedLast.name })
        _ = try LUTStorage.load(renamedLast, in: manyLibrary)
        print("PASS import names, rename persistence/content identity, duplicate/invalid names and 240-entry library")

        for i in 0...100 { let x = Double(i) / 100; precondition(abs(ChannelCurves.value(x, points: ChannelCurves.identity) - x) < 0.00001) }
        let channelsURL = root.appendingPathComponent("channels.JPG")
        try jpeg(channelsURL, color: NSColor(srgbRed: 0.45, green: 0.4, blue: 0.35, alpha: 1))
        let channelOriginal = try Data(contentsOf: channelsURL), channelEngine = PhotoEditEngine(softwareRendering: true)
        _ = try await channelEngine.open(channelsURL)
        let channelBase = pixel(try await channelEngine.preview(PhotoAdjustments(), lut: nil, directory: library))
        for channel in 0..<3 {
            var a = PhotoAdjustments(); a.channelCurves[channel][2].y = 0.8
            let edited = pixel(try await channelEngine.preview(a, lut: nil, directory: library))
            precondition(Int(edited[channel]) > Int(channelBase[channel]) + 15)
            for other in 0..<3 where other != channel { precondition(abs(Int(edited[other]) - Int(channelBase[other])) <= 3) }
        }
        var combined = PhotoAdjustments(); combined.curve[2].y = 0.6; combined.channelCurves[2][2].y = 0.8
        try await channelEngine.save(combined, lut: nil, directory: library)
        try await channelEngine.restore()
        try require(try Data(contentsOf: channelsURL) == channelOriginal)
        for p in [CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.9, y: 0.1), CGPoint(x: 0.1, y: 0.9), CGPoint(x: 0.9, y: 0.9)] {
            let constrained = EditorGeometry.drag(anchor: CGPoint(x: 0.5, y: 0.5), to: p, normalizedAspect: 1.5)
            precondition(EditorGeometry.unit.contains(constrained) && abs(constrained.width / constrained.height - 1.5) < 0.00001)
        }
        print("PASS independent R/G/B curves preserve other channels, combined save/restore and ratio-locked crop dragging")

        var rotation = PhotoAdjustments(); rotation.freeRotation = 30
        let turned = try await channelEngine.preview(rotation, lut: nil, directory: library)
        let turnedBefore = try await channelEngine.reference(rotation)
        precondition(turned.width < 64 && turned.height < 48 && turned.width == turnedBefore.width && turned.height == turnedBefore.height)
        var raster = [UInt8](repeating: 0, count: turned.width * turned.height * 4)
        raster.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: turned.width, height: turned.height, bitsPerComponent: 8, bytesPerRow: turned.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(turned, in: CGRect(x: 0, y: 0, width: turned.width, height: turned.height))
        }
        for (x, y) in [(0, 0), (turned.width - 1, 0), (0, turned.height - 1), (turned.width - 1, turned.height - 1)] { precondition(raster[(y * turned.width + x) * 4 + 3] >= 250) }
        try await channelEngine.save(rotation, lut: nil, directory: library)
        let rotatedSaved = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(channelsURL as CFURL, nil)!, 0, nil)!
        precondition(rotatedSaved.width == turned.width && rotatedSaved.height == turned.height)
        try await channelEngine.restore()
        try require(try Data(contentsOf: channelsURL) == channelOriginal)
        print("PASS free rotation preview/reference alignment, filled corners, full-resolution dimensions and exact restore")

        let ruler = AngleRulerView()
        var rulerValue = 0.0, rulerGestures: [Bool] = []
        ruler.changed = { rulerValue = $0 }; ruler.editing = { rulerGestures.append($0) }
        precondition(ruler.accessibilityPerformIncrement() && abs(rulerValue - 0.1) < 0.00001)
        ruler.setAccessibilityValue(NSNumber(value: 99)); precondition(rulerValue == 45)
        precondition(ruler.accessibilityPerformDecrement() && abs(rulerValue - 44.9) < 0.00001)
        precondition(rulerGestures == [true, false, true, false, true, false])
        let live = PhotoEditorModel(directory: root)
        await live.open(channelsURL)
        let initialPixel = pixel(live.preview!)
        var updatedDuringInput = false
        for i in 1...20 {
            live.adjustments.exposure = -Double(i) / 20; live.schedulePreview()
            try await Task.sleep(nanoseconds: 10_000_000)
            if i == 10 { updatedDuringInput = pixel(live.preview!) != initialPixel }
        }
        for _ in 0..<200 { if !live.rendering { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(updatedDuringInput && !live.rendering)
        var finalSettings = PhotoAdjustments(); finalSettings.exposure = -1
        let finalExpected = pixel(try await channelEngine.preview(finalSettings, lut: nil, directory: library))
        for c in 0..<3 { precondition(abs(Int(pixel(live.preview!)[c]) - Int(finalExpected[c])) <= 3) }
        live.dispose()
        print("PASS ruler fine steps/limits/undo grouping and continuous preview updates before input ends with latest-value convergence")

        let xmpText = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><rdf:Description xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/" crs:Exposure2012="0.5" crs:Highlights2012="25" crs:Saturation="20" crs:HueAdjustmentRed="15" crs:CameraProfile="MissingAdobeProfile" crs:Texture="30"><crs:Name><rdf:Alt><rdf:li>合成预设</rdf:li></rdf:Alt></crs:Name></rdf:Description></rdf:RDF></x:xmpmeta>
        """
        let mapped = try XMPPhotoFilter.parse(Data(xmpText.utf8))
        precondition(mapped.recipe.exposure == 0.5 && mapped.recipe.highlights == 1.25 && mapped.recipe.saturation == 1.2 && mapped.recipe.selectiveColors[0].hue == 0.15)
        precondition(mapped.name == "合成预设" && mapped.warnings.contains(where:{$0.contains("Texture")}) && mapped.warnings.contains(where:{$0.contains("MissingAdobeProfile")}))
        expectFailure { _ = try XMPPhotoFilter.parse(Data("<!DOCTYPE x [<!ENTITY y SYSTEM 'file:///etc/passwd'>]><x>&y;</x>".utf8)) }
        expectFailure { _ = try XMPPhotoFilter.parse(Data("<x/>".utf8)) }
        expectFailure { _ = try XMPPhotoFilter.parse(Data(repeating:32,count:2*1024*1024+1)) }
        let xmpSource=root.appendingPathComponent("test.xmp"), filters=root.appendingPathComponent("Filters")
        try Data(xmpText.utf8).write(to:xmpSource)
        let preset=try PhotoFilterStorage.add(xmpSource,to:filters,name:"测试滤镜")
        _ = try PhotoFilterStorage.add(xmpSource,to:filters,name:"重复内容")
        precondition(PhotoFilterStorage.entries(in:filters).count==1)
        try PhotoFilterStorage.rename(preset,to:"新名称",in:filters)
        precondition(PhotoFilterStorage.entries(in:filters).first?.name == "新名称")
        var presetSettings=PhotoAdjustments();presetSettings.presetID=preset.id
        let presetPixel=pixel(try await channelEngine.preview(presetSettings,lut:nil,directory:library,preset:preset))
        precondition(presetPixel != channelBase)
        try Data("changed".utf8).write(to:PhotoFilterStorage.file(preset,in:filters))
        expectFailure { _ = try PhotoFilterStorage.load(preset,in:filters) }
        try Data(xmpText.utf8).write(to:PhotoFilterStorage.file(preset,in:filters))
        let xmpThumb=try await channelEngine.libraryThumbnail(PhotoAdjustments(),directory:library,preset:preset)
        let lutThumb=try await channelEngine.libraryThumbnail(PhotoAdjustments(),directory:library,lut:entry)
        precondition(xmpThumb != nil && lutThumb != nil && xmpThumb!.width<=128 && lutThumb!.height<=96)
        precondition(pixel(xmpThumb!) != pixel(lutThumb!))
        let allThumbs=try await channelEngine.filterThumbnails(PhotoAdjustments())
        precondition(allThumbs.count==10)
        for group in [AdjustmentSection.light,.color,.blackWhite] {
            let strip=try await channelEngine.adjustmentStrip(group,adjustments:PhotoAdjustments())
            precondition(strip.count==7 && strip.allSatisfy{$0.width<=96 && $0.height<=64})
        }
        print("PASS imported XMP and LUT current-photo thumbnails, bounded output and ten built-in previews")
        print("PASS XMP mapping, compatibility warnings, XML entity/size rejection, independent import, deduplication, naming and digest checks")

        var modern=PhotoAdjustments();modern.exposure=1;modern.disabledGroups=[.light]
        let disabledPixel=pixel(try await channelEngine.preview(modern,lut:nil,directory:library))
        for c in 0..<3 { precondition(abs(Int(disabledPixel[c])-Int(channelBase[c]))<=3) }
        modern.disabledGroups=[]
        let enabledPixel=pixel(try await channelEngine.preview(modern,lut:nil,directory:library));precondition(enabledPixel != disabledPixel)
        for effect in BuiltinPhotoFilter.all {
            var settings=PhotoAdjustments();settings.builtinFilter=effect.id
            let image=try await channelEngine.preview(settings,lut:nil,directory:library)
            precondition(image.width==64 && image.height==48)
            if ["mono","tonal","noir"].contains(effect.id) { let values=pixel(image);precondition(abs(Int(values[0])-Int(values[1]))<=2 && abs(Int(values[1])-Int(values[2]))<=2) }
            settings.filterAmount=0
            let zero=pixel(try await channelEngine.preview(settings,lut:nil,directory:library))
            for c in 0..<3 { precondition(abs(Int(zero[c])-Int(channelBase[c]))<=3) }
        }
        let effectChanges:[(inout PhotoAdjustments)->Void] = [
            {$0.brilliance=0.6},{$0.blackPoint=0.5},{$0.colorAmount=0.5},{$0.tint=0.5},{$0.levels[0].gamma=2},{$0.selectiveColors[0].hue=0.6},{$0.blackWhite=1;$0.blackWhiteGrain=0.5},{$0.noiseReduction=0.5},{$0.definition=0.5},{$0.vignette=0.6},{$0.corrections=[PhotoCorrection(tool:.retouch,point:CGPoint(x:0.5,y:0.5),radius:0.05)]},{$0.corrections=[PhotoCorrection(tool:.redEye,point:CGPoint(x:0.5,y:0.5),radius:0.2)]}
        ]
        for mutate in effectChanges { var settings=PhotoAdjustments();mutate(&settings);let image=try await channelEngine.preview(settings,lut:nil,directory:library);precondition(image.width==64 && image.height==48) }
        print("PASS adjustment group bypass/restore, ten built-in previews, zero-strength identity, monochrome output and all advanced effect families")
        var geometry=PhotoAdjustments();geometry.flipHorizontal=true
        let flipPlan=ImageGeometryPlan(size:CGSize(width:640,height:480),adjustments:geometry)
        let originalPoint=flipPlan.originalPoint(CGPoint(x:0.2,y:0.3))
        precondition(abs(originalPoint.x-0.8)<0.00001 && abs(originalPoint.y-0.3)<0.00001)
        for vertical in [-0.8,0.8] { for horizontal in [-0.8,0.8] {
            var settings=PhotoAdjustments();settings.perspectiveVertical=vertical;settings.perspectiveHorizontal=horizontal
            let image=try await channelEngine.preview(settings,lut:nil,directory:library),reference=try await channelEngine.reference(settings)
            precondition(image.width==reference.width && image.height==reference.height && image.width<64 && image.height<48)
            var bytes=[UInt8](repeating:0,count:image.width*image.height*4)
            bytes.withUnsafeMutableBytes { memory in let c=CGContext(data:memory.baseAddress,width:image.width,height:image.height,bitsPerComponent:8,bytesPerRow:image.width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!;c.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height)) }
            for (x,y) in [(0,0),(image.width-1,0),(0,image.height-1),(image.width-1,image.height-1)] { precondition(bytes[(y*image.width+x)*4+3]>=250) }
        } }
        for edge in 0..<4 {
            let rect=EditorGeometry.dragEdge(edge,initial:CGRect(x:0.2,y:0.2,width:0.6,height:0.6),to:CGPoint(x:0.5,y:0.5),normalizedAspect:1.5)
            precondition(EditorGeometry.unit.contains(rect) && abs(rect.width/rect.height-1.5)<0.00001)
        }
        print("PASS flip inverse mapping, perspective/reference alignment and filled corners, four crop edges with preserved aspect")

        let histogramImage=try await channelEngine.preview(PhotoAdjustments(),lut:nil,directory:library)
        let histogramChannels=PhotoHistogram.channels(histogramImage)
        precondition(histogramChannels.count==4 && histogramChannels.allSatisfy{$0.count==256 && $0.max()==1})
        for c in 0..<3 {
            let peak=histogramChannels[c+1].enumerated().max{$0.element<$1.element}!.offset
            precondition(abs(peak-Int(channelBase[c]))<=3)
        }
        var brighter=PhotoAdjustments();brighter.exposure=1
        let brighterImage=try await channelEngine.preview(brighter,lut:nil,directory:library)
        precondition(PhotoHistogram.channels(brighterImage) != histogramChannels)
        let perspectiveRuler=AngleRulerView();perspectiveRuler.rulerTitle="垂直"
        precondition(perspectiveRuler.accessibilityLabel()=="垂直刻度尺")
        print("PASS actual luminance/R/G/B histogram peaks match photo pixels and update after exposure; named perspective ruler accessibility")

        var flexible=PhotoAdjustments()
        flexible.curve=CurveEditing.inserting(CGPoint(x:0.125,y:0.4),in:flexible.curve).points
        flexible.curve=CurveEditing.inserting(CGPoint(x:0.625,y:0.9),in:flexible.curve).points
        precondition(flexible.curve.count==7)
        let flexiblePreview=try await channelEngine.preview(flexible,lut:nil,directory:library)
        precondition(pixel(flexiblePreview) != channelBase)
        try await channelEngine.save(flexible,lut:nil,directory:library)
        try await channelEngine.restore()
        try require(try Data(contentsOf:channelsURL)==channelOriginal)
        var dense=ChannelCurves.identity
        for i in 1..<100{dense=CurveEditing.inserting(CGPoint(x:Double(i)/100,y:Double(i)/100),in:dense).points}
        precondition(dense.count==CurveEditing.limit && zip(dense,dense.dropFirst()).allSatisfy{$0.x<$1.x})
        let sampled=PhotoEditorModel(directory:root)
        await sampled.open(channelsURL)
        sampled.curveChannel=1;sampled.activeBrush = .curveWhite
        sampled.brush(CGPoint(x:0.5,y:0.5))
        precondition(sampled.activeBrush==nil && sampled.adjustments.channelCurves[0].count==6)
        let chosen=sampled.adjustments.channelCurves[0][sampled.curvePointIndex]
        precondition(abs(chosen.x-Double(channelBase[0])/255)<0.03 && chosen.y==1)
        sampled.activeBrush = .selectiveColor;sampled.brush(CGPoint(x:0.5,y:0.5))
        precondition(sampled.activeBrush==nil && sampled.adjustments.selectiveHues[sampled.selectiveIndex] != Double(sampled.selectiveIndex)/6)
        precondition(sampled.selectiveIndex==6 && sampled.adjustments.selectiveColors.count==7 && sampled.adjustments.selectiveHues.prefix(6).elementsEqual((0..<6).map{Double($0)/6}))
        let chosenRGB=sampled.adjustments.sampledSelectiveRGB!
        precondition(abs(chosenRGB[0]-Double(channelBase[0])/255)<0.03)
        sampled.change{$0.selectiveColors[6].saturation = -1}
        let customPreview=try await channelEngine.preview(sampled.adjustments,lut:nil,directory:library)
        precondition(pixel(customPreview) != channelBase)
        sampled.dispose()
        print("PASS seven-point master curve rendering/save/restore, point cap/order, sampled white-point insertion and custom selective hue")

        let stale=PhotoEditorModel(directory:root)
        let strength=SystemParameter(id:"inputStrength",title:"强度",kind:.scalar,values:[0],lower:0,upper:1)
        let face=SystemAdjustment(name:"CIFaceBalance",title:"人脸色彩平衡",parameters:[strength])
        stale.systemControlTemplates=[face]
        let host=NSHostingView(rootView:SystemAdjustmentControls(model:stale));host.frame=NSRect(x:0,y:0,width:280,height:400)
        for _ in 0..<20{
            stale.beginGesture();stale.setSystemValue(1,group:face,parameter:strength,component:0);stale.endGesture();host.layoutSubtreeIfNeeded()
            stale.undoChange();host.layoutSubtreeIfNeeded()
            precondition(stale.systemValue(face,strength,0)==0)
            stale.redoChange();stale.change{$0=PhotoAdjustments()};host.layoutSubtreeIfNeeded()
            precondition(stale.systemValue(face,strength,0)==0 && stale.systemValue(face,strength,99)==0)
            await Task.yield()
        }
        precondition(stale.systemControlTemplates.count==1)
        stale.beginGesture();stale.setSystemValue(1,group:face,parameter:strength,component:0);stale.endGesture()
        precondition(face.section == .portrait && stale.adjustments.isChanged(.portrait))
        precondition(stale.adjustments.resetting(.portrait).systemAdjustments.isEmpty)
        stale.adjustments.disabledGroups.insert(.portrait)
        precondition(stale.adjustments.enabledParameters.systemAdjustments.isEmpty)
        stale.setSystemValue(0.5,group:face,parameter:strength,component:0)
        precondition(!stale.adjustments.disabledGroups.contains(.portrait))
        let bulk=LUTLibrary(directory:root.appendingPathComponent("Bulk/LUTs"))
        var batch=[LUTImportItem]()
        for i in 0..<140{
            let path=root.appendingPathComponent("bulk-\(i).xmp")
            try Data("<x:xmpmeta xmlns:x=\"adobe:ns:meta/\" xmlns:crs=\"http://ns.adobe.com/camera-raw-settings/1.0/\"><crs:Exposure2012>\(Double(i)/140)</crs:Exposure2012></x:xmpmeta>".utf8).write(to:path)
            batch.append(LUTImportItem(url:path,name:"Preset \(i)"))
        }
        let bad=root.appendingPathComponent("bad.xmp");try Data("not xml".utf8).write(to:bad);batch.insert(LUTImportItem(url:bad,name:"Bad"),at:70)
        let report=await bulk.importNamed(batch)
        precondition(report.succeeded==140 && report.failures.count==1 && bulk.photoFilters.count==140 && bulk.importCompleted==141)
        if let external=ProcessInfo.processInfo.environment["PHOTOHARBOR_IMPORT_TEST_PATH"]{
            let files=try FileManager.default.contentsOfDirectory(at:URL(fileURLWithPath:external),includingPropertiesForKeys:nil).filter{$0.pathExtension=="xmp"}
            let result=await bulk.importNamed(files.map{LUTImportItem(url:$0,name:String($0.deletingPathExtension().lastPathComponent.replacingOccurrences(of:":",with:" ").prefix(80)))})
            print("External XMP batch: \(result.succeeded) processed, \(result.failures.count) failed")
            for failure in result.failures.prefix(5){print(failure.message)}
        }
        print("PASS retained system bindings after undo/reset, permanent templates and 141-file partial import with progress")

    }
}
