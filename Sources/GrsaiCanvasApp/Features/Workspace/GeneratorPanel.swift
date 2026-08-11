import SwiftUI

/// 提供会话密钥、参考图、模型参数、提示词和付费提交入口。
struct GeneratorPanel: View {
    @Bindable var model: WorkspaceViewModel
    @State private var isCacheConfirmationPresented = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                accessSection
                cacheSection
                referenceImages
                generationOptions
                promptEditor
                submitActions
            }
            .padding(24)
        }
        .background(.regularMaterial)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("画境", systemImage: "sparkles.rectangle.stack")
                .font(.title2.bold())
            Text("原生 macOS 生图工作台")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var accessSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("API Key", detail: model.hasCredential ? "已保存到本机" : "关闭应用后仍保留")
            if model.hasCredential {
                HStack {
                    Label("密钥保存在本机应用数据中", systemImage: "checkmark.shield.fill")
                        .foregroundStyle(.green)
                    Spacer()
                    Button("清除") {
                        Task { await model.clearCredential() }
                    }
                    .buttonStyle(.borderless)
                }
                .font(.callout)
            } else {
                HStack {
                    SecureField("输入 Grsai API Key", text: $model.credentialInput)
                        .textFieldStyle(.roundedBorder)
                    Button("使用") {
                        Task { await model.saveCredential() }
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.credentialInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Link("获取 API Key", destination: URL(string: "https://grsai.com")!)
                    .font(.caption)
            }
        }
        .padding(14)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))
    }

    private var referenceImages: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("参考图", detail: "可选，最多 8 张")
            Button {
                model.isFileImporterPresented = true
            } label: {
                VStack(spacing: 10) {
                    Image(systemName: "photo.badge.plus")
                        .font(.system(size: 28))
                    Text("点击选择或拖放图片")
                        .fontWeight(.medium)
                    Text("JPG、PNG、WEBP · 总计不超过 8 MB")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 110)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color.accentColor.opacity(0.35), style: StrokeStyle(lineWidth: 1.5, dash: [7]))
            }
            .dropDestination(for: URL.self) { urls, _ in
                model.addReferenceImages(urls)
                return !urls.isEmpty
            }

            if !model.referenceImageURLs.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 10) {
                        ForEach(model.referenceImageURLs, id: \.self) { url in
                            ReferenceThumbnail(url: url) {
                                model.removeReferenceImage(url)
                            }
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    private var cacheSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("本地缓存", detail: "不删除历史记录")
            Text("清除原始参考图和生成结果图片，历史任务和远程链接会保留。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("清空图片缓存", systemImage: "trash", role: .destructive) {
                isCacheConfirmationPresented = true
            }
            .buttonStyle(.borderless)
            .disabled(model.isClearingCache)
        }
        .padding(14)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))
        .confirmationDialog(
            "清空图片缓存？",
            isPresented: $isCacheConfirmationPresented
        ) {
            Button("清空原图和生成图", role: .destructive) {
                Task { await model.clearImageCache() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只删除本地图片缓存，历史记录、提示词和远程结果链接会保留。")
        }
    }

    private var generationOptions: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("生成参数", detail: nil)
            Picker("模型", selection: $model.selectedModel) {
                ForEach(GrsaiImageModel.allCases) { imageModel in
                    Text(imageModel.rawValue).tag(imageModel)
                }
            }
            .pickerStyle(.menu)

            Picker("比例", selection: $model.selectedAspectRatio) {
                ForEach(GenerationAspectRatio.allCases) { ratio in
                    Text(ratio.rawValue).tag(ratio)
                }
            }
            .pickerStyle(.menu)

            if !model.selectedModel.isGPTImage {
                Picker("清晰度", selection: $model.selectedImageSize) {
                    ForEach(GenerationImageSize.allCases) { size in
                        Text(size.rawValue).tag(size)
                    }
                }
                .pickerStyle(.segmented)
            } else {
                LabeledContent("输出规格", value: "由比例决定 · 1K")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var promptEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("提示词", detail: "描述要生成或编辑的画面")
            TextEditor(text: $model.prompt)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(10)
                .frame(minHeight: 130)
                .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
                .overlay(alignment: .topLeading) {
                    if model.prompt.isEmpty {
                        Text("例如：一只金毛幼犬坐在午后的草地上，自然摄影风格……")
                            .foregroundStyle(.tertiary)
                            .padding(16)
                            .allowsHitTesting(false)
                    }
                }
        }
    }

    private var submitActions: some View {
        VStack(spacing: 10) {
            Button {
                Task { await model.generate() }
            } label: {
                HStack {
                    if model.isSubmitting { ProgressView().controlSize(.small) }
                    Text(model.isSubmitting ? "正在提交…" : "生成图像 · 可能产生费用")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!model.canGenerate)

            HStack {
                Text(model.hasCredential ? "点击生成即提交付费任务" : "请先设置 API Key")
                    .foregroundStyle(model.hasCredential ? Color.secondary : Color.orange)
                Spacer()
                Button("清空") { model.resetDraft() }
                    .buttonStyle(.borderless)
            }
            .font(.caption)
        }
    }

    /// 统一生成控制台的小节标题。
    private func sectionTitle(_ title: String, detail: String?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.headline)
            Spacer()
            if let detail {
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// 显示一张本地参考图并提供移除操作。
private struct ReferenceThumbnail: View {
    let url: URL
    let onRemove: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let image = NSImage(contentsOf: url) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "photo")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 72, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: 10))

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.65))
            }
            .buttonStyle(.plain)
            .offset(x: 5, y: -5)
            .accessibilityLabel("移除 \(url.lastPathComponent)")
        }
        .padding(.top, 5)
    }
}
