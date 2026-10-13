import Foundation

/// Grsai 当前支持的图片和视频模型。
enum GrsaiImageModel: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case nanoBanana = "nano-banana"
    case nanoBananaFast = "nano-banana-fast"
    case nanoBanana2 = "nano-banana-2"
    case nanoBanana2CL = "nano-banana-2-cl"
    case nanoBanana22KCL = "nano-banana-2-2k-cl"
    case nanoBanana24KCL = "nano-banana-2-4k-cl"
    case nanoBanana21 = "nano-banana-2.1"
    case nanoBananaPro = "nano-banana-pro"
    case nanoBananaProVT = "nano-banana-pro-vt"
    case nanoBananaProCL = "nano-banana-pro-cl"
    case nanoBananaProVIP = "nano-banana-pro-vip"
    case nanoBananaPro4KVIP = "nano-banana-pro-4k-vip"
    case gptImage2 = "gpt-image-2"
    case gptImage2VIP = "gpt-image-2-vip"
    case gptImage25 = "gpt-image-2.5"
    case gptImage25Flare = "gpt-image-2.5-flare"
    case gptImage25Sunburst = "gpt-image-2.5-sunburst"
    case minimaxH3 = "minimax-h3"
    case agnesVideo25 = "agnes-video-2.5"

    var id: String { rawValue }

    /// 判断模型是否属于异步视频生成模型。
    var isVideo: Bool { self == .minimaxH3 || self == .agnesVideo25 }

    /// 返回视频模型支持的分辨率。
    var supportedVideoResolutions: [GenerationVideoResolution] {
        self == .agnesVideo25 ? [.p720, .p1080, .p2K] : [.p480, .p768, .p1080]
    }

    /// 返回视频模型支持的时长范围。
    var videoDurationRange: ClosedRange<Int> { self == .agnesVideo25 ? 4...12 : 1...15 }

    /// 转换工作台比例为当前视频模型请求值。
    func videoAspectRatioValue(_ ratio: GenerationAspectRatio) -> String {
        self == .agnesVideo25 ? ratio.rawValue : ratio.videoRawValue
    }

    /// 判断模型是否属于 gpt-image-2 系列。
    var isGPTImage: Bool { rawValue.hasPrefix("gpt-image-2") }

    /// 判断模型是否只能使用自动或像素尺寸输出。
    var isGPTPremium: Bool {
        self == .gptImage2VIP || self == .gptImage25Flare || self == .gptImage25Sunburst
    }

    /// 根据 Grsai 文档返回当前模型在工作台中可直接选择的比例。
    var supportedAspectRatios: [GenerationAspectRatio] {
        if self == .minimaxH3 { return [.portrait, .landscape] }
        if self == .agnesVideo25 { return [.landscape, .portrait, .ultrawide, .fourThree, .square, .threeFour] }
        if isGPTPremium { return [.automatic] }
        if isGPTImage {
            return GenerationAspectRatio.allCases.filter {
                ![.oneThree, .threeOne, .oneFour, .fourOne, .oneEight, .eightOne].contains($0)
            }
        }
        let standard: [GenerationAspectRatio] = [
            .automatic, .square, .landscape, .portrait, .fourThree, .threeFour,
            .threeTwo, .twoThree, .fiveFour, .fourFive, .ultrawide
        ]
        return rawValue.hasPrefix("nano-banana-2")
            ? standard + [.oneFour, .fourOne, .oneEight, .eightOne]
            : standard
    }
}

/// 原生视频模型支持的输出分辨率。
enum GenerationVideoResolution: String, CaseIterable, Codable, Identifiable, Sendable {
    case p480 = "480p"
    case p720 = "720p"
    case p768 = "768p"
    case p1080 = "1080p"
    case p2K = "2k"

    var id: String { rawValue }

}

/// 任务结果的媒体类型，旧历史记录缺少该字段时按图片处理。
enum GenerationMediaType: String, Codable, Sendable {
    case image
    case video
    case text
}

/// 工作台对应的 Grsai 接口类型。
enum GenerationInterface: String, CaseIterable, Codable, Identifiable, Sendable {
    case nativeImage
    case nativeVideo
    case openAIImage
    case imageEdit
    case openAIChat
    case gemini
    case geminiStream

