package ai.grsai.canvas

import android.os.Bundle
import android.net.Uri
import android.view.ViewGroup
import android.widget.MediaController
import android.widget.VideoView
import java.io.File
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.gestures.transformable
import androidx.compose.foundation.gestures.rememberTransformableState
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.material3.IconButton
import coil.compose.AsyncImage
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.lifecycle.viewmodel.compose.viewModel

/** Android 画境入口。 */
class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent { CanvasApp() }
    }
}

private val Paper = Color(0xFFF2EBDD)
private val Ink = Color(0xFF3E3328)
private val Forest = Color(0xFF4A7A55)
private val Sky = Color(0xFF5C96A8)
private val Terracotta = Color(0xFFC66A3D)

@Composable
private fun CanvasApp(model: MainViewModel = viewModel()) {
    val snackbar = remember { SnackbarHostState() }
    LaunchedEffect(model.message) {
        model.message?.let { snackbar.showSnackbar(it); model.consumeMessage() }
    }
    MaterialTheme {
        Scaffold(snackbarHost = { SnackbarHost(snackbar) }, containerColor = Paper) { padding ->
            LazyColumn(
                modifier = Modifier.fillMaxSize().padding(padding).padding(horizontal = 18.dp),
                verticalArrangement = Arrangement.spacedBy(14.dp)
            ) {
                item { Header() }
                item { CredentialSection(model) }
                item { PromptSection(model) }
                item { GallerySection(model) }
            }
        }
    }
}

@Composable
private fun Header() {
    Column(modifier = Modifier.padding(top = 18.dp)) {
        Text("画境", style = MaterialTheme.typography.headlineMedium, color = Ink)
            Text("原生 Android 图片与视频工作台", color = Ink.copy(alpha = 0.65f))
    }
}

@Composable
private fun CredentialSection(model: MainViewModel) {
    var value by remember(model.apiKey) { mutableStateOf(model.apiKey) }
    Card(colors = CardDefaults.cardColors(containerColor = Color(0xFFE8DECC))) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row {
                Text("API Key", style = MaterialTheme.typography.titleMedium, color = Ink)
                Spacer(Modifier.weight(1f))
                if (model.apiKey.isBlank()) {
                    OutlinedButton(onClick = { model.saveApiKey(value) }) { Text("保存") }
                } else {
                    OutlinedButton(onClick = model::clearApiKey) { Text("清除") }
                }
            }
            if (model.apiKey.isBlank()) {
                OutlinedTextField(
                    value = value,
                    onValueChange = { value = it },
                    modifier = Modifier.fillMaxWidth(),
                    singleLine = true,
                    label = { Text("输入 Grsai API Key") },
                    visualTransformation = PasswordVisualTransformation()
                )
            } else {
                Text("密钥已安全保存在本机应用数据中", color = Forest)
            }
        }
    }
}

