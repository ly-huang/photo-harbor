import SwiftUI
import AppKit

struct PhotoExportView: View {
    let photos: [Photo]
    let protected: Set<URL>
    @Environment(\.dismiss) private var dismiss
    @ViewState private var folder: URL?
    @ViewState private var separate = true
    @ViewState private var running = false
    @ViewState private var stopped = false
    @ViewState private var finished = false
    @ViewState private var completed = 0
    @ViewState private var skipped = 0
    @ViewState private var processed = 0
    @ViewState private var failures: [String] = []
    private var files: [PhotoFile] { photos.flatMap(\.files) }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("导出筛选照片").font(.title2.weight(.semibold))
            Text("当前筛选结果：\(photos.count) 张照片，\(files.count) 个文件。复制 JPG 与 RAW，保留来源文件。").foregroundStyle(.secondary)
            HStack {
                Text(folder?.path ?? "请选择导出文件夹").lineLimit(2).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                Button("选择…") { chooseFolder() }.disabled(running || finished)
            }
            Picker("存放方式", selection: $separate) {
                Text("分别存入 JPG / RAW 子文件夹").tag(true)
                Text("全部存入所选文件夹").tag(false)
            }.pickerStyle(.radioGroup).disabled(running || finished)
            Text("缺少的目录会自动创建，已有目录会继续使用。同名文件逐项询问：替换、保留两者或跳过。保留两者会添加数字后缀。").font(.caption).foregroundStyle(.secondary)
            if running || finished {
                ProgressView(value: Double(processed), total: Double(max(files.count, 1)))
                Text("已导出 \(completed) · 已跳过 \(skipped) · 失败 \(failures.count)\(stopped ? " · 已停止" : "")").font(.callout)
            }
            if !failures.isEmpty {
                ScrollView { Text(failures.joined(separator: "\n")).font(.caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 110)
            }
            HStack {
                Spacer()
                if running { Button("停止") { stopped = true }.disabled(stopped) }
                else {
                    Button(finished ? "完成" : "取消") { dismiss() }
                    if !finished { Button("开始导出") { Task { await run() } }.buttonStyle(.borderedProminent).disabled(folder == nil || files.isEmpty) }
                }
            }
        }.padding(28).frame(width: 530).interactiveDismissDisabled(running)
    }
    private func chooseFolder() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.canCreateDirectories = true; panel.allowsMultipleSelection = false; panel.prompt = "选择导出位置"
        if panel.runModal() == .OK { folder = panel.url.map(canonicalURL) }
    }
    @MainActor private func run() async {
        guard let folder else { return }
        running = true
        defer { running = false; finished = true }
        for file in files {
            if stopped { break }
            let destination = PhotoExport.destination(file, folder: folder, separate: separate)
            do {
                var choice = PhotoExport.Choice.keepBoth
                var target: PhotoExport.Target?
                if FileManager.default.fileExists(atPath: destination.path) {
                    target = try? await Task.detached { try PhotoExport.reviewedTarget(destination) }.value
                    let alert = NSAlert(); alert.messageText = "已存在同名文件：\(destination.lastPathComponent)"
                    alert.informativeText = "目标：\(destination.path)\n替换会覆盖目标内容，无法通过应用撤销。来源照片保留。"
                    alert.addButton(withTitle: "保留两者"); alert.addButton(withTitle: "替换已有文件"); alert.addButton(withTitle: "跳过该文件")
                    alert.buttons[1].isEnabled = target != nil && !protected.contains(destination)
                    if let window = NSApp.keyWindow {
                        let response = await withCheckedContinuation { continuation in alert.beginSheetModal(for: window) { continuation.resume(returning: $0) } }
                        choice = response == .alertSecondButtonReturn ? .replace : response == .alertThirdButtonReturn ? .skip : .keepBoth
                    } else { choice = .skip }
                }
                let selectedChoice = choice, reviewed = target, protectedURLs = protected
                let result = try await Task.detached(priority: .userInitiated) { try PhotoExport.copy(file, to: destination, choice: selectedChoice, target: reviewed, protected: protectedURLs) }.value
                if result == nil { skipped += 1 } else { completed += 1 }
            } catch { failures.append("\(file.url.lastPathComponent)：\(error.localizedDescription)") }
            processed += 1
        }
    }
}
