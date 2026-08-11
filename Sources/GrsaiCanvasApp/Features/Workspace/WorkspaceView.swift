import SwiftUI
import UniformTypeIdentifiers
import AppKit

/// 承载结果画廊与生成控制台的应用主界面。
struct WorkspaceView: View {
    @Bindable var model: WorkspaceViewModel

    var body: some View {
        HSplitView {
            GalleryView(model: model)
                .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)

            GeneratorPanel(model: model)
                .frame(minWidth: 360, idealWidth: 420, maxWidth: 480, maxHeight: .infinity)
        }
        .background(WorkspaceTheme.void)
        .task { await model.load() }
        .fileImporter(
            isPresented: $model.isFileImporterPresented,
            allowedContentTypes: [.image],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls): model.addReferenceImages(urls)
            case .failure(let error): model.alertMessage = error.localizedDescription
            }
        }
        .alert("提示", isPresented: alertBinding) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(model.alertMessage ?? "")
        }
    }

    private var alertBinding: Binding<Bool> {
        Binding(
            get: { model.alertMessage != nil },
            set: { if !$0 { model.alertMessage = nil } }
        )
    }
}

/// 显示历史任务和已下载结果的响应式画廊。
private struct GalleryView: View {
    @Bindable var model: WorkspaceViewModel
    @State private var taskPendingDeletion: GenerationTask?
    @State private var taskPendingPreview: GenerationTask?
    private let columns = [GridItem(.adaptive(minimum: 160, maximum: 180), spacing: 12)]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("作品画廊")
                        .font(.title2.bold())
                    Text("任务保存在本机，可在重启后继续查询。")
                        .font(.callout)
                        .foregroundStyle(WorkspaceTheme.silverMist)
                }
                Spacer()
                if !model.tasks.isEmpty {
                    Text("\(model.tasks.count) 个任务")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(WorkspaceTheme.raisedSurface, in: Capsule())
                }
            }
            .padding(24)

            Divider()

            if model.tasks.isEmpty {
                ContentUnavailableView(
                    "还没有作品",
                    systemImage: "photo.on.rectangle.angled",
                    description: Text("在右侧输入提示词，生成结果会显示在这里。")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                        ForEach(model.tasks) { task in
                            TaskCard(
                                task: task,
                                onContinueOriginal: {
                                    Task { await model.continueEditing(task: task, source: .original) }
                                },
                                onContinueGenerated: {
                                    Task { await model.continueEditing(task: task, source: .generated) }
                                },
                                onPreview: {
                                    taskPendingPreview = task
                                }
                            ) {
                                taskPendingDeletion = task
                            }
                        }
                    }
                    .padding(18)
                }
            }
        }
        .confirmationDialog(
            "删除这个任务？",
            isPresented: deletionConfirmationBinding,
            presenting: taskPendingDeletion
        ) { task in
            Button("删除任务和本地图片", role: .destructive) {
                taskPendingDeletion = nil
                Task { await model.deleteTask(id: task.id) }
            }
            Button("取消", role: .cancel) {
                taskPendingDeletion = nil
            }
        } message: { _ in
            Text("任务记录和应用数据中的结果图片将被删除，另存为的副本不受影响。")
        }
        .sheet(item: $taskPendingPreview) { task in
            ImagePreviewView(task: task)
        }
    }

    /// 将待删除任务转换为确认弹窗的显示状态。
    private var deletionConfirmationBinding: Binding<Bool> {
        Binding(
            get: { taskPendingDeletion != nil },
            set: { if !$0 { taskPendingDeletion = nil } }
        )
    }
}

