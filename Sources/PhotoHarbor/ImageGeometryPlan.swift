import CoreImage
import simd

struct ImageGeometryPlan {
    enum Step { case affine(CGAffineTransform), crop(CGRect), perspective([CGPoint]) }
    var steps: [Step] = []
    var size: CGSize
    let originalSize: CGSize
    private var forward = matrix_identity_double3x3
    init(size: CGSize, adjustments a: PhotoAdjustments) {
        self.size=size; originalSize=size
        let w=size.width,h=size.height
        switch a.rotation % 4 {
        case 1: affine(CGAffineTransform(a:0,b:-1,c:1,d:0,tx:0,ty:w)); self.size=CGSize(width:h,height:w)
        case 2: affine(CGAffineTransform(a:-1,b:0,c:0,d:-1,tx:w,ty:h))
        case 3: affine(CGAffineTransform(a:0,b:1,c:-1,d:0,tx:h,ty:0)); self.size=CGSize(width:h,height:w)
        default: break
        }
        if a.flipHorizontal { affine(CGAffineTransform(a:-1,b:0,c:0,d:1,tx:self.size.width,ty:0)) }
        if a.flipVertical { affine(CGAffineTransform(a:1,b:0,c:0,d:-1,tx:0,ty:self.size.height)) }
        if abs(a.freeRotation)>0.00001 {
            let c=CGPoint(x:self.size.width/2,y:self.size.height/2)
            affine(CGAffineTransform(translationX:-c.x,y:-c.y).concatenating(CGAffineTransform(rotationAngle:-a.freeRotation * .pi/180)).concatenating(CGAffineTransform(translationX:c.x,y:c.y)))
            crop(EditorGeometry.straightenCrop(size:self.size,degrees:a.freeRotation))
        }
        if abs(a.perspectiveVertical)+abs(a.perspectiveHorizontal)>0.00001 {
            let w=self.size.width,h=self.size.height,v=a.perspectiveVertical,horizontal=a.perspectiveHorizontal
            let top=max(0,v)*w*0.15,bottom=max(0,-v)*w*0.15,left=max(0,-horizontal)*h*0.15,right=max(0,horizontal)*h*0.15
            let quad=[CGPoint(x:bottom,y:left),CGPoint(x:w-bottom,y:right),CGPoint(x:w-top,y:h-right),CGPoint(x:top,y:h-left)]
            let src=[CGPoint.zero,CGPoint(x:w,y:0),CGPoint(x:w,y:h),CGPoint(x:0,y:h)]
            let matrix=Self.homography(from:src,to:quad)
            steps.append(.perspective(quad)); forward=matrix*forward
            let x=ceil(max(top,bottom)),y=ceil(max(left,right))
            crop(CGRect(x:x,y:y,width:max(1,floor(w-x)-x),height:max(1,floor(h-y)-y)))
        }
        let extent=CGRect(origin:.zero,size:self.size)
        if let selection=a.cropRect { crop(EditorGeometry.pixels(selection,in:extent)) }
        else if let ratio=a.cropRatio(imageAspect:self.size.width/self.size.height), a.crop != "原比例" {
            let width=min(extent.width,extent.height*ratio),height=min(extent.height,extent.width/ratio)
            crop(CGRect(x:extent.midX-width/2,y:extent.midY-height/2,width:width,height:height).integral)
        }
    }
    private mutating func affine(_ t:CGAffineTransform) {
        steps.append(.affine(t)); let m=simd_double3x3(columns:(SIMD3(t.a,t.b,0),SIMD3(t.c,t.d,0),SIMD3(t.tx,t.ty,1))); forward=m*forward
    }
    private mutating func crop(_ r:CGRect) { steps.append(.crop(r)); affine(CGAffineTransform(translationX:-r.minX,y:-r.minY)); size=r.size }
    func apply(_ input:CIImage)->CIImage {
        var image=input.transformed(by:CGAffineTransform(translationX:-input.extent.minX,y:-input.extent.minY))
        for step in steps {
            switch step {
            case .affine(let t): image=image.transformed(by:t)
            case .crop(let r): image=image.cropped(to:r)
            case .perspective(let p): image=image.applyingFilter("CIPerspectiveTransform",parameters:["inputBottomLeft":CIVector(cgPoint:p[0]),"inputBottomRight":CIVector(cgPoint:p[1]),"inputTopRight":CIVector(cgPoint:p[2]),"inputTopLeft":CIVector(cgPoint:p[3])])
            }
        }
        return image
    }
    func originalPoint(_ p:CGPoint)->CGPoint {
        let q=forward.inverse*SIMD3(Double(p.x*size.width),Double((1-p.y)*size.height),1)
        return CGPoint(x:min(1,max(0,q.x/q.z/originalSize.width)),y:min(1,max(0,1-q.y/q.z/originalSize.height)))
    }
    private static func homography(from:[CGPoint],to:[CGPoint])->simd_double3x3 {
        var rows=[[Double]]()
        for (p,q) in zip(from,to) {
            rows.append([p.x,p.y,1,0,0,0,-q.x*p.x,-q.x*p.y,q.x])
            rows.append([0,0,0,p.x,p.y,1,-q.y*p.x,-q.y*p.y,q.y])
        }
        for i in 0..<8 {
            let pivot=(i..<8).max { abs(rows[$0][i])<abs(rows[$1][i]) }!; rows.swapAt(i,pivot)
            let divisor=rows[i][i]; guard abs(divisor)>1e-12 else { return matrix_identity_double3x3 }
            for j in i...8 { rows[i][j]/=divisor }
            for k in 0..<8 where k != i { let f=rows[k][i];for j in i...8 { rows[k][j]-=f*rows[i][j] } }
        }
        let h=rows.map{$0[8]};return simd_double3x3(columns:(SIMD3(h[0],h[3],h[6]),SIMD3(h[1],h[4],h[7]),SIMD3(h[2],h[5],1)))
    }
}
