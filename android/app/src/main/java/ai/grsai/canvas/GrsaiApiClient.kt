package ai.grsai.canvas

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.util.UUID

/** 文本接口的统一响应。 */
data class GrsaiTextResponse(val id: String, val text: String)

/** 使用系统 HTTPS 能力调用 Grsai，避免首版引入额外网络依赖。 */
class GrsaiApiClient(private val baseUrl: String = "https://grsai.dakka.com.cn") {
    init {
        require(baseUrl.startsWith("https://")) { "Grsai 节点必须使用 HTTPS" }
    }
    /** 校验模型参数并提交一次原生异步生成任务。 */
    suspend fun submit(
        apiKey: String,
        prompt: String,
        model: GrsaiImageModel,
        referenceImages: List<String> = emptyList(),
        aspectRatio: String = if (model == GrsaiImageModel.AGNES_VIDEO_2_5) "16:9" else if (model.isVideo) "landscape" else "auto",
        imageSize: String? = null,
        resolution: String? = null,
        duration: Int? = null,
        seed: Int? = null,
        referenceAudios: List<String> = emptyList()
    ): GenerationTask =
        withContext(Dispatchers.IO) {
            if (model.isVideo) {
                require(imageSize == null) { "视频不支持图片清晰度" }
                require(aspectRatio in model.videoAspectRatios) { "当前视频模型不支持所选比例" }
                val selectedResolution = resolution ?: if (model == GrsaiImageModel.AGNES_VIDEO_2_5) "720p" else "768p"
                require(selectedResolution in model.videoResolutions) { "当前视频模型不支持所选分辨率" }
                require((duration ?: 5) in model.videoDurationRange) { "当前视频模型不支持所选时长" }
                if (model == GrsaiImageModel.MINIMAX_H3 && selectedResolution == "1080p") require((duration ?: 5) <= 10) { "1080p 视频时长最多 10 秒" }
                require(referenceImages.size <= 9) { "视频参考图最多允许 9 张" }
                require(referenceAudios.size <= 3) { "视频参考音频最多允许 3 个" }
            } else {
                require(referenceImages.size <= 8) { "参考图最多允许 8 张" }
                require(aspectRatio in model.imageAspectRatios) { "当前图片模型不支持所选比例" }
                require(imageSize == null || (!model.isGptImage && imageSize in setOf("1K", "2K", "4K"))) { "当前图片模型不支持所选清晰度" }
                require(referenceAudios.isEmpty() && resolution == null && duration == null && seed == null) { "视频参数只适用于视频模型" }
            }
            val body = JSONObject()
                .put("model", model.value)
                .put("prompt", prompt)
                .put("replyType", "async")
                .put("aspectRatio", aspectRatio)
                .put("images", org.json.JSONArray(referenceImages).takeIf { referenceImages.isNotEmpty() })
                .apply {
                    imageSize?.let { put("imageSize", it) }
                    if (model.isVideo) {
                        put("resolution", resolution ?: if (model == GrsaiImageModel.AGNES_VIDEO_2_5) "720p" else "768p")
                        put("duration", duration ?: 5)
                        if (referenceAudios.isNotEmpty()) put("audios", org.json.JSONArray(referenceAudios))
                        seed?.let { put("seed", it) }
                    }
                }
            val response = payload(request("/v1/api/generate", apiKey, body, "POST"))
            val id = response.optString("id").ifBlank { response.optString("task_id") }
            require(id.isNotBlank()) { "Grsai 未返回任务 ID" }
            GenerationTask(
                id = id,
                prompt = prompt,
                model = model,
                mediaType = if (model.isVideo) GenerationMediaType.VIDEO else GenerationMediaType.IMAGE,
                aspectRatio = aspectRatio,
                imageSize = imageSize,
                resolution = resolution,
                duration = duration,
                seed = seed
            )
        }

    suspend fun query(apiKey: String, taskId: String, current: GenerationTask): GenerationTask =
        withContext(Dispatchers.IO) {
            val response = payload(request("/v1/api/result?id=${java.net.URLEncoder.encode(taskId, "UTF-8")}", apiKey, null, "GET"))
            val status = when (response.optString("status").lowercase()) {
                "succeeded", "success", "completed" -> GenerationStatus.SUCCEEDED
                "failed", "error" -> GenerationStatus.FAILED
                "violation" -> GenerationStatus.VIOLATION
                else -> GenerationStatus.RUNNING
            }
            val urls = buildList {
                response.optJSONArray("results")?.let { array ->
                    for (index in 0 until array.length()) add(array.optJSONObject(index)?.optString("url").orEmpty())
                }
                response.optString("url").takeIf { it.isNotBlank() }?.let(::add)
            }.filter { it.startsWith("https://") }
            val serverError = response.optString("error").takeIf { it.isNotBlank() }
            current.copy(
                mediaType = if (current.model.isVideo) GenerationMediaType.VIDEO else current.mediaType,
                status = status,
                progress = response.optInt("progress", -1).takeIf { it >= 0 },
                resultUrls = urls,
                errorMessage = serverError?.let(::friendlyError)
            )
        }

