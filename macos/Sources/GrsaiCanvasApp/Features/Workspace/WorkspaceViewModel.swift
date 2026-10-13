import Foundation
import Observation

/// 历史任务继续编辑时选择的参考图来源。
enum HistoryEditSource: Sendable {
    case original
    case generated
}

/// 编排工作台输入、付费提交、同任务轮询、结果下载与历史持久化。
@MainActor
@Observable
final class WorkspaceViewModel {
    var tasks: [GenerationTask] = []
    var interfaceMode: GenerationInterface = .nativeImage {
        didSet {
            if interfaceMode == .nativeVideo { selectedModel = .minimaxH3 }
            if interfaceMode != .nativeVideo, selectedModel.isVideo { selectedModel = .gptImage2 }
        }
    }
    var prompt = ""
    var selectedModel: GrsaiImageModel = .gptImage2 {
        didSet {
            if !selectedModel.supportedAspectRatios.contains(selectedAspectRatio) {
                selectedAspectRatio = selectedModel.isVideo ? .landscape : .automatic
            }
            if selectedModel.isVideo && !selectedModel.supportedVideoResolutions.contains(selectedVideoResolution) {
                selectedVideoResolution = selectedModel == .agnesVideo25 ? .p720 : .p768
            }
            if selectedModel.isVideo {
                selectedVideoDuration = min(max(selectedVideoDuration, selectedModel.videoDurationRange.lowerBound), maximumVideoDuration)
            }
        }
    }
    var selectedAspectRatio: GenerationAspectRatio = .automatic
    var selectedImageSize: GenerationImageSize = .oneK
    var selectedVideoResolution: GenerationVideoResolution = .p768 {
        didSet {
            selectedVideoDuration = min(selectedVideoDuration, maximumVideoDuration)
        }
    }
    var selectedVideoDuration = 5 {
        didSet {
            if selectedModel.isVideo && selectedVideoDuration > maximumVideoDuration {
                selectedVideoDuration = maximumVideoDuration
            }
        }
    }
    /// 当前视频模型和分辨率共同限定的最长时长。
    var maximumVideoDuration: Int {
        selectedModel == .minimaxH3 && selectedVideoResolution == .p1080 ? 10 : selectedModel.videoDurationRange.upperBound
    }
    var selectedVideoSeed: Int?
    var serviceModel = "gemini-3.1-pro"
    var imageQuality = "auto"
    var imageBackground = "auto"
    var chatStream = false
    var geminiGenerationConfigJSON = "{}"
    var referenceImageURLs: [URL] = []
    var credentialInput = ""
    var hasCredential = false
    var isSubmitting = false
    var isFileImporterPresented = false
    var isClearingData = false
    var alertMessage: String?

    /// 当前统一模型菜单对应的选项，兼容旧字段以保持请求和历史记录格式稳定。
    var selectedModelOption: GenerationModelOption {
        switch interfaceMode {
        case .nativeImage, .nativeVideo: .native(selectedModel)
        case .openAIImage, .imageEdit, .openAIChat, .gemini, .geminiStream:
            .native(.gptImage2)
        }
    }

    private let apiClient: GrsaiAPIClient
    private let historyStore: GenerationHistoryStore
    private let imageStore: ResultImageStore
    private let secretStore: any SecretStore
    private let pollInterval: Duration
    private let retryInterval: Duration
    private var pollingTaskIDs: Set<String> = []

    /// 切换统一模型菜单选项，并同步底层协议和原生模型状态。
    func selectModelOption(_ option: GenerationModelOption) {
        interfaceMode = option.interfaceMode
        selectedModel = option.nativeModel
    }

