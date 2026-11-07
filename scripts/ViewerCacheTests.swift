import Foundation
import ImageIO
import CoreGraphics

@main struct ViewerCacheTests {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let context = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 256,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.3, green: 0.6, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        let raster = context.makeImage()!
        let urls = (0..<25).map { root.appendingPathComponent("\($0).png") }
        for url in urls {
            let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, raster, nil)
            precondition(CGImageDestinationFinalize(destination))
        }
        let order = ViewerImageCache.neighbors(urls, current: urls[12])
        precondition(order.count == 25 && Array(order.prefix(5)) == [urls[12], urls[13], urls[11], urls[14], urls[10]])
        let cache = ViewerImageCache(maximumBytes: 1024 * 1024, monitorsPressure: false)
        await cache.setWindow(order)
        for url in order {
            let image = await cache.decode(url, prefetch: true)
            precondition(image != nil)
        }
        let first = await cache.decode(urls[12])!
        let second = await cache.decode(urls[12])!
        precondition(first === second)
        let small = ViewerImageCache(maximumBytes: first.bytesPerRow * first.height * 2, monitorsPressure: false)
        await small.setWindow(order)
        var loaded = 0
        for url in order {
            guard await small.decode(url, prefetch: true) != nil else { break }
            loaded += 1
        }
        precondition(loaded == 2)
        let cost = await small.cost
        precondition(cost <= first.bytesPerRow * first.height * 2)
        // Moving to the edge of the cache creates a gap ahead, but must retain the previous photo.
        let adjacent = ViewerImageCache.neighbors(urls, current: urls[13])
        let previous = await small.decode(urls[12])!
        await small.setWindow(adjacent)
        let retained = await small.decode(urls[12])!
        precondition(retained === previous)
        let moved = ViewerImageCache.neighbors(urls, current: urls[0])
        await small.setWindow(moved)
        let jumpedCost = await small.cost
        precondition(jumpedCost == 0)
        let movedImage = await small.decode(urls[0], prefetch: true)
        precondition(movedImage != nil)
        var refilled = 1
        for url in moved.dropFirst() {
            guard await small.decode(url, prefetch: true) != nil else { break }
            refilled += 1
        }
        precondition(refilled == 2)
        await small.setWindow([urls[24]])
        let switchedCost = await small.cost
        precondition(switchedCost == 0)
        let switchedImage = await small.decode(urls[24], prefetch: true)
        precondition(switchedImage != nil)
        let changed = urls[12]
        try Data("invalid image".utf8).write(to: changed, options: .atomic)
        let changedImage = await cache.decode(changed)
        precondition(changedImage == nil)
        await small.handlePressure(.critical)
        let criticalCost = await small.cost
        let criticalBudget = await small.budget
        precondition(criticalCost == 0 && criticalBudget == 0)
        let noPrefetch = await small.decode(urls[24], prefetch: true)
        precondition(noPrefetch == nil)
        let foreground = await small.decode(urls[24])
        precondition(foreground != nil)
        let foregroundCost = await small.cost
        precondition(foregroundCost == 0)
        let adaptive = ViewerImageCache(monitorsPressure: false)
        for expected in [512, 256, 128, 64, 0] {
            await adaptive.handlePressure(.warning)
            let budget = await adaptive.budget
            precondition(budget == expected * 1024 * 1024)
        }
        await adaptive.handlePressure(.normal)
        let recovered = await adaptive.budget
        precondition(recovered == 64 * 1024 * 1024)
        await adaptive.setWindow(order)
        let grown = await adaptive.budget
        precondition(grown == 128 * 1024 * 1024)
        await cache.clear()
        let clearedCost = await cache.cost
        precondition(clearedCost == 0)
        print("PASS viewer cache has no count cap, reuses rasters, obeys byte budget, slides, invalidates changed files and clears")
        print("PASS memory warning halves budget to zero, critical clears and pauses prefetch, foreground remains available and recovery is gradual")
    }
}
