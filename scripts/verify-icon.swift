import AppKit
import ImageIO

let urls = CommandLine.arguments.dropFirst().map { URL(fileURLWithPath: $0) }
precondition(urls.count == 3)
for (index, url) in urls.enumerated() {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { fatalError("Icon source cannot be decoded") }
    let images = (0..<CGImageSourceGetCount(source)).compactMap { CGImageSourceCreateImageAtIndex(source, $0, nil) }
    guard let image = images.max(by: { $0.width < $1.width }), image.width == 1024, image.height == 1024 else { fatalError("Icon must contain a 1024px master") }
    let rep = NSBitmapImageRep(cgImage: image)
    for (x, y) in [(0, 0), (1023, 0), (0, 1023), (1023, 1023)] { precondition((rep.colorAt(x: x, y: y)?.alphaComponent ?? 1) < 0.01, "Icon corners must remain transparent") }
    precondition((rep.colorAt(x: 512, y: 512)?.alphaComponent ?? 0) > 0.99)
    if index > 0 { precondition((rep.colorAt(x: 41, y: 512)?.alphaComponent ?? 1) < 0.01, "Packaged icon must keep standard optical margins") }
}
print("PASS approved master, prepared PNG and packaged ICNS retain transparent corners")
