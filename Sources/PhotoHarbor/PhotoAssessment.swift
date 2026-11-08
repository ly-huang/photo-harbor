import Foundation
import Vision
import ImageIO
import CoreGraphics

struct PhotoAssessment: Sendable {
    var aesthetics: Double?
    var aestheticsNote = ""
    var detailEnergy: Double = 0
    var darkPercent: Double = 0
    var brightPercent: Double = 0
    var meanBrightness: Double = 0
    var metadata = Metadata()
    var histogram: [Double] = []
}
struct PairAssessment: Sendable {
    var left: PhotoAssessment
    var right: PhotoAssessment
    var distance: Float?
    var similarityNote = ""
}
struct AssessmentDistance: Sendable {
    let first: Int
    let second: Int
    let value: Float
}
struct GroupAssessment: Sendable {
    var stats: [PhotoAssessment?]
    var errors: [String?]
    var distances: [AssessmentDistance]
}
actor AssessmentService {
    static let shared = AssessmentService()
    private struct Entry { let stats: PhotoAssessment; let feature: Any? }
    private var cache: [String: Entry] = [:]
    private func analyze(_ url: URL) async throws -> Entry {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let stamp = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key = "\(url.path)|\(stamp)|\(attributes[.size] ?? "")"
        if let cached = cache[key] { return cached }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 1024] as CFDictionary) else { throw LibraryError.message("无法解码对比照片：\(url.lastPathComponent)") }
        var stats = pixelMetrics(image)
        stats.metadata = Metadata.read(url)
        var feature: Any?
        if #available(macOS 15.0, *) {
            var request = GenerateImageFeaturePrintRequest(.revision2)
            request.cropAndScaleAction = .scaleToFit
            feature = try? await request.perform(on: image)
            if let observation = try? await CalculateImageAestheticsScoresRequest(.revision1).perform(on: image) {
                stats.aesthetics = Double(observation.overallScore + 1) * 50
                stats.aestheticsNote = observation.isUtility ? "系统判为记录用途；评分仅供参考" : "Apple Vision 模型参考分"
            } else { stats.aestheticsNote = "本机审美模型暂不可用" }
        } else {
            let request = VNGenerateImageFeaturePrintRequest()
            request.revision = VNGenerateImageFeaturePrintRequestRevision2
            request.imageCropAndScaleOption = .scaleFit
            if (try? VNImageRequestHandler(cgImage: image).perform([request])) != nil {
                feature = request.results?.first
            }
            stats.aestheticsNote = "审美评分需要 macOS 15 或更新版本"
        }
        let entry = Entry(stats: stats, feature: feature)
        if cache.count >= 100 { cache.removeAll() }
        cache[key] = entry
        return entry
    }
    private func distance(_ first: Any, _ second: Any) throws -> Float {
        if #available(macOS 15.0, *), let first = first as? FeaturePrintObservation, let second = second as? FeaturePrintObservation {
            return Float(try first.distance(to: second))
        }
        guard let first = first as? VNFeaturePrintObservation, let second = second as? VNFeaturePrintObservation else {
            throw LibraryError.message("图像特征版本不一致。")
        }
        var value: Float = 0
        try first.computeDistance(&value, to: second)
        return value
    }
    func compare(_ a: URL, _ b: URL) async throws -> PairAssessment {
        let left = try await analyze(a), right = try await analyze(b)
        var result = PairAssessment(left: left.stats, right: right.stats)
        if let first = left.feature, let second = right.feature {
            do { result.distance = try distance(first, second) }
            catch { result.similarityNote = "相似度分析未完成" }
        } else { result.similarityNote = "本机图像特征模型暂不可用" }
        return result
    }
    func assess(_ url: URL) async throws -> PhotoAssessment { try await analyze(url).stats }
    func compareMany(_ urls: [URL]) async -> GroupAssessment {
        var entries: [Entry?] = [], errors: [String?] = []
        for url in urls {
            do { entries.append(try await analyze(url)); errors.append(nil) }
            catch { entries.append(nil); errors.append(error.localizedDescription) }
        }
        var distances: [AssessmentDistance] = []
        for i in entries.indices {
            for j in entries.indices where j > i {
                if let first = entries[i]?.feature, let second = entries[j]?.feature {
                    do { distances.append(AssessmentDistance(first: i, second: j, value: try distance(first, second))) }
                    catch { /* Other pairs remain usable. */ }
                }
            }
        }
        return GroupAssessment(stats: entries.map { $0?.stats }, errors: errors, distances: distances)
    }
    private func pixelMetrics(_ image: CGImage) -> PhotoAssessment {
        let w = image.width, h = image.height
        guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let data = context.data else { return PhotoAssessment() }
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        var luminance = [Double](repeating: 0, count: w * h)
        var histogram = [Double](repeating: 0, count: 32), dark = 0.0, bright = 0.0, mean = 0.0
        for i in luminance.indices {
            let p = i * 4
            let value = (0.2126 * Double(bytes[p]) + 0.7152 * Double(bytes[p+1]) + 0.0722 * Double(bytes[p+2])) / 255
            luminance[i] = value; mean += value
            histogram[min(31, Int(value * 32))] += 1
            if value < 0.02 { dark += 1 }; if value > 0.98 { bright += 1 }
        }
        var sum = 0.0, square = 0.0, count = 0.0
        if w > 2 && h > 2 {
            for y in 1..<(h-1) { for x in 1..<(w-1) {
                let i = y * w + x
                let laplacian = luminance[i-1] + luminance[i+1] + luminance[i-w] + luminance[i+w] - 4 * luminance[i]
                sum += laplacian; square += laplacian * laplacian; count += 1
            } }
        }
        let pixels = Double(w * h)
        return PhotoAssessment(detailEnergy: count > 0 ? max(0, square / count - pow(sum / count, 2)) * 10000 : 0,
                               darkPercent: dark / pixels * 100, brightPercent: bright / pixels * 100,
                               meanBrightness: mean / pixels * 100, histogram: histogram.map { $0 / pixels })
    }
}
