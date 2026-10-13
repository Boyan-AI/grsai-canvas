import SwiftUI

/// 提供会话密钥、参考图、模型参数、提示词和付费提交入口。
struct GeneratorPanel: View {
    @Bindable var model: WorkspaceViewModel
    @State private var isCacheConfirmationPresented = false
    @FocusState private var isPromptFocused: Bool

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
        .scrollIndicators(.hidden)
        .background(WorkspaceTheme.surface)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("画境", systemImage: "sparkles.rectangle.stack")
                .font(.title2.bold())
            Text("原生 macOS 生图工作台")
                .font(.callout)
                .foregroundStyle(WorkspaceTheme.silverMist)
        }
    }

    private var accessSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("API Key", detail: model.hasCredential ? "已保存到本机" : "关闭应用后仍保留")
            if model.hasCredential {
                HStack {
                    Label("密钥保存在本机应用数据中", systemImage: "checkmark.shield.fill")
                        .foregroundStyle(WorkspaceTheme.deepVerdant)
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
                    .tint(WorkspaceTheme.electricIris)
                    .disabled(model.credentialInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Link("获取 API Key", destination: URL(string: "https://grsai.com")!)
                    .font(.caption)
            }
        }
        .padding(14)
        .background(WorkspaceTheme.raisedSurface, in: RoundedRectangle(cornerRadius: 14))
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
                        .foregroundStyle(WorkspaceTheme.silverMist)
                }
                .frame(maxWidth: .infinity, minHeight: 110)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(WorkspaceTheme.electricIris.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(WorkspaceTheme.electricIris.opacity(0.65), style: StrokeStyle(lineWidth: 1.5, dash: [7]))
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
            HStack(alignment: .firstTextBaseline) {
                Text("应用数据")
                    .font(.headline)
                Spacer()
                Button("清空应用数据", systemImage: "trash", role: .destructive) {
                    isCacheConfirmationPresented = true
                }
                .buttonStyle(.borderless)
                .disabled(model.isClearingData)
            }
            Text("清除历史记录、原始参考图和生成结果图片，仅保留 API Key。")
                .font(.caption)
                .foregroundStyle(WorkspaceTheme.silverMist)
        }
        .padding(14)
        .background(WorkspaceTheme.raisedSurface, in: RoundedRectangle(cornerRadius: 14))
        .confirmationDialog(
            "清空应用数据？",
            isPresented: $isCacheConfirmationPresented
        ) {
            Button("清空历史和图片，仅保留 API Key", role: .destructive) {
                Task { await model.clearApplicationDataKeepingCredential() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("历史记录、原图和生成图都会删除，API Key 会保留。此操作不可恢复。")
        }
    }

    private var generationOptions: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("生成参数", detail: nil)
            Picker(
                "模型",
                selection: Binding(
                    get: { model.selectedModelOption },
                    set: { model.selectModelOption($0) }
                )
            ) {
                Section("图片 Image") {
                    ForEach(GenerationModelOption.imageOptions) { option in
                        Text(option.displayName).tag(option)
                    }
                }
                Section("视频 Video") {
                    ForEach(GenerationModelOption.videoOptions) { option in
                        Text(option.displayName).tag(option)
                    }
                }
            }
            .pickerStyle(.menu)
            .onChange(of: model.selectedModelOption) { _, _ in
                // 切换模型时结束当前输入法组合，避免候选条残留在新参数区域上。
                isPromptFocused = false
            }
            Text("选择模型后会自动使用对应的图片或视频接口。")
                .font(.caption)
                .foregroundStyle(WorkspaceTheme.silverMist)

            Picker("比例", selection: $model.selectedAspectRatio) {
                ForEach(model.selectedModel.supportedAspectRatios) { ratio in
                    Text(model.selectedModel.isVideo ? model.selectedModel.videoAspectRatioValue(ratio) : ratio.rawValue).tag(ratio)
                }
            }
            .pickerStyle(.menu)

            if model.selectedModel.isVideo {
                Picker("分辨率", selection: $model.selectedVideoResolution) {
                    ForEach(model.selectedModel.supportedVideoResolutions) { resolution in
                        Text(resolution.rawValue).tag(resolution)
                    }
                }
                .pickerStyle(.segmented)
                Stepper("时长 \(model.selectedVideoDuration) 秒", value: $model.selectedVideoDuration, in: model.selectedModel.videoDurationRange.lowerBound...model.maximumVideoDuration)
                Text(model.selectedModel == .agnesVideo25
                     ? "支持 4–12 秒；视频参考图和音频由请求层支持"
                     : "支持 1–15 秒，1080p 最长 10 秒；视频参考图和音频由请求层支持")
                    .font(.caption)
                    .foregroundStyle(WorkspaceTheme.silverMist)
            } else if !model.selectedModel.isGPTImage {
                Picker("清晰度", selection: $model.selectedImageSize) {
                    ForEach(GenerationImageSize.allCases) { size in
                        Text(size.rawValue).tag(size)
                    }
                }
                .pickerStyle(.segmented)
            } else {
                LabeledContent("输出规格", value: "由比例决定 · 1K")
                    .foregroundStyle(WorkspaceTheme.silverMist)
            }
        }
    }

    /// 编辑提示词并在输入法开始组合文字时隐藏占位文案。
    private var promptEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("提示词", detail: "描述要生成或编辑的画面")
            TextEditor(text: $model.prompt)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(10)
                .frame(minHeight: 130)
                .focused($isPromptFocused)
                .background(WorkspaceTheme.raisedSurface, in: RoundedRectangle(cornerRadius: 12))
                .overlay(alignment: .topLeading) {
                    if model.prompt.isEmpty && !isPromptFocused {
                        Text("例如：一只金毛幼犬坐在午后的草地上，自然摄影风格……")
                            .foregroundStyle(WorkspaceTheme.ashGray)
                            // 与 TextEditor 的外部内边距保持一致，让示例文本和输入光标共用起始位置。
                            .padding(10)
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
                    Text(model.isSubmitting ? "正在提交…" : (model.selectedModel.isVideo ? "生成视频 · 可能产生费用" : "生成图片 · 可能产生费用"))
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(WorkspaceTheme.electricIris)
            .controlSize(.large)
            .disabled(!model.canGenerate)

            HStack {
                Text(model.hasCredential ? "点击生成即提交付费任务" : "请先设置 API Key")
                    .foregroundStyle(model.hasCredential ? WorkspaceTheme.silverMist : WorkspaceTheme.saffronSpark)
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
                Text(detail).font(.caption).foregroundStyle(WorkspaceTheme.ashGray)
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
                        .foregroundStyle(WorkspaceTheme.silverMist)
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
