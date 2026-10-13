# 画境 Android

这是画境的 Android 客户端工程，使用 Kotlin、Jetpack Compose 和 Android SDK 36。

## 打开与构建

使用 Android Studio 打开本目录，等待 Gradle 同步完成后运行 `app`；也可使用已提交的 Gradle Wrapper 执行 `./gradlew :app:assembleDebug` 构建 Debug APK。

## 当前实现

- API Key 使用 Android Keystore 加密保存，关闭应用后仍保留。
- Grsai 原生异步接口提交和同任务 ID 轮询。
- 工作台支持原生图片、原生视频、OpenAI 图片生成、multipart 图片编辑、OpenAI Chat、Gemini `generateContent` 和 `streamGenerateContent`。
- 模型清单已同步 `gpt-image-2.5`、Flare、Sunburst、VIP 变体、`nano-banana-2.1` 和 `agnes-video-2.5`。
- 图片最多 8 张、视频最多 9 张 JPG、PNG、WEBP 参考图，并在请求前编码为 data URL。
- 历史任务 JSON 持久化、删除和清空记录。
- 图片结果支持双指缩放、拖动预览；视频结果使用系统 `VideoView` 播放本地缓存或 HTTPS 地址。
- Chat/Gemini 文本结果会持久化到历史并在 Compose 文本卡片和预览弹窗中显示；流式响应在本地合并后保存。
- Compose 温暖手绘风格工作台骨架。

结果图片或视频下载到应用私有缓存，WorkManager 会在后台继续查询已有任务。`minimax-h3` 支持 portrait/landscape、480p/768p/1080p 和 1–15 秒时长（1080p 最长 10 秒）；`agnes-video-2.5` 支持 16:9/9:16/21:9/4:3/1:1/3:4、720p/1080p/2k 和 4–12 秒时长。真实生成请求可能产生费用，联调前请确认 API Key 和费用授权。
