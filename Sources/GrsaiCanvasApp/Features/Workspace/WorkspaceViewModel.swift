import Foundation
import Observation

/// 编排工作台输入、付费提交、同任务轮询、结果下载与历史持久化。
@MainActor
@Observable
final class WorkspaceViewModel {
    var tasks: [GenerationTask] = []
    var prompt = ""
    var selectedModel: GrsaiImageModel = .gptImage2
    var selectedAspectRatio: GenerationAspectRatio = .automatic
    var selectedImageSize: GenerationImageSize = .oneK
    var referenceImageURLs: [URL] = []
    var credentialInput = ""
    var hasCredential = false
    var isSubmitting = false
    var isFileImporterPresented = false
    var alertMessage: String?

    private let apiClient: GrsaiAPIClient
    private let historyStore: GenerationHistoryStore
    private let imageStore: ResultImageStore
    private let secretStore: any SecretStore
    private let pollInterval: Duration
    private let retryInterval: Duration
    private var pollingTaskIDs: Set<String> = []

    /// 注入所有外部副作用，默认值连接生产 Grsai 节点与本地存储。
    init(
        apiClient: GrsaiAPIClient = GrsaiAPIClient(),
        historyStore: GenerationHistoryStore = GenerationHistoryStore(),
        imageStore: ResultImageStore = ResultImageStore(),
        secretStore: any SecretStore = SessionSecretStore(),
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
    }

    /// 加载历史和会话凭据，并恢复同一任务 ID 的查询。
    func load() async {
        do {
            tasks = try await historyStore.load().sorted { $0.createdAt > $1.createdAt }
            hasCredential = await secretStore.read() != nil
            resumePendingTasks()
        } catch {
            present(error)
        }
    }

    /// 保存当前会话凭据，不写入文件或 UserDefaults。
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

    /// 清除当前会话凭据并停止新提交。
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
        referenceImageURLs = Array(merged.prefix(ReferenceImageEncoder.maximumImageCount))
        if candidates.count != urls.count {
            alertMessage = "已忽略非 JPG、JPEG、PNG 或 WEBP 文件"
        } else if merged.count > ReferenceImageEncoder.maximumImageCount {
            alertMessage = "参考图最多允许 8 张"
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
            let urls = referenceImageURLs
            let images = try await Task.detached {
                try ReferenceImageEncoder.encode(urls: urls)
            }.value
            let draft = try GenerationDraft(
                prompt: prompt,
                model: selectedModel,
                aspectRatio: selectedAspectRatio,
                imageSize: selectedModel.isGPTImage ? nil : selectedImageSize,
                referenceImages: images
            ).validated()
            let requestID = UUID()
            let response = try await apiClient.submit(
                draft: draft,
                apiKey: credential,
                requestID: requestID
            )
            let task = GenerationTask.submitted(
                response: response,
                requestID: requestID,
                draft: draft
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
                tasks[currentIndex].errorMessage = nil
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
        guard tasks[index].status == .succeeded, tasks[index].localImagePaths.isEmpty else { return }
        let urls = tasks[index].resultURLs
        var paths: [String] = []
        do {
            for (resultIndex, url) in urls.enumerated() {
                let path = try await imageStore.download(url: url, taskID: taskID, index: resultIndex + 1)
                paths.append(path)
            }
            guard let currentIndex = tasks.firstIndex(where: { $0.id == taskID }) else { return }
            tasks[currentIndex].localImagePaths = paths
            tasks[currentIndex].errorMessage = nil
            try await historyStore.save(tasks)
        } catch {
            if let currentIndex = tasks.firstIndex(where: { $0.id == taskID }) {
                tasks[currentIndex].errorMessage = "结果已生成，但下载失败：\(error.localizedDescription)"
                try? await historyStore.save(tasks)
            }
        }
    }

    /// 把安全错误文本交给界面统一展示。
    private func present(_ error: Error) {
        alertMessage = error.localizedDescription
    }
}
