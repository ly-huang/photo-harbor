import AppKit

extension PhotoCanvas {
    var editingCursor: NSCursor { (cropActive || brushTool != nil) ? .crosshair : (rotationActive ? .arrow : (isComparing ? .resizeLeftRight : .arrow)) }
    func drawEditing(in imageRect: CGRect) {
        if isComparing, let comparisonImage {
            let visible = imageRect.intersection(bounds)
            let x = min(max(comparisonX ?? bounds.midX, visible.minX), visible.maxX)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: CGRect(x: 0, y: 0, width: x, height: bounds.height)).addClip()
            comparisonImage.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
            NSGraphicsContext.restoreGraphicsState()
            NSColor.white.setStroke(); let path = NSBezierPath(); path.move(to: NSPoint(x: x, y: max(0, imageRect.minY))); path.line(to: NSPoint(x: x, y: min(bounds.height, imageRect.maxY))); path.lineWidth = 1.5; path.stroke()
            let labels: [(String, CGPoint)] = [
                ("编辑前", CGPoint(x: visible.minX + 10, y: visible.minY + 12)),
                ("编辑后", CGPoint(x: visible.maxX - 58, y: visible.minY + 12))
            ]
            for (index, pair) in labels.enumerated() {
                let (label, point) = pair
                guard (index == 0 ? x - visible.minX : visible.maxX - x) >= 72 else { continue }
                let bg = CGRect(x: point.x - 5, y: point.y - 3, width: 53, height: 23)
                NSColor.black.withAlphaComponent(0.65).setFill(); NSBezierPath(roundedRect: bg, xRadius: 6, yRadius: 6).fill()
                (label as NSString).draw(at: point, withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.white])
            }

        }
        if rotationActive {
            let grid = NSBezierPath(); grid.lineWidth = 0.5; NSColor.white.withAlphaComponent(0.45).setStroke()
            for i in 1...2 {
                let x = imageRect.minX + imageRect.width * CGFloat(i) / 3, y = imageRect.minY + imageRect.height * CGFloat(i) / 3
                grid.move(to: CGPoint(x: x, y: imageRect.minY)); grid.line(to: CGPoint(x: x, y: imageRect.maxY))
                grid.move(to: CGPoint(x: imageRect.minX, y: y)); grid.line(to: CGPoint(x: imageRect.maxX, y: y))
            }
            grid.stroke()
        }
        if brushTool != nil,let point=brushPoint {
            let diameter=brushDiameter*min(imageRect.width,imageRect.height),circle=NSBezierPath(ovalIn:CGRect(x:point.x-diameter/2,y:point.y-diameter/2,width:diameter,height:diameter))
            NSColor.black.withAlphaComponent(0.6).setStroke();circle.lineWidth=3;circle.stroke();NSColor.white.setStroke();circle.lineWidth=1;circle.stroke()
        }
        guard cropActive else { return }
        let selection = cropSelection ?? CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
        let rect = cropDisplayRect(selection, imageRect)
        let shade = NSBezierPath(rect: bounds); shade.append(NSBezierPath(rect: rect)); shade.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.55).setFill(); shade.fill()
        NSColor.white.setStroke(); let outline = NSBezierPath(rect: rect); outline.lineWidth = 1.5; outline.stroke()
        let grid = NSBezierPath(); grid.lineWidth = 0.5
        for i in 1...2 {
            let x = rect.minX + rect.width * CGFloat(i) / 3, y = rect.minY + rect.height * CGFloat(i) / 3
            grid.move(to: NSPoint(x: x, y: rect.minY)); grid.line(to: NSPoint(x: x, y: rect.maxY))
            grid.move(to: NSPoint(x: rect.minX, y: y)); grid.line(to: NSPoint(x: rect.maxX, y: y))
        }
        grid.stroke(); NSColor.white.setFill()
        for point in cropCorners(rect) + cropEdges(rect) { NSBezierPath(roundedRect: CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8), xRadius: 2, yRadius: 2).fill() }
    }
    private func cropEdges(_ r: CGRect) -> [CGPoint] { [CGPoint(x:r.midX,y:r.minY),CGPoint(x:r.maxX,y:r.midY),CGPoint(x:r.midX,y:r.maxY),CGPoint(x:r.minX,y:r.midY)] }
    private func cropCorners(_ r: CGRect) -> [CGPoint] { [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)] }
    private func cropDisplayRect(_ r: CGRect, _ image: CGRect) -> CGRect { CGRect(x: image.minX + r.minX * image.width, y: image.minY + r.minY * image.height, width: r.width * image.width, height: r.height * image.height) }
    private func normalized(_ point: CGPoint) -> CGPoint {
        let r = editingImageRect
        return CGPoint(x: min(1, max(0, (point.x - r.minX) / max(1, r.width))), y: min(1, max(0, (point.y - r.minY) / max(1, r.height))))
    }
    func beginCrop(at point: CGPoint) {
        cropStart = normalized(point); cropInitial = cropSelection ?? CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
        let display = cropDisplayRect(cropInitial, editingImageRect)
        if let corner = cropCorners(display).firstIndex(where: { hypot($0.x - point.x, $0.y - point.y) < 14 }) { cropDragMode = corner }
        else if let edge = cropEdges(display).firstIndex(where: { hypot($0.x-point.x,$0.y-point.y)<14 }) { cropDragMode=6+edge }
        else { cropDragMode = display.contains(point) ? 4 : 5 }
        if cropDragMode == 5 { cropSelection = CGRect(origin: cropStart, size: .zero) }
        needsDisplay = true
    }
    func dragCrop(to point: CGPoint) {
        let p = normalized(point), initial = cropInitial
        if cropDragMode == 4 {
            cropSelection = CGRect(x: min(1 - initial.width, max(0, initial.minX + p.x - cropStart.x)), y: min(1 - initial.height, max(0, initial.minY + p.y - cropStart.y)), width: initial.width, height: initial.height)
        } else if cropDragMode >= 6 {
            cropSelection=EditorGeometry.dragEdge(cropDragMode-6, initial:initial, to:p, normalizedAspect:cropAspect)
        } else {
            let opposite = cropDragMode < 4 ? cropCorners(initial)[(cropDragMode + 2) % 4] : cropStart
            cropSelection = EditorGeometry.drag(anchor: opposite, to: p, normalizedAspect: cropAspect)
        }
        needsDisplay = true
    }
    func finishCrop() {
        if let selection = cropSelection, let valid = EditorGeometry.valid(selection) { cropSelection = valid; cropChanged?(valid) }
        else { cropSelection = cropInitial }
        needsDisplay = true
    }
}