    var id: String { rawValue }

    /// 返回面向用户的接口名称，并附加英文能力标记。
    var displayName: String {
        switch self {
        case .nativeImage: "Native · Image"
        case .nativeVideo: "Native · Video"
        case .openAIImage: "OpenAI · Image"
        case .imageEdit: "Image Edit · Image"
        case .openAIChat: "OpenAI · Chat"
        case .gemini: "Gemini · Chat"
        case .geminiStream: "Gemini Stream · Chat"
        }
    }

    /// 返回接口产生的结果类型。
    var mediaType: GenerationMediaType {
        switch self {
        case .nativeVideo: .video
        case .openAIChat, .gemini, .geminiStream: .text
        default: .image
        }
    }
}

/// 工作台统一模型菜单中的原生图片和视频模型。
enum GenerationModelOption: Hashable, Identifiable, Sendable {
    case native(GrsaiImageModel)

    var id: String {
        switch self {
        case .native(let model): "native:\(model.rawValue)"
        }
    }

    /// 返回统一模型菜单中显示的原生模型名称。
    var displayName: String {
        switch self {
        case .native(let model): model.rawValue
        }
    }

    /// 图片模型分组。
    static var imageOptions: [GenerationModelOption] {
        GrsaiImageModel.allCases.filter { !$0.isVideo }.map(Self.native)
    }

    /// 视频模型分组。
    static var videoOptions: [GenerationModelOption] {
        GrsaiImageModel.allCases.filter(\.isVideo).map(Self.native)
    }

    /// 将原生模型转换为已有的请求协议类型。
    var interfaceMode: GenerationInterface {
        switch self {
        case .native(let model): model.isVideo ? .nativeVideo : .nativeImage
        }
    }

    /// 返回菜单选项对应的原生模型。
    var nativeModel: GrsaiImageModel {
        switch self {
        case .native(let model): model
        }
    }
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

    /// 返回 minimax-h3 使用的英文比例值。
    var videoRawValue: String {
        switch self {
        case .portrait: return "portrait"
        case .landscape: return "landscape"
        case .square: return "square"
        default: return "landscape"
        }
    }
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
    var referenceAudios: [String] = []
    var videoResolution: GenerationVideoResolution? = nil
    var videoDuration: Int? = nil
    var videoSeed: Int? = nil

