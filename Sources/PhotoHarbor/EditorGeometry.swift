import Foundation

// Crop coordinates use the oriented image, with origin at its top-left.
enum EditorGeometry {
    static let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
    static func valid(_ rect: CGRect) -> CGRect? {
        guard [rect.minX, rect.minY, rect.width, rect.height].allSatisfy({ $0.isFinite }), rect.width > 0, rect.height > 0 else { return nil }
        let clipped = rect.intersection(unit)
        return clipped.width >= 0.01 && clipped.height >= 0.01 ? clipped : nil
    }
    static func pixels(_ selection: CGRect, in extent: CGRect) -> CGRect {
        guard let r = valid(selection) else { return extent }
        // Round inward to keep the saved output inside the selected source pixels.
        let x0 = ceil(extent.minX + r.minX * extent.width), x1 = floor(extent.minX + r.maxX * extent.width)
        let y0 = ceil(extent.minY + (1 - r.maxY) * extent.height), y1 = floor(extent.minY + (1 - r.minY) * extent.height)
        return CGRect(x: x0, y: y0, width: max(1, x1 - x0), height: max(1, y1 - y0)).intersection(extent)
    }
    static func straightenCrop(size: CGSize, degrees: Double) -> CGRect {
        let radians = degrees * .pi / 180, c = abs(cos(radians)), s = abs(sin(radians))
        let scale = min(size.width / max(1, size.width * c + size.height * s), size.height / max(1, size.width * s + size.height * c))
        let width = floor(size.width * scale), height = floor(size.height * scale)
        return CGRect(x: ceil((size.width - width) / 2), y: ceil((size.height - height) / 2), width: max(1, width - 1), height: max(1, height - 1))
    }
    static func aspectFit(_ selection: CGRect, normalizedAspect: CGFloat) -> CGRect {
        let r = valid(selection) ?? unit, ratio = max(0.001, normalizedAspect)
        let width = min(r.width, r.height * ratio), height = width / ratio
        return CGRect(x: r.midX - width / 2, y: r.midY - height / 2, width: width, height: height)
    }
    static func drag(anchor: CGPoint, to point: CGPoint, normalizedAspect: CGFloat?) -> CGRect {
        let dx = point.x - anchor.x, dy = point.y - anchor.y
        guard let ratio = normalizedAspect, ratio > 0 else { return CGRect(x: min(anchor.x, point.x), y: min(anchor.y, point.y), width: abs(dx), height: abs(dy)) }
        let maxX = dx >= 0 ? 1 - anchor.x : anchor.x, maxY = dy >= 0 ? 1 - anchor.y : anchor.y
        let width = min(max(abs(dx), abs(dy) * ratio), maxX, maxY * ratio), height = width / ratio
        return CGRect(x: dx >= 0 ? anchor.x : anchor.x - width, y: dy >= 0 ? anchor.y : anchor.y - height, width: width, height: height)
    }
    // Edges: top, right, bottom, left. The opposite edge stays anchored.
    static func dragEdge(_ edge: Int, initial r: CGRect, to p: CGPoint, normalizedAspect ratio: CGFloat?) -> CGRect {
        let horizontal=edge==1 || edge==3
        var width=r.width,height=r.height
        if horizontal { width=max(0.01,edge==1 ? min(1,p.x)-r.minX:r.maxX-max(0,p.x)) }
        else { height=max(0.01,edge==2 ? min(1,p.y)-r.minY:r.maxY-max(0,p.y)) }
        if let ratio,ratio>0 {
            if horizontal { width=min(width,2*min(r.midY,1-r.midY)*ratio);height=width/ratio }
            else { height=min(height,2*min(r.midX,1-r.midX)/ratio);width=height*ratio }
        }
        let x=edge==1 ? r.minX:(edge==3 ? r.maxX-width:r.midX-width/2)
        let y=edge==2 ? r.minY:(edge==0 ? r.maxY-height:r.midY-height/2)
        return CGRect(x:x,y:y,width:width,height:height).intersection(unit)
    }
    static func recommendation(subject: CGRect?, size: CGSize) -> CGRect {
        let subject = subject.flatMap(valid) ?? CGRect(x: 0.35, y: 0.35, width: 0.3, height: 0.3)
        // Preserve a margin around detected subjects; use a mild crop when none is found.
        let margin: CGFloat = 0.10
        var width = min(1, max(0.72, subject.width + margin * 2))
        var height = min(1, max(0.72, subject.height + margin * 2))
        let ratio: CGFloat = size.width >= size.height ? 1.5 : 2 / 3
        let imageRatio = max(0.001, size.width / max(1, size.height))
        if width * imageRatio / height > ratio { height = min(1, width * imageRatio / ratio) }
        else { width = min(1, height * ratio / imageRatio) }
        // Keep the entire salient region, preferring a third for off-centre subjects.
        let thirdX: CGFloat = subject.midX < 0.45 ? 1 / 3 : (subject.midX > 0.55 ? 2 / 3 : 0.5)
        let x = min(max(0, subject.midX - width * thirdX), 1 - width)
        let y = min(max(0, subject.midY - height * 0.45), 1 - height)
        let candidate = CGRect(x: x, y: y, width: width, height: height)
        return candidate.contains(subject) ? candidate : candidate.union(subject).intersection(unit)
    }
}