/** 展示模型、参数和提示词，并将输入同步到工作台状态。 */
@Composable
private fun PromptSection(model: MainViewModel) {
    var prompt by remember(model.prompt) { mutableStateOf(model.prompt) }
    var modelMenuExpanded by remember { mutableStateOf(false) }
    var interfaceMenuExpanded by remember { mutableStateOf(false) }
    var imageRatioMenuExpanded by remember { mutableStateOf(false) }
    var imageSizeMenuExpanded by remember { mutableStateOf(false) }
    val picker = androidx.activity.compose.rememberLauncherForActivityResult(
        ActivityResultContracts.GetMultipleContents()
    ) { uris -> model.referenceUris = uris.take(if (model.interfaceMode == GenerationInterface.NATIVE_VIDEO) 9 else 8) }
    Card(colors = CardDefaults.cardColors(containerColor = Color(0xFFFFFCF5))) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Text("生成参数", style = MaterialTheme.typography.titleMedium, color = Ink)
            Row {
                Button(onClick = { interfaceMenuExpanded = true }) { Text(model.interfaceMode.title) }
                DropdownMenu(
                    expanded = interfaceMenuExpanded,
                    onDismissRequest = { interfaceMenuExpanded = false }
                ) {
                    GenerationInterface.entries.forEach { option ->
                        DropdownMenuItem(
                            text = { Text(option.title) },
                            onClick = {
                                model.interfaceMode = option
                                if (option == GenerationInterface.NATIVE_VIDEO && !model.model.isVideo) model.selectNativeModel(GrsaiImageModel.MINIMAX_H3)
                                if (option != GenerationInterface.NATIVE_VIDEO && model.model.isVideo) model.selectNativeModel(GrsaiImageModel.GPT_IMAGE_2)
                                model.interfaceMode = option
                                interfaceMenuExpanded = false
                            }
                        )
                    }
                }
                Spacer(Modifier.width(8.dp))
                if (model.interfaceMode == GenerationInterface.NATIVE_IMAGE || model.interfaceMode == GenerationInterface.NATIVE_VIDEO) {
                Button(onClick = { modelMenuExpanded = true }) { Text(model.model.value) }
                DropdownMenu(
                    expanded = modelMenuExpanded,
                    onDismissRequest = { modelMenuExpanded = false }
                ) {
                    GrsaiImageModel.entries.forEach { option ->
                        DropdownMenuItem(
                            text = { Text(option.value) },
                            onClick = {
                                model.selectNativeModel(option)
                                modelMenuExpanded = false
                            }
                        )
                    }
                }
                }
            }
            if (model.interfaceMode != GenerationInterface.NATIVE_IMAGE && model.interfaceMode != GenerationInterface.NATIVE_VIDEO) {
                OutlinedTextField(
                    value = model.serviceModel,
                    onValueChange = { model.serviceModel = it },
                    modifier = Modifier.fillMaxWidth(),
                    singleLine = true,
                    label = { Text("服务模型") }
                )
            }
            if (model.interfaceMode == GenerationInterface.OPENAI_IMAGE || model.interfaceMode == GenerationInterface.IMAGE_EDIT) {
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    listOf("auto", "low", "medium", "high").forEach { quality ->
                        OutlinedButton(onClick = { model.imageQuality = quality }) { Text(if (model.imageQuality == quality) "✓ $quality" else quality) }
                    }
                }
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    listOf("auto", "transparent", "opaque").forEach { background ->
                        OutlinedButton(onClick = { model.imageBackground = background }) { Text(if (model.imageBackground == background) "✓ $background" else background) }
                    }
                }
            }
            if (model.interfaceMode == GenerationInterface.OPENAI_CHAT) {
                OutlinedButton(onClick = { model.chatStream = !model.chatStream }) {
                    Text(if (model.chatStream) "✓ 流式响应" else "普通响应")
                }
            }
            if (model.interfaceMode == GenerationInterface.GEMINI || model.interfaceMode == GenerationInterface.GEMINI_STREAM) {
                OutlinedTextField(
                    value = model.geminiGenerationConfigJson,
                    onValueChange = { model.geminiGenerationConfigJson = it },
                    modifier = Modifier.fillMaxWidth(),
                    singleLine = true,
                    label = { Text("generationConfig JSON（可选）") }
                )
            }
            if (model.interfaceMode == GenerationInterface.NATIVE_IMAGE && !model.model.isVideo) {
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Column {
                        OutlinedButton(onClick = { imageRatioMenuExpanded = true }) { Text("比例 ${model.imageAspectRatio}") }
                        DropdownMenu(expanded = imageRatioMenuExpanded, onDismissRequest = { imageRatioMenuExpanded = false }) {
                            model.model.imageAspectRatios.forEach { ratio ->
                                DropdownMenuItem(text = { Text(ratio) }, onClick = {
                                    model.imageAspectRatio = ratio
                                    imageRatioMenuExpanded = false
                                })
                            }
                        }
                    }
                    if (!model.model.isGptImage) {
                        Column {
                            OutlinedButton(onClick = { imageSizeMenuExpanded = true }) { Text("清晰度 ${model.imageSize}") }
                            DropdownMenu(expanded = imageSizeMenuExpanded, onDismissRequest = { imageSizeMenuExpanded = false }) {
                                listOf("1K", "2K", "4K").forEach { size ->
                                    DropdownMenuItem(text = { Text(size) }, onClick = {
                                        model.imageSize = size
                                        imageSizeMenuExpanded = false
                                    })
                                }
                            }
                        }
                    }
                }
            }
            if (model.model.isVideo && model.interfaceMode == GenerationInterface.NATIVE_VIDEO) {
                Text("视频比例：${model.videoAspectRatio}", color = Ink)
                OutlinedButton(onClick = {
                    val ratios = model.model.videoAspectRatios
                    model.videoAspectRatio = ratios[(ratios.indexOf(model.videoAspectRatio) + 1) % ratios.size]
                }) { Text("切换比例") }
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    model.model.videoResolutions.forEach { resolution ->
                        OutlinedButton(onClick = {
                            model.videoResolution = resolution
                            if (model.model == GrsaiImageModel.MINIMAX_H3 && resolution == "1080p") model.videoDuration = minOf(model.videoDuration, 10)
                        }) {
                            Text(if (model.videoResolution == resolution) "✓ $resolution" else resolution)
                        }
                    }
                }
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text("时长 ${model.videoDuration} 秒", color = Ink)
                    OutlinedButton(onClick = {
                        val maximum = if (model.model == GrsaiImageModel.MINIMAX_H3 && model.videoResolution == "1080p") 10 else model.model.videoDurationRange.last
                        model.videoDuration = if (model.videoDuration >= maximum) model.model.videoDurationRange.first else model.videoDuration + 1
                    }) {
                        Text("调整时长")
                    }
                }
            }
            OutlinedTextField(
                value = prompt,
                onValueChange = { prompt = it; model.prompt = it },
                modifier = Modifier.fillMaxWidth().height(120.dp),
                label = { Text("描述你想生成的画面") }
            )
            OutlinedButton(onClick = { picker.launch("image/*") }) {
                val maximum = if (model.interfaceMode == GenerationInterface.NATIVE_VIDEO) 9 else 8
                Text(if (model.referenceUris.isEmpty()) "选择参考图（最多 $maximum 张）" else "已选择 ${model.referenceUris.size} 张参考图")
            }
            Button(
                onClick = { model.generate() },
                modifier = Modifier.fillMaxWidth(),
                enabled = model.canGenerate
            ) {
                Text(if (model.isSubmitting) "正在提交…" else if (model.interfaceMode == GenerationInterface.OPENAI_CHAT || model.interfaceMode == GenerationInterface.GEMINI || model.interfaceMode == GenerationInterface.GEMINI_STREAM) "发送消息 · 可能产生费用" else "生成结果 · 可能产生费用")
            }
        }
    }
}

