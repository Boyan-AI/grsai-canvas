package ai.grsai.canvas

import android.app.Application
import android.content.Context
import android.net.Uri
import android.util.Base64
import java.io.ByteArrayOutputStream
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import androidx.work.BackoffPolicy
import androidx.work.Constraints
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.workDataOf
import java.util.concurrent.TimeUnit
import org.json.JSONArray
import org.json.JSONObject

/** 管理 Android 工作台输入、凭据和历史任务，重启后恢复任务记录。 */
class MainViewModel(application: Application) : AndroidViewModel(application) {
    private val preferences = application.getSharedPreferences("canvas", Context.MODE_PRIVATE)
    private val credentialStore = SecureCredentialStore(application)
    private val imageStore = ResultImageStore(application)
    private val client = GrsaiApiClient()
    var apiKey by mutableStateOf(credentialStore.read().orEmpty())
    var prompt by mutableStateOf("")
    var model by mutableStateOf(GrsaiImageModel.GPT_IMAGE_2)
    var interfaceMode by mutableStateOf(GenerationInterface.NATIVE_IMAGE)
    var serviceModel by mutableStateOf("gemini-3.1-pro")
    var imageQuality by mutableStateOf("auto")
    var imageBackground by mutableStateOf("auto")
    var chatStream by mutableStateOf(false)
    var geminiGenerationConfigJson by mutableStateOf("{}")
    var videoAspectRatio by mutableStateOf("landscape")
    var videoResolution by mutableStateOf("768p")
    var videoDuration by mutableStateOf(5)
    var videoSeed by mutableStateOf<Int?>(null)
    var referenceUris by mutableStateOf<List<Uri>>(emptyList())
    var isSubmitting by mutableStateOf(false)
    var tasks by mutableStateOf(loadTasks())
        private set
    var message by mutableStateOf<String?>(null)
        private set

    val canGenerate: Boolean
        get() = apiKey.isNotBlank() && prompt.isNotBlank() && !isSubmitting

    /** 切换原生模型时同步接口模式和该视频模型的默认参数。 */
    fun selectNativeModel(selected: GrsaiImageModel) {
        model = selected
        interfaceMode = if (selected.isVideo) GenerationInterface.NATIVE_VIDEO else GenerationInterface.NATIVE_IMAGE
        if (selected.isVideo) {
            videoAspectRatio = selected.videoAspectRatios.first()
            videoResolution = if (selected == GrsaiImageModel.AGNES_VIDEO_2_5) "720p" else "768p"
            videoDuration = 5
        }
    }

    init {
        tasks.filter { it.status == GenerationStatus.RUNNING }.forEach { task ->
            scheduleBackgroundPolling(task)
            viewModelScope.launch { poll(task.id) }
        }
    }

    /** 保存 API Key 到应用私有数据，关闭应用后仍保留。 */
    fun saveApiKey(value: String) {
        apiKey = value.trim()
        credentialStore.save(apiKey)
        message = "API Key 已保存"
    }

    /** 清除本机保存的 API Key，并同步隐藏输入内容。 */
    fun clearApiKey() {
        credentialStore.delete()
        apiKey = ""
        message = "API Key 已清除"
    }

