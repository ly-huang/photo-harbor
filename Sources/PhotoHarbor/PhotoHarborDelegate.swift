import AppKit

@MainActor final class PhotoHarborDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Use the icon resolved from the signed bundle by the system.
        NSApp.setActivationPolicy(.regular)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
        writeIconReportIfRequested()
    }

    // Opt-in integration diagnostics read the actual AppKit image; no screen capture.
    private func writeIconReportIfRequested() {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: "--icon-report"), arguments.indices.contains(flag + 1) else { return }
        let folder = URL(fileURLWithPath: arguments[flag + 1], isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let runtimeIcon = NSApp.applicationIconImage
            let data = runtimeIcon?.tiffRepresentation
            let rep = data.flatMap(NSBitmapImageRep.init(data:))
            if let png = rep?.representation(using: .png, properties: [:]) {
                try png.write(to: folder.appendingPathComponent("runtime-dock-icon.png"), options: .atomic)
            }
            let report: [String: Any] = [
                "bundleIdentifier": Bundle.main.bundleIdentifier ?? "",
                "bundlePath": Bundle.main.bundlePath,
                "configuredIcon": Bundle.main.object(forInfoDictionaryKey: "CFBundleIconFile") as? String ?? "",
                "foregroundApp": NSApp.activationPolicy() == .regular,
                "runtimeIconValid": runtimeIcon?.isValid ?? false,
                "runtimePixelWidth": rep?.pixelsWide ?? 0,
                "runtimePixelHeight": rep?.pixelsHigh ?? 0,
                "centerAlpha": rep?.colorAt(x: (rep?.pixelsWide ?? 0) / 2, y: (rep?.pixelsHigh ?? 0) / 2)?.alphaComponent ?? 0,
                "dockTileWidth": NSApp.dockTile.size.width,
                "dockTileHeight": NSApp.dockTile.size.height
            ]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: folder.appendingPathComponent("icon-report.json"), options: .atomic)
        } catch { NSLog("PhotoHarbor icon diagnostics: %@", error.localizedDescription) }
    }
}
