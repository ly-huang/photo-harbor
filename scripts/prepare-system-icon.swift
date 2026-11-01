import AppKit
import ImageIO

// Normalize the approved raster to the full-bleed square expected by current
// macOS. The OS supplies the rounded mask; a pre-inset translucent tile is
// treated as foreground artwork and receives a second background.
let sourceURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])
let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil)!
let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
precondition(image.width == 1024 && image.height == 1024)
let context = CGContext(data: nil, width: 1024, height: 1024,
                        bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
context.setFillColor(CGColor(srgbRed: 0.985, green: 0.985, blue: 0.985, alpha: 1))
context.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
context.interpolationQuality = .high
// Explicit plate bounds are measured per approved artwork, excluding outer padding.
let values = CommandLine.arguments.dropFirst(3).compactMap(Double.init)
precondition(values.count == 4, "Provide plate bounds: x y width height")
let bounds = CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
precondition(CGRect(x: 0, y: 0, width: 1024, height: 1024).contains(bounds))
let tile = image.cropping(to: bounds)!
context.draw(tile, in: CGRect(x: 0, y: 0, width: 1024, height: 1024))
let rep = NSBitmapImageRep(cgImage: context.makeImage()!)
try rep.representation(using: .png, properties: [:])!.write(to: outputURL)
print("Prepared full-bleed system master:", outputURL.path)
