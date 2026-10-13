import Testing
@testable import GrsaiCanvasApp

@Suite("生图参数校验")
struct GenerationDraftTests {
    @Test("拒绝空提示词和不兼容清晰度")
    func rejectsInvalidInputs() {
        let empty = GenerationDraft(
            prompt: "  ",
            model: .gptImage2,
            aspectRatio: .automatic,
            imageSize: nil,
            referenceImages: []
        )
        #expect(throws: GrsaiClientError.self) { try empty.validated() }

        let incompatible = GenerationDraft(
            prompt: "一只猫",
            model: .gptImage2,
            aspectRatio: .square,
            imageSize: .twoK,
            referenceImages: []
        )
        #expect(throws: GrsaiClientError.self) { try incompatible.validated() }
    }

    @Test("nano-banana 接受清晰度并清理提示词")
    func acceptsNanoBananaSize() throws {
        let draft = GenerationDraft(
            prompt: "  海边灯塔  ",
            model: .nanoBanana2,
            aspectRatio: .landscape,
            imageSize: .twoK,
            referenceImages: []
        )

        let validated = try draft.validated()

        #expect(validated.prompt == "海边灯塔")
        #expect(validated.imageSize == .twoK)
    }

    /// 验证新增 GPT Premium 模型只允许工作台直接选择自动比例。
    @Test("GPT 2.5 Premium 过滤不支持的比例")
    func rejectsUnsupportedPremiumRatio() {
        let valid = GenerationDraft(
            prompt: "透明产品图",
            model: .gptImage25Sunburst,
            aspectRatio: .automatic,
            imageSize: nil,
            referenceImages: []
        )
        let invalid = GenerationDraft(
            prompt: "透明产品图",
            model: .gptImage25Sunburst,
            aspectRatio: .landscape,
            imageSize: nil,
            referenceImages: []
        )

        #expect(throws: Never.self) { try valid.validated() }
        #expect(throws: GrsaiClientError.self) { try invalid.validated() }
    }

    /// 验证 minimax-h3 的视频参数和时长上限。
    @Test("minimax-h3 接受视频参数并限制 1080p 时长")
    func validatesVideoParameters() throws {
        let valid = GenerationDraft(
            prompt: "镜头推进",
            model: .minimaxH3,
            aspectRatio: .portrait,
            imageSize: nil,
            referenceImages: [],
            videoResolution: .p1080,
            videoDuration: 10,
            videoSeed: 42
        )
        let invalid = GenerationDraft(
            prompt: "镜头推进",
            model: .minimaxH3,
            aspectRatio: .landscape,
            imageSize: nil,
            referenceImages: [],
            videoResolution: .p1080,
            videoDuration: 11
        )

        #expect(throws: Never.self) { try valid.validated() }
        #expect(throws: GrsaiClientError.self) { try invalid.validated() }
    }

    /// 验证新增图片模型使用 nano-banana-2 系列额外比例。
    @Test("nano-banana-2.1 支持 1:8 比例")
    func validatesNanoBanana21Ratio() throws {
        let draft = GenerationDraft(
            prompt: "长卷山水", model: .nanoBanana21, aspectRatio: .oneEight,
            imageSize: .twoK, referenceImages: []
        )
        #expect(throws: Never.self) { try draft.validated() }
    }

    /// 验证 agnes 视频的专有比例、分辨率和时长边界。
    @Test("agnes-video-2.5 校验视频参数")
    func validatesAgnesVideoParameters() throws {
        let valid = GenerationDraft(
            prompt: "海边日落", model: .agnesVideo25, aspectRatio: .ultrawide,
            imageSize: nil, referenceImages: [], videoResolution: .p2K, videoDuration: 12
        )
        let wrongRatio = GenerationDraft(
            prompt: "海边日落", model: .agnesVideo25, aspectRatio: .automatic,
            imageSize: nil, referenceImages: [], videoResolution: .p720, videoDuration: 5
        )
        let wrongDuration = GenerationDraft(
            prompt: "海边日落", model: .agnesVideo25, aspectRatio: .landscape,
            imageSize: nil, referenceImages: [], videoResolution: .p720, videoDuration: 3
        )
        #expect(throws: Never.self) { try valid.validated() }
        #expect(throws: GrsaiClientError.self) { try wrongRatio.validated() }
        #expect(throws: GrsaiClientError.self) { try wrongDuration.validated() }
        #expect(GrsaiImageModel.agnesVideo25.videoAspectRatioValue(.ultrawide) == "21:9")
    }
}
