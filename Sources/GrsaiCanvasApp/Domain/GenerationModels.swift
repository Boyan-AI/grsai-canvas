import Foundation

/// Grsai 当前支持的图片模型。
enum GrsaiImageModel: String, CaseIterable, Codable, Identifiable, Sendable {
    case nanoBanana = "nano-banana"
    case nanoBananaFast = "nano-banana-fast"
    case nanoBanana2 = "nano-banana-2"
    case nanoBanana2CL = "nano-banana-2-cl"
    case nanoBanana22KCL = "nano-banana-2-2k-cl"
    case nanoBanana24KCL = "nano-banana-2-4k-cl"
    case nanoBananaPro = "nano-banana-pro"
    case nanoBananaProVT = "nano-banana-pro-vt"
    case nanoBananaProCL = "nano-banana-pro-cl"
    case nanoBananaProVIP = "nano-banana-pro-vip"
    case nanoBananaPro4KVIP = "nano-banana-pro-4k-vip"
    case gptImage2 = "gpt-image-2"
    case gptImage2VIP = "gpt-image-2-vip"

    var id: String { rawValue }

    /// 判断模型是否属于 gpt-image-2 系列。
    var isGPTImage: Bool { rawValue.hasPrefix("gpt-image-2") }
}

/// 原生接口支持的图片比例。
enum GenerationAspectRatio: String, CaseIterable, Codable, Identifiable, Sendable {
    case automatic = "auto"
    case square = "1:1"
    case landscape = "16:9"
    case portrait = "9:16"
    case fourThree = "4:3"
    case threeFour = "3:4"
    case threeTwo = "3:2"
    case twoThree = "2:3"
    case fiveFour = "5:4"
    case fourFive = "4:5"
    case ultrawide = "21:9"
    case ultraPortrait = "9:21"
    case oneTwo = "1:2"
    case twoOne = "2:1"
    case oneThree = "1:3"
    case threeOne = "3:1"
    case oneFour = "1:4"
    case fourOne = "4:1"
    case oneEight = "1:8"
    case eightOne = "8:1"

    var id: String { rawValue }
}

/// nano-banana 系列支持的输出清晰度。
enum GenerationImageSize: String, CaseIterable, Codable, Identifiable, Sendable {
    case oneK = "1K"
    case twoK = "2K"
    case fourK = "4K"

    var id: String { rawValue }
}

/// 已校验并可发送给 Grsai 的单张参考图。
struct ReferenceImagePayload: Codable, Equatable, Sendable {
    let fileName: String
    let dataURL: String
}

/// 用户一次生图操作的稳定输入。
struct GenerationDraft: Equatable, Sendable {
    var prompt: String
    var model: GrsaiImageModel
    var aspectRatio: GenerationAspectRatio
    var imageSize: GenerationImageSize?
    var referenceImages: [ReferenceImagePayload]

    /// 在产生费用的请求前校验提示词和模型参数组合。
    func validated() throws -> GenerationDraft {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else {
            throw GrsaiClientError.invalidInput("请输入生图提示词")
        }
        guard trimmedPrompt.count <= 32_000 else {
            throw GrsaiClientError.invalidInput("提示词最多允许 32000 个字符")
        }
        guard referenceImages.count <= 8 else {
            throw GrsaiClientError.invalidInput("参考图最多允许 8 张")
        }
        if model.isGPTImage, imageSize != nil {
            throw GrsaiClientError.invalidInput("gpt-image-2 系列不支持清晰度选项")
        }
        var copy = self
        copy.prompt = trimmedPrompt
        return copy
    }
}

/// 原生异步任务的标准状态。
enum GenerationStatus: String, Codable, Sendable {
    case running
    case violation
    case succeeded
    case failed
}

/// Grsai 返回的单张结果图片地址。
struct GenerationOutput: Codable, Equatable, Sendable {
    let url: URL
}

/// 一次提交或查询返回的标准任务结果。
struct GenerationResponse: Codable, Equatable, Sendable {
    let id: String
    let status: GenerationStatus
    let progress: Int?
    let results: [GenerationOutput]
}

/// 可跨应用重启恢复的生图任务记录。
struct GenerationTask: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let requestID: UUID
    let prompt: String
    let model: GrsaiImageModel
    let aspectRatio: GenerationAspectRatio
    let imageSize: GenerationImageSize?
    let referenceImageNames: [String]
    var status: GenerationStatus
    var progress: Int?
    var resultURLs: [URL]
    var localImagePaths: [String]
    var errorMessage: String?
    let createdAt: Date
    var updatedAt: Date

    /// 用首次提交结果创建可立即持久化的任务记录。
    static func submitted(
        response: GenerationResponse,
        requestID: UUID,
        draft: GenerationDraft,
        now: Date = Date()
    ) -> GenerationTask {
        GenerationTask(
            id: response.id,
            requestID: requestID,
            prompt: draft.prompt,
            model: draft.model,
            aspectRatio: draft.aspectRatio,
            imageSize: draft.imageSize,
            referenceImageNames: draft.referenceImages.map(\.fileName),
            status: response.status,
            progress: response.progress,
            resultURLs: response.results.map(\.url),
            localImagePaths: [],
            errorMessage: nil,
            createdAt: now,
            updatedAt: now
        )
    }

    /// 把同一任务 ID 的最新查询结果合并到历史记录。
    mutating func apply(_ response: GenerationResponse, now: Date = Date()) {
        guard response.id == id else { return }
        status = response.status
        progress = response.progress
        resultURLs = response.results.map(\.url)
        updatedAt = now
    }
}
