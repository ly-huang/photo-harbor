import AppKit
import ImageIO

// Preserve the approved raster, including its transparent rounded corners.
// ICNS must not flatten those corners onto an opaque square.
let sourceURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])
let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil)!
let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
precondition(image.width == 1024 && image.height == 1024)
let context = CGContext(data: nil, width: 1024, height: 1024,
                        bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
context.clear(CGRect(x: 0, y: 0, width: 1024, height: 1024))
context.interpolationQuality = .high
// Explicit plate bounds are measured per approved artwork, excluding outer padding.
let values = CommandLine.arguments.dropFirst(3).compactMap(Double.init)
precondition(values.count == 4, "Provide plate bounds: x y width height")
let bounds = CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
precondition(CGRect(x: 0, y: 0, width: 1024, height: 1024).contains(bounds))
let tile = image.cropping(to: bounds)!
// Match the visual footprint of standard macOS icons, with transparent optical margins.
context.draw(tile, in: CGRect(x: 82, y: 82, width: 860, height: 860))
let rep = NSBitmapImageRep(cgImage: context.makeImage()!)
try rep.representation(using: .png, properties: [:])!.write(to: outputURL)
print("Prepared optically inset transparent master:", outputURL.path)
