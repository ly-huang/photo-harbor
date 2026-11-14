import SwiftUI
import AppKit

extension PhotoLabel {
    var color:Color{Color(nsColor:nsColor)}
    var nsColor:NSColor{switch self{case .orange:return .systemOrange;case .yellow:return .systemYellow;case .green:return .systemGreen;case .blue:return .systemBlue;case .purple:return .systemPurple;case .gray:return .systemGray}}
    var menuImage:NSImage{
        let context=CGContext(data:nil,width:32,height:32,bitsPerComponent:8,bytesPerRow:128,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(nsColor.cgColor);context.fillEllipse(in:CGRect(x:2,y:2,width:28,height:28))
        let image=NSImage(cgImage:context.makeImage()!,size:NSSize(width:14,height:14));image.isTemplate=false;return image
    }
    var menuTitle:NSAttributedString {
        let text=NSMutableAttributedString(string:"●  ",attributes:[.foregroundColor:nsColor,.font:NSFont.systemFont(ofSize:13)])
        text.append(NSAttributedString(string:rawValue,attributes:[.foregroundColor:NSColor.labelColor,.font:NSFont.menuFont(ofSize:0)]));return text
    }
}
struct PhotoLabelDots:View {
    let labels:Set<PhotoLabel>
    var body:some View{HStack(spacing:4){ForEach(PhotoLabel.allCases.filter{labels.contains($0)},id:\.self){label in Circle().fill(label.color).frame(width:8,height:8).overlay(Circle().stroke(.black.opacity(0.35),lineWidth:0.5))}}.padding(5).background(.black.opacity(0.35),in:Capsule()).accessibilityLabel(labels.map(\.rawValue).sorted().joined(separator:"、"))}
}
struct PhotoLabelMenu:View {
    @EnvironmentObject var store:LibraryStore
    let photo:Photo
    var body:some View {
        Menu("颜色标记") {
            ForEach(PhotoLabel.allCases,id:\.self){label in
                Button {store.toggleLabel(label,photo:photo)} label:{Label{Text(PhotoCommand.color(label).menuTitle((store.labels(for:photo).contains(label) ? "✓ ":"")+label.rawValue))} icon:{Image(nsImage:label.menuImage).renderingMode(.original)}.labelStyle(.titleAndIcon)}
            }
            Divider();Button(PhotoCommand.clearLabels.menuTitle("移除所有颜色标记")){store.clearLabels(photo)}.disabled(store.labels(for:photo).isEmpty)
        }.disabled(store.busy)
    }
}
