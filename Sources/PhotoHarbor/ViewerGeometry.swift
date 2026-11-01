import Foundation
import CoreGraphics

// All coordinates use the image's top-left origin; geometry is shared by the
// main image and navigator so click/drag positions remain consistent on resize.
enum ViewerGeometry {
    static func imageRect(viewport: CGSize, fitSize: CGSize, zoom: CGFloat, offset: CGPoint) -> CGRect {
        CGRect(x: viewport.width / 2 + offset.x - fitSize.width * zoom / 2,
               y: viewport.height / 2 + offset.y - fitSize.height * zoom / 2,
               width: fitSize.width * zoom, height: fitSize.height * zoom)
    }
    static func visibleRegion(viewport: CGSize, fitSize: CGSize, zoom: CGFloat, offset: CGPoint) -> CGRect {
        let image = imageRect(viewport: viewport, fitSize: fitSize, zoom: zoom, offset: offset)
        guard image.width > 0, image.height > 0 else { return .zero }
        let visible = image.intersection(CGRect(origin: .zero, size: viewport))
        guard !visible.isNull else { return .zero }
        return CGRect(x: (visible.minX - image.minX) / image.width, y: (visible.minY - image.minY) / image.height,
                      width: visible.width / image.width, height: visible.height / image.height)
    }
    static func offsetForCenter(_ center: CGPoint, fitSize: CGSize, zoom: CGFloat) -> CGPoint {
        CGPoint(x: (0.5 - min(1, max(0, center.x))) * fitSize.width * zoom,
                y: (0.5 - min(1, max(0, center.y))) * fitSize.height * zoom)
    }
    static func zoomOffset(offset: CGPoint, anchor: CGPoint, viewport: CGSize, ratio: CGFloat) -> CGPoint {
        CGPoint(x: anchor.x - viewport.width / 2 - (anchor.x - viewport.width / 2 - offset.x) * ratio,
                y: anchor.y - viewport.height / 2 - (anchor.y - viewport.height / 2 - offset.y) * ratio)
    }
}
