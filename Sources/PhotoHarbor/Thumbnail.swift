import SwiftUI
import ImageIO

final class ImageCache: @unchecked Sendable {
    static let shared: ImageCache = {
        let instance = ImageCache()
        instance.setLimit(UserDefaults.standard.object(forKey: "photo.thumbnailMiB") as? Int ?? 512)
        return instance
    }()
    let cache = NSCache<NSString, NSImage>()
    let queue = OperationQueue()
    init() { cache.totalCostLimit = 512 * 1024 * 1024; queue.maxConcurrentOperationCount = 3 }
    func setLimit(_ mib: Int) {
        // NSCache treats a zero limit as unlimited.
        cache.totalCostLimit = max(1, mib * 1024 * 1024)
        cache.removeAllObjects()
    }
    private final class DecodeResult: @unchecked Sendable {
        // The operation writes this before its completion block reads it.
        var image: NSImage?
    }

    func load(_ file: PhotoFile, size: Int, priority: Operation.QueuePriority = .normal) async -> NSImage? {
        guard !Task.isCancelled else { return nil }
        let url = file.url
        let key = "\(url.path):\(size):\(file.identity):\(file.bytes):\(file.modified.timeIntervalSince1970)"
        if let cached = cache.object(forKey: key as NSString) { return cached }
        let operation = BlockOperation()
        operation.queuePriority = priority
        let result = DecodeResult()
        operation.addExecutionBlock { [weak operation] in
            guard operation?.isCancelled == false else { return }
            result.image = autoreleasepool {
                if let cached = self.cache.object(forKey: key as NSString) { return cached }
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: size] as CFDictionary) else { return nil }
                let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                if self.cache.totalCostLimit > 1 {
                    self.cache.setObject(image, forKey: key as NSString, cost: cg.bytesPerRow * cg.height)
                }
                return image
            }
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                operation.completionBlock = { continuation.resume(returning: result.image) }
                queue.addOperation(operation)
            }
        } onCancel: {
            operation.cancel()
        }
    }
}
struct PhotoImage: View {
    let file: PhotoFile
    var size = 600
    var priority: Operation.QueuePriority = .normal
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
        .task(id: "\(file.url.path):\(size):\(file.identity):\(file.bytes):\(file.modified.timeIntervalSince1970)") {
            image = nil; loading = true
            let loaded = await ImageCache.shared.load(file, size: size, priority: priority)
            guard !Task.isCancelled else { return }
            image = loaded; loading = false
        }
        .accessibilityLabel(file.url.lastPathComponent)
    }
}