@Composable
private fun GallerySection(model: MainViewModel) {
    var previewTask by remember { mutableStateOf<GenerationTask?>(null) }
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Row {
            Text("作品画廊", style = MaterialTheme.typography.titleLarge, color = Ink)
            Spacer(Modifier.weight(1f))
            Text("${model.tasks.size} 个任务", color = Ink.copy(alpha = 0.6f))
        }
        if (model.tasks.isEmpty()) {
            Text("任务保存在本机，可在重启后继续查询。", color = Ink.copy(alpha = 0.65f))
        } else {
            model.tasks.forEach { TaskCard(it, model, onPreview = { previewTask = it }) }
            OutlinedButton(onClick = model::clearApplicationData, modifier = Modifier.fillMaxWidth()) {
                Text("清空历史和图片，仅保留 API Key", color = Terracotta)
            }
        }
    }
    previewTask?.let { PreviewDialog(it) { previewTask = null } }
}

@Composable
private fun TaskCard(task: GenerationTask, model: MainViewModel, onPreview: (GenerationTask) -> Unit) {
    Card(colors = CardDefaults.cardColors(containerColor = Color(0xFFFFFCF5))) {
        Column(Modifier.fillMaxWidth().padding(14.dp)) {
            Text(task.prompt, maxLines = 1, color = Ink)
            Text("${task.status.name.lowercase()} · ${task.model.value}", color = Ink.copy(alpha = 0.6f))
            Text("${task.interfaceMode.title}${task.serviceModel?.let { " · $it" } ?: ""}", color = Ink.copy(alpha = 0.6f))
            if (task.mediaType == GenerationMediaType.TEXT) {
                Text(task.textResult.orEmpty(), color = Ink, maxLines = 8)
            }
            task.progress?.let { progress -> Text("进度：$progress%", color = Sky) }
            task.resultUrls.firstOrNull()?.let { Text("结果已生成", color = Forest) }
            task.errorMessage?.let { Text(it, color = Terracotta) }
            if (task.mediaType == GenerationMediaType.TEXT || task.resultUrls.isNotEmpty() || task.localImagePaths.isNotEmpty()) {
                OutlinedButton(onClick = { onPreview(task) }) { Text("预览") }
            }
            OutlinedButton(onClick = { model.deleteTask(task) }) { Text("删除") }
        }
    }
}

