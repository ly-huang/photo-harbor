import Foundation
import ImageIO
import Dispatch

private final class ViewerMemoryPressureMonitor {
    private let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .global(qos: .utility))
    init(handler: @escaping (DispatchSource.MemoryPressureEvent) -> Void) {
        source.setEventHandler { [weak self] in
            guard let self else { return }
            handler(self.source.data)
        }
        source.resume()
    }
    deinit { source.cancel() }
}

/// Each lane has at most one active decode. Cached reads never wait for either lane.
private actor ViewerRasterDecoder {
    func decode(_ url: URL, availableBytes: Int?) -> CGImage? {
        guard !Task.isCancelled, (availableBytes ?? 1) > 0 else { return nil }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        if let availableBytes {
            // Stop before another full raster is allocated when its dimensions already exceed the budget.
            if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
               let width = properties[kCGImagePropertyPixelWidth as String] as? Double,
               let height = properties[kCGImagePropertyPixelHeight as String] as? Double, width > 0, height > 0 {
                let scale = min(1, 8000 / max(width, height))
                let estimatedBytes = width * height * scale * scale * 4
                if estimatedBytes > Double(availableBytes) { return nil }
            } else if availableBytes <= 0 { return nil }
        }
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 8000,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary), !Task.isCancelled else { return nil }
        return image
    }
}

/// Retains decoded rasters for the active viewer window.
actor ViewerImageCache {
    static let shared = ViewerImageCache()
    private struct Entry {
        let signature: String
        let image: CGImage
        var cost: Int { image.bytesPerRow * image.height }
    }
    private let foregroundDecoder = ViewerRasterDecoder()
    private let backgroundDecoder = ViewerRasterDecoder()
    private let maximumBytes: Int
    private let monitorsPressure: Bool
    private var pressureMonitor: ViewerMemoryPressureMonitor?
    private(set) var budget: Int
    private var pressureIsNormal = true
    private var entries: [URL: Entry] = [:]
    private var priority: [URL] = []
    private(set) var cost = 0

    init(maximumBytes: Int = 1024 * 1024 * 1024, monitorsPressure: Bool = true) {
        self.maximumBytes = max(0, maximumBytes)
        self.budget = max(0, maximumBytes)
        self.monitorsPressure = monitorsPressure
    }

    private func startPressureMonitor() {
        guard monitorsPressure, pressureMonitor == nil else { return }
        pressureMonitor = ViewerMemoryPressureMonitor { [weak self] event in
            Task { await self?.handlePressure(event) }
        }
    }

    func handlePressure(_ event: DispatchSource.MemoryPressureEvent) {
        if event.contains(.critical) { pressureIsNormal = false; budget = 0 }
        else if event.contains(.warning) {
            pressureIsNormal = false
            let reduced = budget / 2
            budget = reduced < 64 * 1024 * 1024 ? 0 : reduced
        } else if event.contains(.normal) {
            pressureIsNormal = true
            // Resume conservatively, then grow on subsequent navigation while pressure stays normal.
            budget = min(maximumBytes, max(64 * 1024 * 1024, budget))
        }
        for url in priority.reversed() where cost > budget { remove(url) }
    }

    static func neighbors(_ urls: [URL], current: URL) -> [URL] {
        guard let index = urls.firstIndex(of: current) else { return [current] }
        var result = [current]
        if urls.count > 1 {
            for distance in 1..<urls.count {
                if index + distance < urls.count { result.append(urls[index + distance]) }
                if index >= distance { result.append(urls[index - distance]) }
            }
        }
        var seen = Set<URL>()
        return result.filter { seen.insert($0).inserted }
    }

    func setWindow(_ urls: [URL]) {
        guard !Task.isCancelled else { return }
        startPressureMonitor()
        if pressureIsNormal && budget < maximumBytes {
            budget = min(maximumBytes, max(64 * 1024 * 1024, budget * 2))
        }
        priority = urls
        // Keep useful entries across small moves, even if a neighbor is still loading.
        // Reclaim the old window immediately on a distant jump.
        let overlaps = urls.prefix(3).contains { entries[$0] != nil }
        let reusable = overlaps ? Set(urls) : []
        for url in Array(entries.keys) where !reusable.contains(url) { remove(url) }
    }

    func clear() {
        priority.removeAll()
        entries.removeAll()
        cost = 0
    }

    private func remove(_ url: URL) {
        if let removed = entries.removeValue(forKey: url) { cost -= removed.cost }
    }

    func decode(_ url: URL, prefetch: Bool = false) async -> CGImage? {
        startPressureMonitor()
        guard !Task.isCancelled, !prefetch || (budget > 0 && priority.contains(url)) else { return nil }
        let freshURL = URL(fileURLWithPath: url.path)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: freshURL.path) else { remove(url); return nil }
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let signature = "\(attributes[.systemNumber] ?? ""):\(attributes[.systemFileNumber] ?? ""):\(attributes[.size] ?? ""):\(modified)"
        if let cached = entries[url], cached.signature == signature { return cached.image }
        remove(url)
        let availableBytes = prefetch ? budget - priority.prefix { $0 != url }.reduce(0) { $0 + (entries[$1]?.cost ?? 0) } : nil
        let decoder = prefetch ? backgroundDecoder : foregroundDecoder
        guard let image = await decoder.decode(freshURL, availableBytes: availableBytes), !Task.isCancelled else { return nil }
        if let cached = entries[url] {
            // Another decode may have cached a newer version while this one was suspended.
            return cached.signature == signature ? cached.image : (prefetch ? nil : image)
        }
        if prefetch && !priority.contains(url) { return nil }
        let entry = Entry(signature: signature, image: image)
        if let rank = priority.firstIndex(of: url), entry.cost <= budget {
            // Keep nearer photos before farther photos, rather than churning the useful cache.
            for candidate in priority.dropFirst(rank + 1).reversed() {
                if cost + entry.cost <= budget { break }
                remove(candidate)
            }
            if cost + entry.cost <= budget {
                entries[url] = entry
                cost += entry.cost
            }
        }
        return prefetch && entries[url] == nil ? nil : image
    }
}
