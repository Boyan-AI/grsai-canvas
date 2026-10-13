package ai.grsai.canvas

import android.content.Context
import androidx.work.CoroutineWorker
import androidx.work.WorkerParameters
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject

/** 应用切后台后继续查询已有任务，不会创建新的生图任务。 */
class TaskPollingWorker(
    context: Context,
    parameters: WorkerParameters
) : CoroutineWorker(context, parameters) {
    override suspend fun doWork(): Result = withContext(Dispatchers.IO) {
        val taskId = inputData.getString(KEY_TASK_ID) ?: return@withContext Result.failure()
        val prompt = inputData.getString(KEY_PROMPT).orEmpty()
        val model = GrsaiImageModel.entries.firstOrNull {
            it.value == inputData.getString(KEY_MODEL)
        } ?: GrsaiImageModel.GPT_IMAGE_2
        val apiKey = SecureCredentialStore(applicationContext).read() ?: return@withContext Result.failure()
        val task = GenerationTask(id = taskId, prompt = prompt, model = model)
        val next = runCatching { GrsaiApiClient().query(apiKey, taskId, task) }.getOrElse {
            return@withContext Result.retry()
        }
        applicationContext.getSharedPreferences("canvas", Context.MODE_PRIVATE)
            .edit()
            .putString("worker_result_$taskId", JSONObject().apply {
                put("status", next.status.name)
                put("progress", next.progress ?: -1)
                put("urls", next.resultUrls.joinToString("\n"))
            }.toString())
            .apply()
        if (next.status == GenerationStatus.RUNNING) Result.retry() else Result.success()
    }

    companion object {
        const val KEY_TASK_ID = "task_id"
        const val KEY_PROMPT = "prompt"
        const val KEY_MODEL = "model"
    }
}