    /** 调用 OpenAI 兼容图片生成接口。 */
    suspend fun openAIImage(
        apiKey: String,
        prompt: String,
        model: String,
        quality: String? = null,
        background: String? = null
    ): GenerationTask = withContext(Dispatchers.IO) {
        require(prompt.trim().isNotEmpty()) { "提示词不能为空" }
        val body = JSONObject().apply {
            put("model", model)
            put("prompt", prompt.trim())
            put("n", 1)
            quality?.let { put("quality", it) }
            background?.let { put("background", it) }
        }
        val response = request("/v1/images/generations", apiKey, body, "POST")
        imageTask(response, prompt, model, GenerationInterface.OPENAI_IMAGE)
    }

    /** 调用 OpenAI 兼容图片编辑 multipart 接口。 */
    suspend fun editImage(
        apiKey: String,
        prompt: String,
        model: String,
        image: ByteArray,
        fileName: String,
        mimeType: String,
        quality: String? = null,
        background: String? = null
    ): GenerationTask = withContext(Dispatchers.IO) {
        require(image.isNotEmpty()) { "编辑图片不能为空" }
        val boundary = "Boundary-${UUID.randomUUID()}"
        val body = MultipartBuilder(boundary).apply {
            field("model", model)
            field("prompt", prompt.trim())
            quality?.let { field("quality", it) }
            background?.let { field("background", it) }
            file("image", fileName, mimeType, image)
        }.build()
        val response = JSONObject(rawRequest("/v1/images/edits", apiKey, body, "POST", "multipart/form-data; boundary=$boundary"))
        imageTask(response, prompt, model, GenerationInterface.IMAGE_EDIT)
    }

    /** 调用 OpenAI Chat，流式响应在本地合并 SSE 增量。 */
    suspend fun chatCompletion(
        apiKey: String,
        model: String,
        prompt: String,
        referenceImages: List<String> = emptyList(),
        stream: Boolean = false
    ): GrsaiTextResponse = withContext(Dispatchers.IO) {
        val content: Any = if (referenceImages.isEmpty()) prompt else JSONArray().apply {
            put(JSONObject().put("type", "text").put("text", prompt))
            referenceImages.forEach { put(JSONObject().put("type", "image_url").put("image_url", JSONObject().put("url", it))) }
        }
        val messages = JSONArray().put(JSONObject().put("role", "user").put("content", content))
        val body = JSONObject().put("model", model).put("messages", messages).put("stream", stream)
        val response = rawRequest("/v1/chat/completions", apiKey, body.toString().toByteArray(Charsets.UTF_8), "POST", "application/json")
        val text = if (stream) parseChatStream(response) else JSONObject(response).optJSONArray("choices")
            ?.optJSONObject(0)?.optJSONObject("message")?.optString("content").orEmpty()
        require(text.isNotBlank()) { "Chat 未返回文本" }
        val responseID = if (stream) "chat-${UUID.randomUUID()}" else JSONObject(response).optString("id").ifBlank { "chat-${UUID.randomUUID()}" }
        GrsaiTextResponse(responseID, text)
    }

    /** 调用 Gemini 普通或流式 generateContent 接口。 */
    suspend fun geminiContent(
        apiKey: String,
        model: String,
        prompt: String,
        referenceImages: List<String> = emptyList(),
        generationConfigJson: String = "{}",
        stream: Boolean = false
    ): GrsaiTextResponse = withContext(Dispatchers.IO) {
        val parts = JSONArray().put(JSONObject().put("text", prompt))
        referenceImages.forEach { dataUrl ->
            val pieces = dataUrl.split(',', limit = 2)
            if (pieces.size == 2 && pieces[0].startsWith("data:")) {
                val mime = pieces[0].substringAfter("data:").substringBefore(';')
                parts.put(JSONObject().put("inlineData", JSONObject().put("mimeType", mime).put("data", pieces[1])))
            }
        }
        val body = JSONObject().put("contents", JSONArray().put(JSONObject().put("role", "user").put("parts", parts)))
        runCatching { JSONObject(generationConfigJson) }.getOrNull()?.takeIf { it.length() > 0 }?.let { body.put("generationConfig", it) }
        val operation = if (stream) "streamGenerateContent" else "generateContent"
        val response = rawRequest("/v1beta/models/$model:$operation", apiKey, body.toString().toByteArray(Charsets.UTF_8), "POST", "application/json")
        val text = if (stream) parseGeminiStream(response) else parseGemini(JSONObject(response))
        require(text.isNotBlank()) { "Gemini 未返回文本" }
        GrsaiTextResponse("gemini-${UUID.randomUUID()}", text)
    }

