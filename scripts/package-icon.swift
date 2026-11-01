import AppKit
import ImageIO

// Package an approved raster master without redrawing or recoloring its contents.
let master = URL(fileURLWithPath: CommandLine.arguments[1])
let folder = URL(fileURLWithPath: CommandLine.arguments[2])
let output = URL(fileURLWithPath: CommandLine.arguments[3])
let source = CGImageSourceCreateWithURL(master as CFURL, nil)!
let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
precondition(image.width == 1024 && image.height == 1024)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
let names = [16: ["icon_16x16"], 32: ["icon_16x16@2x", "icon_32x32"], 64: ["icon_32x32@2x"], 128: ["icon_128x128"], 256: ["icon_128x128@2x", "icon_256x256"], 512: ["icon_256x256@2x", "icon_512x512"], 1024: ["icon_512x512@2x"]]
for size in names.keys.sorted() {
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
    let rep = NSBitmapImageRep(cgImage: context.makeImage()!)
    let png = size == 1024 ? try Data(contentsOf: master) : rep.representation(using: .png, properties: [:])!
    for name in names[size]! { try png.write(to: folder.appendingPathComponent(name + ".png")) }
}
// Use Apple's compiler, including its legacy-size encodings and metadata.
// ImageIO decoding alone does not validate all system icon consumers.
let compiler = Process()
compiler.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
compiler.arguments = ["-c", "icns", folder.path, "-o", output.path]
try compiler.run(); compiler.waitUntilExit()
guard compiler.terminationStatus == 0 else {
    throw NSError(domain: "PhotoHarbor.IconPackaging", code: Int(compiler.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "macOS iconutil failed. Run the build in a normal macOS terminal with IconServices access."])
}
print("Packaged approved icon: \(output.path)")