    /** 提交真实生图请求；调用前必须由用户明确触发。 */
    fun generate() {
        if (isSubmitting) return
        if (apiKey.isBlank() || prompt.isBlank()) {
            message = "请先填写 API Key 和提示词"
            return
        }
        val currentPrompt = prompt.trim()
        val currentReferences = referenceUris
        val currentModel = model
        val currentAspectRatio = videoAspectRatio
        val currentResolution = videoResolution
        val currentDuration = videoDuration
        val currentSeed = videoSeed
        val currentMode = interfaceMode
        val currentServiceModel = serviceModel
        val currentQuality = imageQuality
        val currentBackground = imageBackground
        val currentChatStream = chatStream
        val currentGeminiConfig = geminiGenerationConfigJson
        val currentApiKey = apiKey
        isSubmitting = true
        clearSubmittedDraft()
        viewModelScope.launch {
            val encodedReferences = runCatching {
                encodeReferences(currentReferences, if (currentModel.isVideo) 9 else 8)
            }.getOrElse {
                isSubmitting = false
                message = it.message ?: "参考图读取失败"
                return@launch
            }
            runCatching {
                when (currentMode) {
                    GenerationInterface.OPENAI_IMAGE -> client.openAIImage(
                        currentApiKey, currentPrompt, currentServiceModel,
                        currentQuality.takeIf { it != "auto" }, currentBackground.takeIf { it != "auto" }
                    )
                    GenerationInterface.IMAGE_EDIT -> {
                        val uri = currentReferences.firstOrNull() ?: error("图片编辑至少需要一张参考图")
                        val bytes = readBytes(uri)
                        client.editImage(
                            currentApiKey, currentPrompt, currentServiceModel, bytes,
                            uri.lastPathSegment ?: "image.png", contentType(uri),
                            currentQuality.takeIf { it != "auto" }, currentBackground.takeIf { it != "auto" }
                        )
                    }
                    GenerationInterface.OPENAI_CHAT, GenerationInterface.GEMINI, GenerationInterface.GEMINI_STREAM -> {
                        val textResponse = if (currentMode == GenerationInterface.OPENAI_CHAT) {
                            client.chatCompletion(currentApiKey, currentServiceModel, currentPrompt, encodedReferences, currentChatStream)
                        } else {
                            client.geminiContent(currentApiKey, currentServiceModel, currentPrompt, encodedReferences, currentGeminiConfig, currentMode == GenerationInterface.GEMINI_STREAM)
                        }
                        GenerationTask(
                            id = textResponse.id,
                            prompt = currentPrompt,
                            model = GrsaiImageModel.GPT_IMAGE_2,
                            interfaceMode = currentMode,
                            serviceModel = currentServiceModel,
                            mediaType = GenerationMediaType.TEXT,
                            status = GenerationStatus.SUCCEEDED,
                            progress = 100,
                            textResult = textResponse.text,
                            referenceUris = currentReferences.map(Uri::toString)
                        )
                    }
                    GenerationInterface.NATIVE_IMAGE, GenerationInterface.NATIVE_VIDEO -> client.submit(
                        currentApiKey,
                        currentPrompt,
                        currentModel,
                        encodedReferences,
                        currentAspectRatio.takeIf { currentModel.isVideo } ?: "auto",
                        currentResolution.takeIf { currentModel.isVideo },
                        currentDuration.takeIf { currentModel.isVideo },
                        currentSeed.takeIf { currentModel.isVideo }
                    )
                }
            }
                .onSuccess { task ->
                    val savedTask = task.copy(referenceUris = currentReferences.map(Uri::toString))
                    tasks = listOf(savedTask) + tasks
                    saveTasks()
                    scheduleBackgroundPolling(savedTask)
                    viewModelScope.launch { poll(savedTask.id) }
                }
                .onFailure { message = it.message ?: "提交失败" }
            isSubmitting = false
        }
    }

    /** 读取编辑接口需要上传的本地图片字节。 */
    private fun readBytes(uri: Uri): ByteArray {
        return getApplication<Application>().contentResolver.openInputStream(uri)?.use { it.readBytes() }
            ?: error("无法读取参考图")
    }

    /** 根据 Android ContentResolver 返回编辑图片的 MIME 类型。 */
    private fun contentType(uri: Uri): String = getApplication<Application>().contentResolver.getType(uri)
        ?.takeIf { it in setOf("image/jpeg", "image/png", "image/webp") } ?: "image/png"

    /** 读取用户选择的图片并转为受限大小的 data URL。 */
    private fun encodeReferences(uris: List<Uri>, maximumCount: Int): List<String> {
        require(uris.size <= maximumCount) { "参考图最多允许 $maximumCount 张" }
        val resolver = getApplication<Application>().contentResolver
        return uris.map { uri ->
            val mime = resolver.getType(uri).orEmpty().lowercase()
            require(mime in setOf("image/jpeg", "image/png", "image/webp")) { "仅支持 JPG、PNG 或 WEBP" }
            val bytes = resolver.openInputStream(uri)?.use { input ->
                ByteArrayOutputStream().use { output ->
                    input.copyTo(output)
                    output.toByteArray()
                }
            } ?: error("无法读取参考图")
            require(bytes.size <= 10 * 1024 * 1024) { "单张参考图不能超过 10 MB" }
            "data:$mime;base64,${Base64.encodeToString(bytes, Base64.NO_WRAP)}"
        }
    }

    /** 清空提交后的界面草稿，避免用户连续提交相同内容。 */
    private fun clearSubmittedDraft() {
        prompt = ""
        referenceUris = emptyList()
        model = GrsaiImageModel.GPT_IMAGE_2
        videoAspectRatio = "landscape"
        videoResolution = "768p"
        videoDuration = 5
        videoSeed = null
        interfaceMode = GenerationInterface.NATIVE_IMAGE
        serviceModel = "gemini-3.1-pro"
        imageQuality = "auto"
        imageBackground = "auto"
        chatStream = false
        geminiGenerationConfigJson = "{}"
    }

    /** 只查询已有任务 ID，避免轮询过程中重复创建任务。 */
    private suspend fun poll(taskId: String) {
        repeat(150) {
            delay(2_000)
            val current = tasks.firstOrNull { it.id == taskId } ?: return
            val next = runCatching { client.query(apiKey, taskId, current) }.getOrElse {
                message = it.message ?: "查询失败"
                return
            }
            val completed = if (next.status == GenerationStatus.SUCCEEDED && next.localImagePaths.isEmpty()) {
                downloadResults(next)
            } else next
            tasks = tasks.map { if (it.id == taskId) completed else it }
            saveTasks()
            if (completed.status != GenerationStatus.RUNNING) return
        }
        message = "任务仍在生成，可稍后重新打开应用继续查询"
    }