    /** 把同步图片响应转换成统一历史任务。 */
    private fun imageTask(response: JSONObject, prompt: String, model: String, mode: GenerationInterface): GenerationTask {
        val urls = buildList {
            response.optJSONArray("data")?.let { array ->
                for (index in 0 until array.length()) {
                    val item = array.optJSONObject(index) ?: continue
                    item.optString("url").takeIf { it.startsWith("https://") }?.let(::add)
                }
            }
        }
        require(urls.isNotEmpty()) { "图片接口未返回 HTTPS 结果地址" }
        return GenerationTask(
            id = response.optString("id").ifBlank { "image-${UUID.randomUUID()}" },
            prompt = prompt,
            model = GrsaiImageModel.GPT_IMAGE_2,
            interfaceMode = mode,
            serviceModel = model,
            mediaType = GenerationMediaType.IMAGE,
            status = GenerationStatus.SUCCEEDED,
            progress = 100,
            resultUrls = urls
        )
    }

    /** 解析 Chat SSE 的增量文本。 */
    private fun parseChatStream(raw: String): String = raw.lineSequence().mapNotNull { line ->
        val value = line.trim().takeIf { it.startsWith("data:") }?.removePrefix("data:")?.trim() ?: return@mapNotNull null
        if (value == "[DONE]") return@mapNotNull null
        runCatching { JSONObject(value).optJSONArray("choices")?.optJSONObject(0)?.optJSONObject("delta")?.optString("content") }.getOrNull()
    }.joinToString("")

    /** 解析 Gemini 普通响应。 */
    private fun parseGemini(response: JSONObject): String = response.optJSONArray("candidates")?.let { candidates ->
        buildString {
            for (index in 0 until candidates.length()) {
                val parts = candidates.optJSONObject(index)?.optJSONObject("content")?.optJSONArray("parts") ?: continue
                for (partIndex in 0 until parts.length()) append(parts.optJSONObject(partIndex)?.optString("text").orEmpty())
            }
        }
    }.orEmpty()

    /** 解析 Gemini SSE 的增量文本。 */
    private fun parseGeminiStream(raw: String): String = raw.lineSequence().mapNotNull { line ->
        val value = line.trim().removePrefix("data:").trim()
        if (value.isBlank()) null else runCatching { parseGemini(JSONObject(value)) }.getOrNull()
    }.joinToString("")

    /** 将服务端错误转换为用户可理解的提示，同时保留未知错误原文便于排查。 */
    private fun friendlyError(error: String): String = when {
        error.contains("excessive system load", ignoreCase = true) ->
            "服务器当前负载过高，请稍后重新生成"
        else -> error
    }

    /** 执行单次 HTTPS 请求，并限制响应体大小，避免异常响应耗尽内存。 */
    private fun request(path: String, apiKey: String, body: JSONObject?, method: String): JSONObject {
        return JSONObject(rawRequest(path, apiKey, body?.toString()?.toByteArray(Charsets.UTF_8), method, "application/json"))
    }

    /** 执行原始 HTTPS 请求，支持 JSON 和 multipart 两种请求体。 */
    private fun rawRequest(path: String, apiKey: String, body: ByteArray?, method: String, contentType: String): String {
        val connection = (URL(baseUrl.trimEnd('/') + path).openConnection() as HttpURLConnection).apply {
            requestMethod = method
            connectTimeout = 30_000
            readTimeout = 30_000
            setRequestProperty("Authorization", "Bearer $apiKey")
            setRequestProperty("Content-Type", contentType)
            setRequestProperty("X-Request-ID", UUID.randomUUID().toString())
            if (body != null) doOutput = true
        }
        body?.let { connection.outputStream.use { output -> output.write(it) } }
        val stream = if (connection.responseCode in 200..299) connection.inputStream else connection.errorStream
        val text = stream.bufferedReader().use { reader ->
            val result = reader.readText()
            require(result.toByteArray(Charsets.UTF_8).size <= 50 * 1024 * 1024) { "响应内容过大" }
            result
        }
        check(connection.responseCode in 200..299) { "Grsai 请求失败：${connection.responseCode}" }
        connection.disconnect()
        return text
    }

    /** 兼容统一接口将实际结果包在 data 对象中的响应格式。 */
    private fun payload(response: JSONObject): JSONObject = response.optJSONObject("data") ?: response
}

/** 生成 OpenAI 图片编辑所需的 multipart 请求体。 */
private class MultipartBuilder(private val boundary: String) {
    private val output = java.io.ByteArrayOutputStream()

    /** 追加文本字段。 */
    fun field(name: String, value: String): MultipartBuilder {
        output.write("--$boundary\r\nContent-Disposition: form-data; name=\"$name\"\r\n\r\n$value\r\n".toByteArray())
        return this
    }

    /** 追加图片二进制字段。 */
    fun file(name: String, fileName: String, mimeType: String, bytes: ByteArray): MultipartBuilder {
        output.write("--$boundary\r\nContent-Disposition: form-data; name=\"$name\"; filename=\"$fileName\"\r\nContent-Type: $mimeType\r\n\r\n".toByteArray())
        output.write(bytes)
        output.write("\r\n".toByteArray())
        return this
    }

    /** 关闭 multipart 边界并返回请求体。 */
    fun build(): ByteArray {
        output.write("--$boundary--\r\n".toByteArray())
        return output.toByteArray()
    }
}
