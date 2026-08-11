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
}
