import SwiftUI
import ImageIO

final class ImageCache: @unchecked Sendable {
    static let shared = ImageCache()
    let cache = NSCache<NSString, NSImage>()
    let queue = OperationQueue()
    init() { cache.totalCostLimit = 512 * 1024 * 1024; queue.maxConcurrentOperationCount = 3 }
    func load(_ url: URL, size: Int) async -> NSImage? {
        let stamp = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970 ?? 0
        let key = "\(url.path):\(size):\(stamp)"
        if let cached = cache.object(forKey: key as NSString) { return cached }
        return await withCheckedContinuation { continuation in
            queue.addOperation {
                let result: NSImage? = autoreleasepool {
                    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: size] as CFDictionary) else { return nil }
                    let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                    self.cache.setObject(image, forKey: key as NSString, cost: cg.bytesPerRow * cg.height)
                    return image
                }
                continuation.resume(returning: result)
            }
        }
    }
}
struct PhotoImage: View {
    let url: URL
    var size = 600
    @ViewState private var image: NSImage?
    @ViewState private var loading = true
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.opacity(0.22)
                if let image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).frame(width: geometry.size.width, height: geometry.size.height)
                } else if loading { ProgressView().controlSize(.small) }
                else { VStack(spacing: 8) { Image(systemName: "photo.badge.exclamationmark"); Text("无法预览 · 可在 Finder 查看").font(.caption) }.foregroundStyle(.secondary) }
            }
        }
        .task(id: "\(url.path)-\(size)-\((try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970 ?? 0)") {
            image = nil; loading = true
            let loaded = await ImageCache.shared.load(url, size: size)
            guard !Task.isCancelled else { return }
            image = loaded; loading = false
        }
        .accessibilityLabel(url.lastPathComponent)
    }
}
