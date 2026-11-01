import AppKit
import ImageIO
import UniformTypeIdentifiers

// Synthetic, local images solely for UI validation; never shipped as library content.
let base = URL(fileURLWithPath: CommandLine.arguments[1])
let jpg = base.appendingPathComponent("jpg/2026/2026-10-31_界面测试")
let raw = base.appendingPathComponent("raw/2026/2026-10-31_界面测试")
for folder in [jpg, raw] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
for index in 1...8 {
    let image = NSImage(size: NSSize(width: 1200, height: 800))
    image.lockFocus()
    let sky = NSColor(calibratedHue: CGFloat(index) * 0.025 + 0.5, saturation: 0.30, brightness: 0.7, alpha: 1)
    sky.setFill(); NSBezierPath(rect: NSRect(x: 0, y: 0, width: 1200, height: 800)).fill()
    NSColor(calibratedRed: 0.8, green: 0.83, blue: 0.72, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: 700 - index * 40, y: 490, width: 130, height: 130)).fill()
    for layer in 0...2 {
        NSColor(calibratedHue: 0.5 + CGFloat(index) * 0.015, saturation: 0.35, brightness: 0.28 + CGFloat(layer) * 0.10, alpha: 1).setFill()
        let p = NSBezierPath(); p.move(to: NSPoint(x: 0, y: 0)); p.line(to: NSPoint(x: 0, y: 300 - layer * 60))
        p.line(to: NSPoint(x: 240 + index * 40, y: 540 - layer * 120)); p.line(to: NSPoint(x: 600, y: 240 - layer * 60)); p.line(to: NSPoint(x: 990, y: 460 - layer * 90)); p.line(to: NSPoint(x: 1200, y: 290)); p.line(to: NSPoint(x: 1200, y: 0)); p.close(); p.fill()
    }
    image.unlockFocus()
    let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
    let filename = String(format: "DSC%05d", index)
    try rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85])!.write(to: jpg.appendingPathComponent(filename + ".JPG"))
    if index < 7 { try Data("synthetic RAW placeholder".utf8).write(to: raw.appendingPathComponent(filename + ".ARW")) }
}
let state: [String: Any] = ["roots": ["jpg": base.appendingPathComponent("jpg").path, "raw": base.appendingPathComponent("raw").path], "rejected": [], "trash": []]
try JSONSerialization.data(withJSONObject: state).write(to: base.appendingPathComponent("state.json"))
print("Created isolated UI fixtures at \(base.path)")