/// 展示单个任务的封面、状态、提示词和本地操作。
private struct TaskCard: View {
    let task: GenerationTask
    let onContinueOriginal: () -> Void
    let onContinueGenerated: () -> Void
    let onPreview: () -> Void
    let onDelete: () -> Void
    @State private var promptCopied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(WorkspaceTheme.raisedSurface)
                artwork
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 14))

            HStack(spacing: 6) {
                Label(task.status.displayName, systemImage: task.status.systemImage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(task.status.tint)
                Spacer()
                Text(task.model.rawValue)
                    .font(.caption2.monospaced())
                .foregroundStyle(WorkspaceTheme.ashGray)
            }

            Text(task.prompt)
                .font(.body.weight(.medium))
                .lineSpacing(0)
                .lineLimit(1)
                .truncationMode(.tail)
                .contentShape(Rectangle())
                .onTapGesture(perform: copyPrompt)
                .help("点击复制提示词")
                .overlay(alignment: .topTrailing) {
                    if promptCopied {
                        Text("已复制")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(WorkspaceTheme.electricIris, in: Capsule())
                    }
                }

            if task.status == .running {
                ProgressView(value: Double(task.progress ?? 0), total: 100)
                    .accessibilityLabel("生成进度")
                    .accessibilityValue("\(task.progress ?? 0)%")
            }

            if let errorMessage = task.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(WorkspaceTheme.saffronSpark)
                    .lineLimit(3)
            }

            if let path = task.localImagePaths.first {
                HStack(spacing: 10) {
                    Button(action: {
                        reveal(path: path)
                    }) {
                        Image(systemName: "folder")
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.borderless)
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("在 Finder 中显示")
                    .help("在 Finder 中显示")
                    Button(action: {
                        saveAs(path: path)
                    }) {
                        Image(systemName: "square.and.arrow.down")
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.borderless)
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("另存为")
                    .help("另存为")
                    continueEditingMenu
                    deleteButton
                }
                .frame(minHeight: 28)
                .font(.body)
            } else {
                HStack {
                    Spacer()
                    continueEditingMenu
                    deleteButton
                }
                .frame(minHeight: 28)
                .font(.body)
            }
        }
        .padding(10)
        .background(WorkspaceTheme.surface, in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(WorkspaceTheme.subtleBorder)
        }
    }

    /// 提供统一的任务删除入口，由画廊确认后执行实际删除。
    private var deleteButton: some View {
        Button(role: .destructive, action: onDelete) {
            Image(systemName: "trash")
                .frame(width: 30, height: 30)
        }
            .buttonStyle(.borderless)
            .frame(maxWidth: .infinity)
            .foregroundStyle(WorkspaceTheme.saffronSpark)
            .accessibilityLabel("删除任务")
            .help("删除任务")
    }

    /// 提供基于原图或生成图的继续编辑入口。
    private var continueEditingMenu: some View {
        Menu {
            Button("基于原图", action: onContinueOriginal)
                .disabled(!hasAvailableOriginal)
            Button("基于生成图", action: onContinueGenerated)
                .disabled(!hasAvailableGenerated)
        } label: {
            Image(systemName: "pencil")
                .frame(width: 30, height: 30)
        }
        .menuStyle(.borderlessButton)
        .frame(maxWidth: .infinity)
        .accessibilityLabel("继续修改")
        .help("选择参考图继续修改")
    }

    /// 判断历史任务是否仍有可用的原始参考图缓存。
    private var hasAvailableOriginal: Bool {
        (task.referenceImagePaths ?? []).contains {
            FileManager.default.fileExists(atPath: $0)
        }
    }

    /// 判断历史任务是否有本地或远程生成结果。
    private var hasAvailableGenerated: Bool {
        !task.localImagePaths.isEmpty || !task.resultURLs.isEmpty
    }

    @ViewBuilder
    private var artwork: some View {
        Button(action: onPreview) {
            artworkContent
        }
        .buttonStyle(.plain)
        .disabled(!hasAvailableGenerated)
    }

    @ViewBuilder
    private var artworkContent: some View {
        if let path = task.localImagePaths.first,
           let image = NSImage(contentsOfFile: path) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
        } else if let url = task.resultURLs.first {
            RemoteImageView(url: url, contentMode: .fill)
        } else {
            Image(systemName: task.status.systemImage)
                .font(.system(size: 38))
                .foregroundStyle(task.status.tint)
        }
    }

    /// 将完整提示词写入 macOS 系统剪贴板。
    private func copyPrompt() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(task.prompt, forType: .string)
        promptCopied = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            promptCopied = false
        }
    }

    /// 在 Finder 中定位已下载结果。
    private func reveal(path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    /// 通过系统面板把本地结果复制到用户选择的位置。
    private func saveAs(path: String) {
        let source = URL(fileURLWithPath: path)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = source.lastPathComponent
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: source, to: destination)
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}