    /// 注入所有外部副作用，默认值连接生产 Grsai 节点与本地存储。
    init(
        apiClient: GrsaiAPIClient = GrsaiAPIClient(),
        historyStore: GenerationHistoryStore = GenerationHistoryStore(),
        imageStore: ResultImageStore = ResultImageStore(),
        secretStore: any SecretStore = ApplicationDataSecretStore(),
        pollInterval: Duration = .seconds(2),
        retryInterval: Duration = .seconds(5)
    ) {
        self.apiClient = apiClient
        self.historyStore = historyStore
        self.imageStore = imageStore
        self.secretStore = secretStore
        self.pollInterval = pollInterval
        self.retryInterval = retryInterval
    }

    /// 判断当前输入是否满足提交前的最低条件。
    var canGenerate: Bool {
        hasCredential
            && !isSubmitting
            && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (interfaceMode != .imageEdit || !referenceImageURLs.isEmpty)
    }

    /// 加载历史和持久化凭据，并恢复同一任务 ID 的查询。
    func load() async {
        do {
            tasks = try await historyStore.load().sorted { $0.createdAt > $1.createdAt }
            hasCredential = await secretStore.read() != nil
            resumePendingTasks()
        } catch {
            present(error)
        }
    }

    /// 将当前凭据保存到本机应用数据中。
    func saveCredential() async {
        do {
            try await secretStore.save(credentialInput)
            credentialInput = ""
            hasCredential = true
            resumePendingTasks()
        } catch {
            present(error)
        }
    }

    /// 清除本机应用数据中的凭据并停止新提交。
    func clearCredential() async {
        await secretStore.delete()
        credentialInput = ""
        hasCredential = false
    }

    /// 添加去重后的本地参考图，数量上限为八张。
    func addReferenceImages(_ urls: [URL]) {
        let supportedExtensions = Set(["jpg", "jpeg", "png", "webp"])
        let candidates = urls.filter { supportedExtensions.contains($0.pathExtension.lowercased()) }
        let merged = referenceImageURLs + candidates.filter { !referenceImageURLs.contains($0) }
        let maximumCount = selectedModel.isVideo ? ReferenceImageEncoder.maximumVideoImageCount : ReferenceImageEncoder.maximumImageCount
        referenceImageURLs = Array(merged.prefix(maximumCount))
        if candidates.count != urls.count {
            alertMessage = "已忽略非 JPG、JPEG、PNG 或 WEBP 文件"
        } else if merged.count > maximumCount {
            alertMessage = "当前模型的参考图最多允许 (maximumCount) 张"
        }
    }

    /// 从当前草稿中移除一张参考图。
    func removeReferenceImage(_ url: URL) {
        referenceImageURLs.removeAll { $0 == url }
    }

