import Foundation
import CoreGraphics

@main struct ViewportTests {
    static func near(_ a: CGFloat, _ b: CGFloat) { precondition(abs(a - b) < 0.000001, "\(a) differs from \(b)") }
    static func main() {
        let viewport = CGSize(width: 1000, height: 800)
        let fit = CGSize(width: 1000, height: 500)
        let entire = ViewerGeometry.visibleRegion(viewport: viewport, fitSize: fit, zoom: 1, offset: .zero)
        precondition(entire == CGRect(x: 0, y: 0, width: 1, height: 1))
        print("PASS letterboxed fit shows the whole image in navigator")

        let point = CGPoint(x: 0.7, y: 0.3)
        let offset = ViewerGeometry.offsetForCenter(point, fitSize: fit, zoom: 4)
        let region = ViewerGeometry.visibleRegion(viewport: viewport, fitSize: fit, zoom: 4, offset: offset)
        near(region.midX, point.x); near(region.midY, point.y)
        near(region.width, 0.25); near(region.height, 0.4)
        print("PASS navigator click centers the image on the requested location")

        let anchor = CGPoint(x: 200, y: 300), originalOffset = CGPoint(x: -120, y: 80)
        let oldRect = ViewerGeometry.imageRect(viewport: viewport, fitSize: fit, zoom: 2, offset: originalOffset)
        let newOffset = ViewerGeometry.zoomOffset(offset: originalOffset, anchor: anchor, viewport: viewport, ratio: 1.5)
        let newRect = ViewerGeometry.imageRect(viewport: viewport, fitSize: fit, zoom: 3, offset: newOffset)
        near((anchor.x - oldRect.minX) / oldRect.width, (anchor.x - newRect.minX) / newRect.width)
        near((anchor.y - oldRect.minY) / oldRect.height, (anchor.y - newRect.minY) / newRect.height)
        print("PASS pointer stays on the same image pixel while zooming")
    }
}
