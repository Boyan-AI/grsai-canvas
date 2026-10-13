package ai.grsai.canvas

import android.content.Context
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.util.Locale

/** 将生成结果下载到应用缓存目录，限制 HTTPS 和单文件大小。 */
class ResultImageStore(context: Context) {
    private val directory = File(context.filesDir, "images").apply { mkdirs() }

    suspend fun download(url: String, taskId: String, index: Int): String = withContext(Dispatchers.IO) {
        require(url.startsWith("https://")) { "结果地址必须使用 HTTPS" }
        val connection = URL(url).openConnection() as HttpURLConnection
        connection.connectTimeout = 30_000
        connection.readTimeout = 45_000
        check(connection.responseCode in 200..299) { "结果媒体下载失败：${connection.responseCode}" }
        val length = connection.contentLengthLong
        require(length <= MAX_BYTES || length < 0) { "结果媒体超过 50 MB" }
        val temporary = File(directory, "${taskId}-${index}.part")
        connection.inputStream.use { input ->
            temporary.outputStream().use { output ->
                var total = 0L
                val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
                while (true) {
                    val count = input.read(buffer)
                    if (count < 0) break
                    total += count
                    require(total <= MAX_BYTES) { "结果媒体超过 50 MB" }
                    output.write(buffer, 0, count)
                }
            }
        }
        connection.disconnect()
        val bytes = temporary.inputStream().use { it.readNBytes(12) }
        val extension = detectExtension(connection.contentType, bytes, url)
        val target = File(directory, "${taskId}-${index}.$extension")
        require(temporary.renameTo(target)) { "结果媒体保存失败" }
        target.absolutePath
    }

    fun clearCache() {
        directory.listFiles()?.forEach(File::delete)
    }

    fun delete(paths: List<String>) {
        paths.map(::File).filter { it.parentFile == directory }.forEach(File::delete)
    }

    private companion object {
        const val MAX_BYTES = 50L * 1024L * 1024L

        /** 按响应头、文件签名和 URL 后缀推断安全媒体扩展名。 */
        fun detectExtension(contentType: String?, bytes: ByteArray, url: String): String {
            val normalized = contentType?.substringBefore(';')?.lowercase(Locale.ROOT)
            if (normalized == "video/mp4") return "mp4"
            if (normalized == "video/quicktime") return "mov"
            if (normalized == "video/webm") return "webm"
            if (bytes.size >= 8 && bytes.copyOfRange(4, 8).contentEquals(byteArrayOf(0x66, 0x74, 0x79, 0x70))) return "mp4"
            if (bytes.size >= 4 && bytes.copyOfRange(0, 4).contentEquals(byteArrayOf(0x1A, 0x45.toByte(), 0xDF.toByte(), 0xA3.toByte()))) return "webm"
            return when (url.substringBefore('?').substringAfterLast('.').lowercase(Locale.ROOT)) {
                "jpg", "jpeg" -> "jpg"
                "png" -> "png"
                "webp" -> "webp"
                else -> "img"
            }
        }
    }
}