    /// 提交一次明确由用户触发的生图请求，并立即保存任务 ID。
    func generate() async {
        guard !isSubmitting else { return }
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            guard let credential = await secretStore.read() else {
                throw GrsaiClientError.missingAPIKey
            }
            if interfaceMode == .openAIChat || interfaceMode == .gemini || interfaceMode == .geminiStream {
                try await generateText(credential: credential)
                return
            }
            let urls = referenceImageURLs
            let maximumImageCount = selectedModel.isVideo ? ReferenceImageEncoder.maximumVideoImageCount : ReferenceImageEncoder.maximumImageCount
            let images = try await Task.detached {
                try ReferenceImageEncoder.encode(urls: urls, maximumCount: maximumImageCount)
            }.value
            if interfaceMode == .openAIImage {
                let requestID = UUID()
                let response = try await apiClient.openAIImage(
                    prompt: prompt,
                    model: serviceModel,
                    quality: imageQuality == "auto" ? nil : imageQuality,
                    background: imageBackground == "auto" ? nil : imageBackground,
                    apiKey: credential,
                    requestID: requestID
                )
                let task = GenerationTask.completed(response: response, requestID: requestID, prompt: prompt, interfaceMode: .openAIImage, serviceModel: serviceModel)
                tasks.insert(task, at: 0)
                try await historyStore.save(tasks)
                await finishTaskIfNeeded(taskID: task.id)
                clearSubmittedDraft()
                return
            }
            if interfaceMode == .imageEdit {
                guard let firstURL = urls.first,
                      let imageData = try? Data(contentsOf: firstURL) else {
                    throw GrsaiClientError.invalidInput("图片编辑至少需要一张可读取的参考图")
                }
                let requestID = UUID()
                let response = try await apiClient.editImage(
                    prompt: prompt,
                    model: serviceModel,
                    imageData: imageData,
                    imageFileName: firstURL.lastPathComponent,
                    imageMimeType: mimeType(for: firstURL),
                    quality: imageQuality == "auto" ? nil : imageQuality,
                    background: imageBackground == "auto" ? nil : imageBackground,
                    apiKey: credential,
                    requestID: requestID
                )
                let task = GenerationTask.completed(response: response, requestID: requestID, prompt: prompt, interfaceMode: .imageEdit, serviceModel: serviceModel)
                tasks.insert(task, at: 0)
                try await historyStore.save(tasks)
                await finishTaskIfNeeded(taskID: task.id)
                clearSubmittedDraft()
                return
            }
            let draft = try GenerationDraft(
                prompt: prompt,
                model: selectedModel,
                aspectRatio: selectedAspectRatio,
                imageSize: (selectedModel.isGPTImage || selectedModel.isVideo) ? nil : selectedImageSize,
                referenceImages: images,
                videoResolution: selectedModel.isVideo ? selectedVideoResolution : nil,
                videoDuration: selectedModel.isVideo ? selectedVideoDuration : nil,
                videoSeed: selectedModel.isVideo ? selectedVideoSeed : nil
            ).validated()

            // 草稿已经完成校验并独立保存，提交前清空界面输入，避免用户重复提交同一组参数。
            clearSubmittedDraft()
            let requestID = UUID()
            let referenceImagePaths = try await imageStore.copyReferenceImages(
                urls: urls,
                taskID: requestID.uuidString,
                maximumCount: maximumImageCount
            )
            let response = try await apiClient.submit(
                draft: draft,
                apiKey: credential,
                requestID: requestID
            )
            let task = GenerationTask.submitted(
                response: response,
                requestID: requestID,
                draft: draft,
                referenceImagePaths: referenceImagePaths
            )
            tasks.insert(task, at: 0)
            try await historyStore.save(tasks)
            if response.status == .running {
                startPolling(taskID: response.id)
            } else {
                await finishTaskIfNeeded(taskID: response.id)
            }
        } catch {
            present(error)
        }
    }

    /// 清空当前提示词与参考图，保留模型偏好。
    func resetDraft() {
        prompt = ""
        referenceImageURLs = []
    }

    /// 清空已提交任务对应的全部生成配置，恢复为下一次生成的默认状态。
    private func clearSubmittedDraft() {
        resetDraft()
        selectedModel = interfaceMode == .nativeVideo ? .minimaxH3 : .gptImage2
        selectedAspectRatio = .automatic
        selectedImageSize = .oneK
        selectedVideoResolution = .p768
        selectedVideoDuration = 5
        selectedVideoSeed = nil
    }

    /// 调用 Chat 或 Gemini 接口并把完整文本保存为历史任务。
    private func generateText(credential: String) async throws {
        let requestID = UUID()
        let urls = referenceImageURLs
        let images = try await Task.detached {
            try ReferenceImageEncoder.encode(urls: urls, maximumCount: ReferenceImageEncoder.maximumImageCount)
        }.value.map(\.dataURL)
        let result: GrsaiTextResponse
        switch interfaceMode {
        case .openAIChat:
            result = try await apiClient.chatCompletion(
                model: serviceModel,
                messages: [GrsaiChatMessage(content: prompt, imageDataURLs: images)],
                stream: chatStream,
                apiKey: credential,
                requestID: requestID
            )
        case .gemini, .geminiStream:
            result = try await apiClient.geminiContent(
                model: serviceModel,
                prompt: prompt,
                referenceImageDataURLs: images,
                generationConfigJSON: geminiGenerationConfigJSON,
                stream: interfaceMode == .geminiStream,
                apiKey: credential,
                requestID: requestID
            )
        default:
            throw GrsaiClientError.invalidInput("当前接口不支持文本请求")
        }
        let task = GenerationTask.textCompleted(id: result.id, requestID: requestID, prompt: prompt, interfaceMode: interfaceMode, serviceModel: serviceModel, text: result.text)
        tasks.insert(task, at: 0)
        try await historyStore.save(tasks)
        clearSubmittedDraft()
    }

    /// 根据扩展名为图片编辑请求选择安全的 MIME 类型。
    private func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": "image/jpeg"
        case "webp": "image/webp"
        default: "image/png"
        }
    }

    /// 将历史任务的文字和参数恢复到工作台，并按选择加载原图或生成图。
    func continueEditing(task: GenerationTask, source: HistoryEditSource) async {
        prompt = task.prompt
        if task.interfaceMode == .nativeImage || task.interfaceMode == .nativeVideo {
            interfaceMode = task.interfaceMode
            selectedModel = task.model
        } else {
            // 文本或兼容接口历史仍可读取，但继续编辑时统一回到图片模型。
            interfaceMode = .nativeImage
            selectedModel = .gptImage2
        }
        selectedAspectRatio = task.aspectRatio
        selectedImageSize = task.imageSize ?? .oneK
        selectedVideoResolution = task.videoResolution ?? .p768
        selectedVideoDuration = task.videoDuration ?? 5
        selectedVideoSeed = task.videoSeed
        referenceImageURLs = []

        switch source {
        case .original:
            let paths = (task.referenceImagePaths ?? []).filter {
                FileManager.default.fileExists(atPath: $0)
            }
            referenceImageURLs = paths.map(URL.init(fileURLWithPath:))
            if paths.isEmpty {
                alertMessage = "这条历史没有可用的原始参考图，请重新选择图片"
            }
        case .generated:
            let localPaths = task.localImagePaths.filter {
                FileManager.default.fileExists(atPath: $0)
            }
            if !localPaths.isEmpty {
                referenceImageURLs = localPaths
                    .prefix(task.model.isVideo ? ReferenceImageEncoder.maximumVideoImageCount : ReferenceImageEncoder.maximumImageCount)
                    .map(URL.init(fileURLWithPath:))
                return
            }

            do {
                var downloadedPaths: [String] = []
                for (index, url) in task.resultURLs.prefix(task.model.isVideo ? ReferenceImageEncoder.maximumVideoImageCount : ReferenceImageEncoder.maximumImageCount).enumerated() {
                    let path = try await imageStore.download(
                        url: url,
                        taskID: "\(task.id)-reference",
                        index: index + 1
                    )
                    downloadedPaths.append(path)
                }
                referenceImageURLs = downloadedPaths.map(URL.init(fileURLWithPath:))
                if downloadedPaths.isEmpty {
                    alertMessage = "这条历史没有可用的生成图"
                }
            } catch {
                present(error)
            }
        }
    }

    /// 清空历史和全部图片数据，只保留应用数据中的 API Key。
    func clearApplicationDataKeepingCredential() async {
        guard !isClearingData else { return }
        isClearingData = true
        defer { isClearingData = false }
        do {
            try await historyStore.clear()
            try await imageStore.clearCache()
            tasks = []
            alertMessage = "应用数据已清空，API Key 已保留"
        } catch {
            present(error)
        }
    }

    /// 删除指定任务的历史记录，并清理应用管理的本地结果图片。
    func deleteTask(id: String) async {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        let task = tasks.remove(at: index)
        do {
            try await historyStore.save(tasks)
        } catch {
            tasks.insert(task, at: index)
            present(error)
            return
        }

        pollingTaskIDs.remove(id)
        do {
            try await imageStore.delete(paths: task.localImagePaths + (task.referenceImagePaths ?? []))
        } catch {
            present(error)
        }
    }

    /// 为所有未完成任务恢复轮询，不重新提交生成请求。
    private func resumePendingTasks() {
        guard hasCredential else { return }
        for task in tasks where task.status == .running {
            startPolling(taskID: task.id)
        }
    }

    /// 为单个任务启动唯一轮询循环。
    private func startPolling(taskID: String) {
        guard !pollingTaskIDs.contains(taskID) else { return }
        pollingTaskIDs.insert(taskID)
        Task { [weak self] in
            await self?.poll(taskID: taskID)
        }
    }

    /// 只查询已有任务 ID，直到得到终态、凭据被清除或任务被取消。
    private func poll(taskID: String) async {
        defer { pollingTaskIDs.remove(taskID) }
        while !Task.isCancelled {
            guard let index = tasks.firstIndex(where: { $0.id == taskID }), tasks[index].status == .running else {
                return
            }
            guard let credential = await secretStore.read() else { return }
            do {
                try await Task.sleep(for: pollInterval)
                let response = try await apiClient.result(taskID: taskID, apiKey: credential)
                guard let currentIndex = tasks.firstIndex(where: { $0.id == taskID }) else { return }
                tasks[currentIndex].apply(response)
                try await historyStore.save(tasks)
                if response.status != .running {
                    await finishTaskIfNeeded(taskID: taskID)
                    return
                }
            } catch is CancellationError {
                return
            } catch {
                if let currentIndex = tasks.firstIndex(where: { $0.id == taskID }) {
                    tasks[currentIndex].errorMessage = error.localizedDescription
                    try? await historyStore.save(tasks)
                }
                try? await Task.sleep(for: retryInterval)
            }
        }
    }

    /// 下载成功任务的全部 HTTPS 结果，并持久化本地路径。
    private func finishTaskIfNeeded(taskID: String) async {
        guard let index = tasks.firstIndex(where: { $0.id == taskID }) else { return }
        guard tasks[index].status == .succeeded else { return }
        guard !tasks[index].resultURLs.isEmpty else { return }
        let localPaths = tasks[index].localImagePaths.filter {
            FileManager.default.fileExists(atPath: $0)
        }
        guard localPaths.count < tasks[index].resultURLs.count else { return }
        do {
            _ = try await ensureLocalResults(taskID: taskID)
        } catch {
            if let currentIndex = tasks.firstIndex(where: { $0.id == taskID }) {
                tasks[currentIndex].errorMessage = "结果已生成，但下载失败：\(error.localizedDescription)"
                try? await historyStore.save(tasks)
            }
        }
    }

    /// 确保任务结果已下载到本地，供视频预览和历史任务修复使用。
    func ensureLocalResults(taskID: String) async throws -> [String] {
        guard let index = tasks.firstIndex(where: { $0.id == taskID }) else {
            throw GrsaiClientError.invalidInput("任务不存在")
        }
        let task = tasks[index]
        let existingPaths = task.localImagePaths.filter {
            FileManager.default.fileExists(atPath: $0)
        }
        if existingPaths.count == task.resultURLs.count, !existingPaths.isEmpty {
            return existingPaths
        }
        guard !task.resultURLs.isEmpty else {
            throw GrsaiClientError.invalidResponse
        }

        var downloadedPaths: [String] = []
        for (resultIndex, url) in task.resultURLs.enumerated() {
            let path = try await imageStore.download(
                url: url,
                taskID: taskID,
                index: resultIndex + 1
            )
            downloadedPaths.append(path)
        }
        guard let currentIndex = tasks.firstIndex(where: { $0.id == taskID }) else {
            throw GrsaiClientError.invalidInput("任务不存在")
        }
        tasks[currentIndex].localImagePaths = downloadedPaths
        tasks[currentIndex].errorMessage = nil
        try await historyStore.save(tasks)
        return downloadedPaths
    }

    /// 把安全错误文本交给界面统一展示。
    private func present(_ error: Error) {
        alertMessage = error.localizedDescription
    }
}