/** 支持图片缩放和视频播放的 Android 预览弹窗。 */
@Composable
private fun PreviewDialog(task: GenerationTask, onDismiss: () -> Unit) {
    var scale by remember { mutableStateOf(1f) }
    var offsetX by remember { mutableStateOf(0f) }
    var offsetY by remember { mutableStateOf(0f) }
    val transformState = rememberTransformableState { zoom, pan, _ ->
        scale = (scale * zoom).coerceIn(1f, 5f)
        offsetX += pan.x
        offsetY += pan.y
    }
    Dialog(onDismissRequest = onDismiss) {
        Card(colors = CardDefaults.cardColors(containerColor = Color.Black)) {
            Column {
                Row(Modifier.fillMaxWidth()) {
                    Spacer(Modifier.weight(1f))
                    IconButton(onClick = onDismiss) { Text("关闭", color = Color.White) }
                }
                if (task.mediaType == GenerationMediaType.TEXT) {
                    Text(
                        task.textResult.orEmpty(),
                        color = Color.White,
                        modifier = Modifier.fillMaxWidth().padding(18.dp)
                    )
                } else if (task.mediaType == GenerationMediaType.VIDEO) {
                    VideoPreview(task)
                } else {
                    AsyncImage(
                        model = task.localImagePaths.firstOrNull() ?: task.resultUrls.firstOrNull(),
                        contentDescription = "生成结果预览",
                        modifier = Modifier
                            .fillMaxWidth()
                            .height(420.dp)
                            .graphicsLayer {
                                scaleX = scale
                                scaleY = scale
                                translationX = offsetX
                                translationY = offsetY
                            }
                            .transformable(transformState)
                    )
                }
            }
        }
    }
}

/** 使用系统 VideoView 播放本地缓存或 HTTPS 视频，避免新增播放器依赖。 */
@Composable
private fun VideoPreview(task: GenerationTask) {
    val source = task.localImagePaths.firstOrNull()?.let { Uri.fromFile(File(it)) }
        ?: task.resultUrls.firstOrNull()?.let(Uri::parse)
    if (source == null) return
    AndroidView(
        modifier = androidx.compose.ui.Modifier.fillMaxWidth().height(420.dp),
        factory = { context ->
            VideoView(context).apply {
                layoutParams = ViewGroup.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT,
                    ViewGroup.LayoutParams.MATCH_PARENT
                )
                setMediaController(MediaController(context))
                setVideoURI(source)
                start()
            }
        },
        update = { view -> if (!view.isPlaying) view.start() }
    )
}
