import Foundation

// Shape-preserving cubic interpolation, sampled into CIColorCurves' RGB table.
enum ChannelCurves {
    static let identity = [CGPoint(x: 0, y: 0), CGPoint(x: 0.25, y: 0.25), CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.75, y: 0.75), CGPoint(x: 1, y: 1)]
    static func value(_ x: Double, points: [CGPoint]) -> Double {
        guard points.count >= 2 else { return x }
        if x <= points[0].x { return points[0].y }
        if x >= points.last!.x { return points.last!.y }
        let slopes = (0..<points.count - 1).map { i in (points[i + 1].y - points[i].y) / max(0.000001, points[i + 1].x - points[i].x) }
        func tangent(_ i: Int) -> Double {
            if i == 0 { return slopes[0] }
            if i == points.count - 1 { return slopes.last! }
            let a = slopes[i - 1], b = slopes[i]
            guard a * b > 0 else { return 0 }
            let h0 = points[i].x - points[i - 1].x, h1 = points[i + 1].x - points[i].x
            let w0 = 2 * h1 + h0, w1 = h1 + 2 * h0
            return (w0 + w1) / (w0 / a + w1 / b)
        }
        let i = (0..<points.count - 1).first { x <= points[$0 + 1].x }!
        let h = points[i + 1].x - points[i].x, t = (x - points[i].x) / max(0.000001, h)
        let y = (2 * t * t * t - 3 * t * t + 1) * points[i].y + (t * t * t - 2 * t * t + t) * h * tangent(i) + (-2 * t * t * t + 3 * t * t) * points[i + 1].y + (t * t * t - t * t) * h * tangent(i + 1)
        return min(1, max(0, y))
    }
    static func table(_ channels: [[CGPoint]], samples: Int = 1024) -> Data {
        var values: [Float] = []; values.reserveCapacity(samples * 3)
        for i in 0..<samples { for channel in 0..<3 { values.append(Float(value(Double(i) / Double(samples - 1), points: channels[channel]))) } }
        return values.withUnsafeBytes { Data($0) }
    }
}

// Curve editing is independent of the native five-point enhancement recipe.
enum CurveEditing {
    static let limit=32
    static func inserting(_ point:CGPoint,in points:[CGPoint])->(points:[CGPoint],index:Int) {
        let p=CGPoint(x:min(1,max(0,point.x)),y:min(1,max(0,point.y)))
        var result=points
        if let nearest=result.indices.min(by:{abs(result[$0].x-p.x)<abs(result[$1].x-p.x)}),abs(result[nearest].x-p.x)<0.005 {
            result[nearest].y=p.y;return(result,nearest)
        }
        guard result.count<limit else{return(result,result.indices.min(by:{abs(result[$0].x-p.x)<abs(result[$1].x-p.x)}) ?? 0)}
        let index=result.firstIndex{$0.x>p.x} ?? result.count;result.insert(p,at:index);return(result,index)
    }
}