/// 在独立弹窗中展示历史任务的第一张结果图片。
private struct ImagePreviewView: View {
    let task: GenerationTask
    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1
    @State private var settledScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var settledOffset: CGSize = .zero

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("作品预览")
                        .font(.title2.bold())
                    Text(task.prompt)
                        .font(.callout)
                        .foregroundStyle(WorkspaceTheme.silverMist)
                        .lineLimit(2)
                }
                Spacer()
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.escape)
            }

            ZStack {
                previewContent
                    .scaleEffect(scale)
                    .offset(offset)
                    .overlay {
                        TrackpadGestureCapture(
                            onPan: pan,
                            onMagnify: magnify
                        )
                    }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .background(WorkspaceTheme.void, in: RoundedRectangle(cornerRadius: 16))
        }
        .padding(22)
        .frame(minWidth: 720, minHeight: 560)
    }

    /// 应用鼠标拖动或双指平移产生的偏移。
    private func pan(_ delta: CGSize) {
        offset = CGSize(
            width: settledOffset.width + delta.width,
            height: settledOffset.height + delta.height
        )
        settledOffset = offset
    }

    /// 应用触控板缩放，并限制最大放大倍数。
    private func magnify(_ delta: CGFloat) {
        scale = min(max(settledScale + delta, 1), 4)
        settledScale = scale
        if scale == 1 {
            offset = .zero
            settledOffset = .zero
        }
    }

    @ViewBuilder
    private var previewContent: some View {
        if let path = task.localImagePaths.first,
           let image = NSImage(contentsOfFile: path) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .padding(18)
        } else if let url = task.resultURLs.first {
            RemoteImageView(url: url, contentMode: .fit)
                .padding(18)
        } else {
            Label("暂无可预览图片", systemImage: "photo")
                .foregroundStyle(WorkspaceTheme.ashGray)
        }
    }
}

/// 通过 macOS 触控板事件捕获双指平移、缩放和鼠标拖动。
private struct TrackpadGestureCapture: NSViewRepresentable {
    let onPan: (CGSize) -> Void
    let onMagnify: (CGFloat) -> Void

    func makeNSView(context: Context) -> GestureCaptureView {
        let view = GestureCaptureView()
        view.onPan = onPan
        view.onMagnify = onMagnify
        return view
    }

    func updateNSView(_ nsView: GestureCaptureView, context: Context) {
        nsView.onPan = onPan
        nsView.onMagnify = onMagnify
    }
}

/// 接收 macOS 滚轮、放大和鼠标拖动事件的透明视图。
private final class GestureCaptureView: NSView {
    var onPan: ((CGSize) -> Void)?
    var onMagnify: ((CGFloat) -> Void)?
    private var lastMousePoint: NSPoint?

    override func scrollWheel(with event: NSEvent) {
        onPan?(CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY))
    }

    override func magnify(with event: NSEvent) {
        onMagnify?(event.magnification)
    }

    override func mouseDown(with event: NSEvent) {
        lastMousePoint = convert(event.locationInWindow, from: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let lastMousePoint {
            onPan?(CGSize(width: point.x - lastMousePoint.x, height: point.y - lastMousePoint.y))
        }
        lastMousePoint = point
    }

    override func mouseUp(with event: NSEvent) {
        lastMousePoint = nil
    }
}

/// 显式下载远程结果，清空缓存后仍能从任务 URL 恢复显示并支持重试。
private struct RemoteImageView: View {
    let url: URL
    let contentMode: ContentMode
    @State private var image: NSImage?
    @State private var isLoading = true
    @State private var failed = false

    init(url: URL, contentMode: ContentMode) {
        self.url = url
        self.contentMode = contentMode
    }

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else if failed {
                Button("重新加载", systemImage: "arrow.clockwise") {
                    Task { await load() }
                }
                .buttonStyle(.borderless)
            } else if isLoading {
                ProgressView()
            }
        }
        .task(id: url) { await load() }
    }

    /// 从 HTTPS 结果地址重新获取图片数据。
    private func load() async {
        isLoading = true
        failed = false
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let image = NSImage(data: data) else {
                throw URLError(.cannotDecodeContentData)
            }
            self.image = image
        } catch {
            failed = true
        }
        isLoading = false
    }
}

/// 把任务状态转换为统一的中文展示属性。
private extension GenerationStatus {
    var displayName: String {
        switch self {
        case .running: "生成中"
        case .violation: "内容受限"
        case .succeeded: "已完成"
        case .failed: "生成失败"
        }
    }

    var systemImage: String {
        switch self {
        case .running: "clock.arrow.circlepath"
        case .violation: "hand.raised.fill"
        case .succeeded: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .running: WorkspaceTheme.electricIris
        case .violation: WorkspaceTheme.saffronSpark
        case .succeeded: WorkspaceTheme.deepVerdant
        case .failed: WorkspaceTheme.saffronSpark
        }
    }
}
