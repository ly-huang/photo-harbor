import SwiftUI

struct ComparisonSelectionPopover: View {
    @EnvironmentObject var store: LibraryStore
    let openComparison: () -> Void
    let onAction: (PhotoContextAction, [Photo]) -> Void
    private var photos: [Photo] { store.comparisonPhotos }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("已选照片").font(.headline)
                Text("\(photos.count)/4").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("清空选择") { store.clearComparisonSelection() }
                    .buttonStyle(.borderless).disabled(photos.isEmpty).help("仅取消全部对比选择，保留照片文件")
            }
            if photos.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "photo.stack").font(.system(size: 28)).foregroundStyle(.secondary)
                    Text("还没有选择照片").font(.subheadline)
                    Text("右键照片，选择“加入对比”。").font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                        ForEach(Array(photos.enumerated()), id: \.element.id) { index, photo in
                            VStack(alignment: .leading, spacing: 5) {
                                PhotoImage(file: photo.previewFile, size: 360).frame(height: 94)
                                    .clipShape(RoundedRectangle(cornerRadius: 7))
                                    .overlay(alignment: .topTrailing) {
                                        Button { store.toggleComparison(photo) } label: {
                                            Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                                                .frame(width: 24, height: 24).background(.regularMaterial, in: Circle())
                                        }.buttonStyle(.plain).padding(5).help("移出对比：\(photo.name)")
                                            .accessibilityLabel("移出对比 \(photo.name)")
                                    }
                                    .contextMenu { PhotoFileActions(photos: [photo], perform: onAction) }
                                HStack(spacing: 5) {
                                    Text("\(index + 1)").font(.caption.bold()).foregroundStyle(.secondary)
                                    Text(photo.name).font(.caption.weight(.medium)).lineLimit(1)
                                }
                                Text(store.albums.first { $0.id == photo.albumID }?.title ?? "")
                                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                }
            }
            Divider()
            HStack {
                Text("移出仅取消选择").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("开始对比", action: openComparison).buttonStyle(.borderedProminent)
                    .disabled(!(2...4).contains(photos.count))
            }
        }.padding(18).frame(width: 350, height: 400).modifier(ArrowPointer())
    }
}
