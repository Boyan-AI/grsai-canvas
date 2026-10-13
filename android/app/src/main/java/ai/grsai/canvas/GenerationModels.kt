package ai.grsai.canvas

/** Android 端支持的生图模型。 */
enum class GrsaiImageModel(val value: String) {
    GPT_IMAGE_2("gpt-image-2"),
    GPT_IMAGE_2_VIP("gpt-image-2-vip"),
    GPT_IMAGE_2_5("gpt-image-2.5"),
    GPT_IMAGE_2_5_FLARE("gpt-image-2.5-flare"),
    GPT_IMAGE_2_5_SUNBURST("gpt-image-2.5-sunburst"),
    MINIMAX_H3("minimax-h3"),
    AGNES_VIDEO_2_5("agnes-video-2.5"),
    NANO_BANANA("nano-banana"),
    NANO_BANANA_2("nano-banana-2"),
    NANO_BANANA_2_1("nano-banana-2.1"),
    NANO_BANANA_PRO("nano-banana-pro")

    ;

    /** 区分使用视频字段和图片字段的原生模型。 */
    val isVideo: Boolean get() = this == MINIMAX_H3 || this == AGNES_VIDEO_2_5

    /** 返回当前视频模型支持的比例。 */
    val videoAspectRatios: List<String> get() = if (this == AGNES_VIDEO_2_5) listOf("16:9", "9:16", "21:9", "4:3", "1:1", "3:4") else listOf("landscape", "portrait")

    /** 返回当前视频模型支持的分辨率。 */
    val videoResolutions: List<String> get() = if (this == AGNES_VIDEO_2_5) listOf("720p", "1080p", "2k") else listOf("480p", "768p", "1080p")

    /** 返回当前视频模型支持的时长范围。 */
    val videoDurationRange: IntRange get() = if (this == AGNES_VIDEO_2_5) 4..12 else 1..15
}

/** 生成结果的媒体类型，旧历史记录默认按图片处理。 */
enum class GenerationMediaType { IMAGE, VIDEO, TEXT }

/** Android 工作台支持的全部 Grsai 接口模式。 */
enum class GenerationInterface(val title: String) {
    NATIVE_IMAGE("原生图片"),
    NATIVE_VIDEO("原生视频"),
    OPENAI_IMAGE("OpenAI 图片"),
    IMAGE_EDIT("图片编辑"),
    OPENAI_CHAT("OpenAI Chat"),
    GEMINI("Gemini"),
    GEMINI_STREAM("Gemini 流式")
}

/** 生成任务的持久化状态。 */
enum class GenerationStatus { RUNNING, VIOLATION, SUCCEEDED, FAILED }

/** Android 端历史任务记录。 */
data class GenerationTask(
    val id: String,
    val prompt: String,
    val model: GrsaiImageModel,
    val interfaceMode: GenerationInterface = if (model.isVideo) GenerationInterface.NATIVE_VIDEO else GenerationInterface.NATIVE_IMAGE,
    val serviceModel: String? = null,
    val mediaType: GenerationMediaType = if (model.isVideo) GenerationMediaType.VIDEO else GenerationMediaType.IMAGE,
    val status: GenerationStatus = GenerationStatus.RUNNING,
    val progress: Int? = null,
    val resultUrls: List<String> = emptyList(),
    val referenceUris: List<String> = emptyList(),
    val localImagePaths: List<String> = emptyList(),
    val textResult: String? = null,
    val aspectRatio: String = "auto",
    val resolution: String? = null,
    val duration: Int? = null,
    val seed: Int? = null,
    val createdAt: Long = System.currentTimeMillis(),
    val errorMessage: String? = null
)