    /// 在产生费用的请求前校验提示词和模型参数组合。
    func validated() throws -> GenerationDraft {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else {
            throw GrsaiClientError.invalidInput("请输入生图提示词")
        }
        guard trimmedPrompt.count <= 32_000 else {
            throw GrsaiClientError.invalidInput("提示词最多允许 32000 个字符")
        }
        if !model.isVideo && referenceImages.count > 8 {
            throw GrsaiClientError.invalidInput("参考图最多允许 8 张")
        }
        guard referenceImages.count <= 9 else {
            throw GrsaiClientError.invalidInput("视频参考图最多允许 9 张")
        }
        guard referenceAudios.count <= 3 else {
            throw GrsaiClientError.invalidInput("视频参考音频最多允许 3 个")
        }
        if model.isGPTImage, imageSize != nil {
            throw GrsaiClientError.invalidInput("gpt-image-2 系列不支持清晰度选项")
        }
        guard model.supportedAspectRatios.contains(aspectRatio) else {
            throw GrsaiClientError.invalidInput("当前模型不支持所选比例")
        }
        if model.isVideo {
            guard imageSize == nil else {
                throw GrsaiClientError.invalidInput("视频不支持图片清晰度选项")
            }
            guard videoResolution != nil, videoDuration != nil else {
                throw GrsaiClientError.invalidInput("视频必须选择分辨率和时长")
            }
            if let resolution = videoResolution, !model.supportedVideoResolutions.contains(resolution) {
                throw GrsaiClientError.invalidInput("当前视频模型不支持所选分辨率")
            }
            if let duration = videoDuration {
                guard model.videoDurationRange.contains(duration) else {
                    throw GrsaiClientError.invalidInput("当前视频模型不支持所选时长")
                }
                if model == .minimaxH3 && videoResolution == .p1080 && duration > 10 {
                    throw GrsaiClientError.invalidInput("1080p 视频时长最多 10 秒")
                }
            }
        } else if !referenceAudios.isEmpty || videoResolution != nil || videoDuration != nil || videoSeed != nil {
            throw GrsaiClientError.invalidInput("视频参数只适用于视频模型")
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
    let errorMessage: String?

    init(
        id: String,
        status: GenerationStatus,
        progress: Int?,
        results: [GenerationOutput],
        errorMessage: String? = nil
    ) {
        self.id = id
        self.status = status
        self.progress = progress
        self.results = results
        self.errorMessage = errorMessage
    }
}

/// 可跨应用重启恢复的生图任务记录。
struct GenerationTask: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let requestID: UUID
    let prompt: String
    let model: GrsaiImageModel
    /// 历史任务使用的接口模式；旧记录默认按模型推断。
    var interfaceMode: GenerationInterface
    /// Chat/Gemini 等接口实际发送的模型名。
    var serviceModel: String?
    var mediaType: GenerationMediaType
    let aspectRatio: GenerationAspectRatio
    let imageSize: GenerationImageSize?
    let videoResolution: GenerationVideoResolution?
    let videoDuration: Int?
    let videoSeed: Int?
    let referenceImageNames: [String]
    /// 为历史继续编辑保留的应用内原始参考图副本路径；旧记录缺少该字段时为空。
    var referenceImagePaths: [String]?
    var status: GenerationStatus
    var progress: Int?
    var resultURLs: [URL]
    var localImagePaths: [String]
    /// 文本接口的累积响应内容。
    var textResult: String?
    var errorMessage: String?
    let createdAt: Date
    var updatedAt: Date

    private enum CodingKeys: String, CodingKey {
        case id, requestID, prompt, model, interfaceMode, serviceModel, mediaType, aspectRatio, imageSize
        case videoResolution, videoDuration, videoSeed
        case referenceImageNames, referenceImagePaths, status, progress
        case resultURLs, localImagePaths, textResult, errorMessage, createdAt, updatedAt
    }

    /// 创建一条完整的任务历史记录。
    init(
        id: String,
        requestID: UUID,
        prompt: String,
        model: GrsaiImageModel,
        interfaceMode: GenerationInterface = .nativeImage,
        serviceModel: String? = nil,
        mediaType: GenerationMediaType,
        aspectRatio: GenerationAspectRatio,
        imageSize: GenerationImageSize?,
        videoResolution: GenerationVideoResolution?,
        videoDuration: Int?,
        videoSeed: Int?,
        referenceImageNames: [String],
        referenceImagePaths: [String]?,
        status: GenerationStatus,
        progress: Int?,
        resultURLs: [URL],
        localImagePaths: [String],
        textResult: String? = nil,
        errorMessage: String?,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.requestID = requestID
        self.prompt = prompt
        self.model = model
        self.interfaceMode = interfaceMode
        self.serviceModel = serviceModel
        self.mediaType = mediaType
        self.aspectRatio = aspectRatio
        self.imageSize = imageSize
        self.videoResolution = videoResolution
        self.videoDuration = videoDuration
        self.videoSeed = videoSeed
        self.referenceImageNames = referenceImageNames
        self.referenceImagePaths = referenceImagePaths
        self.status = status
        self.progress = progress
        self.resultURLs = resultURLs
        self.localImagePaths = localImagePaths
        self.textResult = textResult
        self.errorMessage = errorMessage
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// 兼容没有媒体类型字段的历史任务记录。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        requestID = try container.decode(UUID.self, forKey: .requestID)
        prompt = try container.decode(String.self, forKey: .prompt)
        model = try container.decode(GrsaiImageModel.self, forKey: .model)
        interfaceMode = try container.decodeIfPresent(GenerationInterface.self, forKey: .interfaceMode)
            ?? (model.isVideo ? .nativeVideo : .nativeImage)
        serviceModel = try container.decodeIfPresent(String.self, forKey: .serviceModel)
        mediaType = try container.decodeIfPresent(GenerationMediaType.self, forKey: .mediaType) ?? (model.isVideo ? .video : .image)
        aspectRatio = try container.decode(GenerationAspectRatio.self, forKey: .aspectRatio)
        imageSize = try container.decodeIfPresent(GenerationImageSize.self, forKey: .imageSize)
        videoResolution = try container.decodeIfPresent(GenerationVideoResolution.self, forKey: .videoResolution)
        videoDuration = try container.decodeIfPresent(Int.self, forKey: .videoDuration)
        videoSeed = try container.decodeIfPresent(Int.self, forKey: .videoSeed)
        referenceImageNames = try container.decode([String].self, forKey: .referenceImageNames)
        referenceImagePaths = try container.decodeIfPresent([String].self, forKey: .referenceImagePaths)
        status = try container.decode(GenerationStatus.self, forKey: .status)
        progress = try container.decodeIfPresent(Int.self, forKey: .progress)
        resultURLs = try container.decode([URL].self, forKey: .resultURLs)
        localImagePaths = try container.decode([String].self, forKey: .localImagePaths)
        textResult = try container.decodeIfPresent(String.self, forKey: .textResult)
        errorMessage = try container.decodeIfPresent(String.self, forKey: .errorMessage)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }

    /// 用首次提交结果创建可立即持久化的任务记录。
    static func submitted(
        response: GenerationResponse,
        requestID: UUID,
        draft: GenerationDraft,
        referenceImagePaths: [String] = [],
        now: Date = Date()
    ) -> GenerationTask {
        GenerationTask(
            id: response.id,
            requestID: requestID,
            prompt: draft.prompt,
            model: draft.model,
            interfaceMode: draft.model.isVideo ? .nativeVideo : .nativeImage,
            mediaType: draft.model.isVideo ? GenerationMediaType.video : GenerationMediaType.image,
            aspectRatio: draft.aspectRatio,
            imageSize: draft.imageSize,
            videoResolution: draft.videoResolution,
            videoDuration: draft.videoDuration,
            videoSeed: draft.videoSeed,
            referenceImageNames: draft.referenceImages.map(\.fileName),
            referenceImagePaths: referenceImagePaths,
            status: response.status,
            progress: response.progress,
            resultURLs: response.results.map(\.url),
            localImagePaths: [],
            textResult: nil,
            errorMessage: response.errorMessage,
            createdAt: now,
            updatedAt: now
        )
    }

    /// 创建同步图片或文本接口的历史记录。
    static func completed(
        response: GenerationResponse,
        requestID: UUID,
        prompt: String,
        model: GrsaiImageModel = .gptImage2,
        interfaceMode: GenerationInterface,
        serviceModel: String?,
        now: Date = Date()
    ) -> GenerationTask {
        GenerationTask(
            id: response.id,
            requestID: requestID,
            prompt: prompt,
            model: model,
            interfaceMode: interfaceMode,
            serviceModel: serviceModel,
            mediaType: interfaceMode.mediaType,
            aspectRatio: .automatic,
            imageSize: nil,
            videoResolution: nil,
            videoDuration: nil,
            videoSeed: nil,
            referenceImageNames: [],
            referenceImagePaths: nil,
            status: response.status,
            progress: response.progress,
            resultURLs: response.results.map(\.url),
            localImagePaths: [],
            textResult: nil,
            errorMessage: response.errorMessage,
            createdAt: now,
            updatedAt: now
        )
    }

    /// 创建 Chat 或 Gemini 文本接口的历史记录。
    static func textCompleted(
        id: String,
        requestID: UUID,
        prompt: String,
        interfaceMode: GenerationInterface,
        serviceModel: String,
        text: String,
        now: Date = Date()
    ) -> GenerationTask {
        GenerationTask(
            id: id,
            requestID: requestID,
            prompt: prompt,
            model: .gptImage2,
            interfaceMode: interfaceMode,
            serviceModel: serviceModel,
            mediaType: .text,
            aspectRatio: .automatic,
            imageSize: nil,
            videoResolution: nil,
            videoDuration: nil,
            videoSeed: nil,
            referenceImageNames: [],
            referenceImagePaths: nil,
            status: .succeeded,
            progress: 100,
            resultURLs: [],
            localImagePaths: [],
            textResult: text,
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
        errorMessage = response.errorMessage
        updatedAt = now
    }
}