    /** 清空历史和本地结果记录，但保留 API Key。 */
    fun clearApplicationData() {
        tasks = emptyList()
        saveTasks()
        imageStore.clearCache()
        message = "历史数据已清空，API Key 已保留"
    }

    fun deleteTask(task: GenerationTask) {
        tasks = tasks.filterNot { it.id == task.id }
        saveTasks()
        imageStore.delete(task.localImagePaths)
    }

    fun consumeMessage() { message = null }

    /** 为运行中的任务安排网络约束下的后台续查。 */
    private fun scheduleBackgroundPolling(task: GenerationTask) {
        val request = OneTimeWorkRequestBuilder<TaskPollingWorker>()
            .setInputData(workDataOf(
                TaskPollingWorker.KEY_TASK_ID to task.id,
                TaskPollingWorker.KEY_PROMPT to task.prompt,
                TaskPollingWorker.KEY_MODEL to task.model.value
            ))
            .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
            .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 10, TimeUnit.SECONDS)
            .build()
        WorkManager.getInstance(getApplication())
            .enqueueUniqueWork("poll-${task.id}", ExistingWorkPolicy.REPLACE, request)
    }

    private fun saveTasks() {
        val array = JSONArray()
        tasks.forEach { task ->
            array.put(JSONObject().apply {
                put("id", task.id)
                put("prompt", task.prompt)
                put("model", task.model.value)
                put("status", task.status.name)
                put("mediaType", task.mediaType.name)
                put("interfaceMode", task.interfaceMode.name)
                put("serviceModel", task.serviceModel)
                put("progress", task.progress ?: -1)
                put("createdAt", task.createdAt)
                put("errorMessage", task.errorMessage)
                put("urls", JSONArray(task.resultUrls))
                put("references", JSONArray(task.referenceUris))
                put("localPaths", JSONArray(task.localImagePaths))
                put("aspectRatio", task.aspectRatio)
                put("resolution", task.resolution)
                put("duration", task.duration)
                put("seed", task.seed)
                put("textResult", task.textResult)
            })
        }
        preferences.edit().putString("tasks", array.toString()).apply()
    }

    /** 下载成功任务的结果并将本地路径写回历史，断网时保留远程地址。 */
    private suspend fun downloadResults(task: GenerationTask): GenerationTask {
        val paths = runCatching {
            task.resultUrls.mapIndexed { index, url -> imageStore.download(url, task.id, index + 1) }
        }.getOrDefault(emptyList())
        return task.copy(localImagePaths = paths)
    }

    private fun loadTasks(): List<GenerationTask> = runCatching {
        val array = JSONArray(preferences.getString("tasks", "[]"))
        buildList {
            for (index in 0 until array.length()) {
                val item = array.getJSONObject(index)
                add(GenerationTask(
                    id = item.getString("id"), prompt = item.getString("prompt"),
                    model = GrsaiImageModel.entries.firstOrNull { it.value == item.getString("model") } ?: GrsaiImageModel.GPT_IMAGE_2,
                    interfaceMode = runCatching { GenerationInterface.valueOf(item.optString("interfaceMode")) }.getOrDefault(GenerationInterface.NATIVE_IMAGE),
                    serviceModel = item.optString("serviceModel").takeIf { it.isNotBlank() },
                    mediaType = runCatching { GenerationMediaType.valueOf(item.optString("mediaType", "IMAGE")) }.getOrDefault(GenerationMediaType.IMAGE),
                    status = GenerationStatus.valueOf(item.optString("status", "RUNNING")),
                    progress = item.optInt("progress", -1).takeIf { it >= 0 },
                    createdAt = item.optLong("createdAt"),
                    errorMessage = item.optString("errorMessage").takeIf { it.isNotBlank() },
                    resultUrls = item.optJSONArray("urls")?.let { urls -> List(urls.length()) { urls.getString(it) } } ?: emptyList(),
                    referenceUris = item.optJSONArray("references")?.let { refs -> List(refs.length()) { refs.getString(it) } } ?: emptyList(),
                    localImagePaths = item.optJSONArray("localPaths")?.let { paths -> List(paths.length()) { paths.getString(it) } } ?: emptyList(),
                    aspectRatio = item.optString("aspectRatio", "auto"),
                    resolution = item.optString("resolution").takeIf { it.isNotBlank() },
                    duration = item.optInt("duration", -1).takeIf { it >= 0 },
                    seed = if (item.has("seed") && !item.isNull("seed")) item.optInt("seed") else null
                    ,textResult = item.optString("textResult").takeIf { it.isNotBlank() }
                ))
            }
        }
    }.getOrDefault(emptyList())
}
