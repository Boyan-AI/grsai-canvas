import SwiftUI
import UniformTypeIdentifiers

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
        .background {
            LinearGradient(
                colors: [Color.accentColor.opacity(0.08), Color.clear],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
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
    private let columns = [GridItem(.adaptive(minimum: 220, maximum: 320), spacing: 16)]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("作品画廊")
                        .font(.title2.bold())
                    Text("任务保存在本机，可在重启后继续查询。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !model.tasks.isEmpty {
                    Text("\(model.tasks.count) 个任务")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.quaternary, in: Capsule())
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
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(model.tasks) { task in
                            TaskCard(task: task) {
                                taskPendingDeletion = task
                            }
                        }
                    }
                    .padding(24)
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
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.secondary.opacity(0.08))
                artwork
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 14))

            HStack(spacing: 8) {
                Label(task.status.displayName, systemImage: task.status.systemImage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(task.status.tint)
                Spacer()
                Text(task.model.rawValue)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("删除任务")
                .help("删除任务")
            }

            Text(task.prompt)
                .font(.callout.weight(.medium))
                .lineLimit(2)

            if task.status == .running {
                ProgressView(value: Double(task.progress ?? 0), total: 100)
                    .accessibilityLabel("生成进度")
                    .accessibilityValue("\(task.progress ?? 0)%")
            }

            if let errorMessage = task.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(3)
            }

            if let path = task.localImagePaths.first {
                HStack {
                    Button("在 Finder 中显示", systemImage: "folder") {
                        reveal(path: path)
                    }
                    .buttonStyle(.borderless)
                    Spacer()
                    Button("另存为", systemImage: "square.and.arrow.down") {
                        saveAs(path: path)
                    }
                    .buttonStyle(.borderless)
                }
                .font(.caption)
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .stroke(Color.primary.opacity(0.08))
        }
    }

    @ViewBuilder
    private var artwork: some View {
        if let path = task.localImagePaths.first,
           let image = NSImage(contentsOfFile: path) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
        } else if let url = task.resultURLs.first {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image): image.resizable().scaledToFill()
                case .failure: Image(systemName: "photo.badge.exclamationmark").font(.largeTitle)
                default: ProgressView()
                }
            }
        } else {
            Image(systemName: task.status.systemImage)
                .font(.system(size: 38))
                .foregroundStyle(task.status.tint)
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
        case .running: .blue
        case .violation: .orange
        case .succeeded: .green
        case .failed: .red
        }
    }
}
