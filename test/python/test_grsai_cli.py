"""Grsai Python CLI 的外部契约测试。"""

from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import sys
from tempfile import TemporaryDirectory
from typing import Any
import unittest


PROJECT_ROOT = Path(__file__).resolve().parents[2]
SCRIPT_PATH = (
    PROJECT_ROOT
    / "skills"
    / "grsai-image-generation"
    / "scripts"
    / "grsai_image.py"
)
SCRIPT_DIRECTORY = SCRIPT_PATH.parent
sys.path.insert(0, str(SCRIPT_DIRECTORY))

from grsai_client import GrsaiError  # noqa: E402
from grsai_image import run_command  # noqa: E402


class FakeClient:
    """提供 CLI 编排测试所需的可配置客户端结果。"""

    def __init__(
        self,
        *,
        generate_result: dict[str, Any] | BaseException | None = None,
        get_result: dict[str, Any] | BaseException | None = None,
        wait_result: dict[str, Any] | BaseException | None = None,
        openai_result: dict[str, Any] | BaseException | None = None,
    ) -> None:
        """保存各调用结果和调用记录。"""
        self.generate_result = generate_result
        self.get_result_value = get_result
        self.wait_result = wait_result
        self.openai_result = openai_result
        self.generate_calls: list[tuple[dict[str, Any], dict[str, Any]]] = []
        self.get_calls: list[tuple[str, dict[str, Any]]] = []
        self.wait_calls: list[tuple[str, int, dict[str, Any]]] = []
        self.openai_calls: list[tuple[dict[str, Any], dict[str, Any]]] = []

    def generate(self, payload: dict[str, Any], **context: Any) -> dict[str, Any]:
        """记录原生提交并返回预设结果。"""
        self.generate_calls.append((payload, context))
        return self._resolve(self.generate_result)

    def get_result(self, task_id: str, **context: Any) -> dict[str, Any]:
        """记录状态查询并返回预设结果。"""
        self.get_calls.append((task_id, context))
        return self._resolve(self.get_result_value)

    def wait_for_result(
        self,
        task_id: str,
        timeout_ms: int,
        **context: Any,
    ) -> dict[str, Any]:
        """记录轮询等待并返回预设结果。"""
        self.wait_calls.append((task_id, timeout_ms, context))
        return self._resolve(self.wait_result)

    def generate_openai(
        self,
        payload: dict[str, Any],
        **context: Any,
    ) -> dict[str, Any]:
        """记录同步生图并返回预设结果。"""
        self.openai_calls.append((payload, context))
        return self._resolve(self.openai_result)

    @staticmethod
    def _resolve(value: dict[str, Any] | BaseException | None) -> dict[str, Any]:
        """抛出异常结果或返回字典结果。"""
        if isinstance(value, BaseException):
            raise value
        if value is None:
            raise AssertionError("没有配置假客户端结果")
        return value


class GrsaiCliContractTests(unittest.TestCase):
    """从子进程边界验证 CLI 的稳定行为。"""

    def run_cli(
        self,
        *arguments: str,
        api_key: str | None = None,
    ) -> subprocess.CompletedProcess[str]:
        """使用隔离环境执行 CLI，避免读取开发机上的真实密钥。"""
        environment = os.environ.copy()
        environment.pop("GRSAI_API_KEY", None)
        if api_key is not None:
            environment["GRSAI_API_KEY"] = api_key
        return subprocess.run(
            [sys.executable, str(SCRIPT_PATH), *arguments],
            cwd=PROJECT_ROOT,
            env=environment,
            capture_output=True,
            text=True,
            check=False,
        )

    def test_help_lists_public_commands(self) -> None:
        """帮助文本应列出三个公开子命令。"""
        result = self.run_cli("--help")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("generate", result.stdout)
        self.assertIn("get", result.stdout)
        self.assertIn("doctor", result.stdout)

    def test_generate_without_prompt_returns_structured_input_error(self) -> None:
        """缺少提示词时应在发出网络请求前返回稳定 JSON。"""
        result = self.run_cli("generate")

        self.assertEqual(result.returncode, 2)
        payload = json.loads(result.stdout)
        self.assertEqual(payload["status"], "failed")
        self.assertEqual(payload["urls"], [])
        self.assertEqual(payload["files"], [])
        self.assertEqual(payload["error"]["code"], "INVALID_ARGUMENTS")
        self.assertEqual(payload["error"]["phase"], "input")
        self.assertFalse(payload["error"]["retryable"])
        self.assertFalse(payload["error"]["acceptance_unknown"])

    def test_doctor_reports_configuration_without_exposing_key(self) -> None:
        """诊断命令应确认密钥存在，但不得回显密钥。"""
        secret = "test-secret-value"
        result = self.run_cli("doctor", api_key=secret)

        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertEqual(payload["status"], "succeeded")
        self.assertTrue(payload["api_key_configured"])
        self.assertIn("python_version", payload)
        self.assertNotIn(secret, result.stdout)
        self.assertNotIn(secret, result.stderr)


class GrsaiCliOrchestrationTests(unittest.TestCase):
    """在无网络条件下验证命令到客户端的业务编排。"""

    def test_native_generate_uses_defaults_and_waits_for_result(self) -> None:
        """默认生图应提交 gpt-image-2 原生异步任务并续查。"""
        client = FakeClient(
            generate_result={"id": "task-1", "status": "running", "progress": 10},
            wait_result={
                "id": "task-1",
                "status": "succeeded",
                "results": [{"url": "https://images.example/result.png"}],
            },
        )

        result = run_command(
            ["generate", "--prompt", "未来城市"],
            {"GRSAI_API_KEY": "test-key"},
            client_factory=lambda _config: client,
        )

        self.assertEqual(result.exit_code, 0)
        self.assertEqual(result.payload["status"], "succeeded")
        self.assertEqual(result.payload["urls"], ["https://images.example/result.png"])
        submitted = client.generate_calls[0][0]
        self.assertEqual(submitted["model"], "gpt-image-2")
        self.assertEqual(submitted["replyType"], "async")
        self.assertEqual(client.wait_calls[0][0], "task-1")
        self.assertEqual(client.wait_calls[0][1], 180_000)

    def test_poll_timeout_returns_running_task_without_resubmitting(self) -> None:
        """可恢复轮询超时应返回已有任务，而不是失败或重复提交。"""
        client = FakeClient(
            generate_result={"id": "task-running", "status": "running", "progress": 25},
            wait_result=GrsaiError(
                "等待生图任务超时",
                code="POLL_TIMEOUT",
                retryable=True,
                phase="poll",
                request_id="request-running",
                timeout_ms=180_000,
            ),
        )

        result = run_command(
            ["generate", "--prompt", "未来城市"],
            {"GRSAI_API_KEY": "test-key"},
            client_factory=lambda _config: client,
        )

        self.assertEqual(result.exit_code, 0)
        self.assertEqual(result.payload["status"], "running")
        self.assertEqual(result.payload["id"], "task-running")
        self.assertEqual(result.payload["progress"], 25)
        self.assertEqual(len(client.generate_calls), 1)

    def test_openai_backend_maps_sync_result_to_stable_output(self) -> None:
        """同步兼容响应应转换为稳定任务输出。"""
        client = FakeClient(
            openai_result={
                "created": 123,
                "data": [{"url": "https://images.example/openai.png"}],
            }
        )

        result = run_command(
            [
                "generate",
                "--prompt",
                "海边日落",
                "--backend",
                "openai-compatible",
                "--aspect-ratio",
                "1024x1024",
            ],
            {"GRSAI_API_KEY": "test-key"},
            client_factory=lambda _config: client,
        )

        self.assertEqual(result.exit_code, 0)
        self.assertEqual(result.payload["id"], "openai-123")
        self.assertEqual(result.payload["status"], "succeeded")
        self.assertEqual(client.openai_calls[0][0]["size"], "1024x1024")

    def test_invalid_model_size_combination_stops_before_client_creation(self) -> None:
        """不可靠参数组合应在可能计费的客户端调用前拒绝。"""
        calls = 0

        def fail_factory(_config: object) -> FakeClient:
            """记录不应发生的客户端创建。"""
            nonlocal calls
            calls += 1
            raise AssertionError("不应创建客户端")

        result = run_command(
            [
                "generate",
                "--prompt",
                "动作图集",
                "--model",
                "gpt-image-2",
                "--image-size",
                "2K",
            ],
            {"GRSAI_API_KEY": "test-key"},
            client_factory=fail_factory,
        )

        self.assertEqual(result.exit_code, 2)
        self.assertEqual(result.payload["error"]["code"], "INVALID_PARAMETER_COMBINATION")
        self.assertEqual(calls, 0)

    def test_successful_generation_can_download_to_absolute_directory(self) -> None:
        """成功任务应把 URL 交给下载模块并返回本地路径。"""
        client = FakeClient(
            generate_result={
                "id": "task-download",
                "status": "succeeded",
                "results": [{"url": "https://images.example/result.png"}],
            }
        )
        download_calls: list[tuple[list[str], str, str, int]] = []

        def fake_download(
            urls: list[str],
            output_dir: str,
            task_id: str,
            max_bytes: int,
            **_context: Any,
        ) -> list[str]:
            """记录下载参数并返回虚构文件路径。"""
            download_calls.append((urls, output_dir, task_id, max_bytes))
            return [str(Path(output_dir) / "generated.png")]

        with TemporaryDirectory(prefix="grsai-cli-output-") as directory:
            result = run_command(
                [
                    "generate",
                    "--prompt",
                    "未来城市",
                    "--no-wait",
                    "--output-dir",
                    directory,
                ],
                {"GRSAI_API_KEY": "test-key"},
                client_factory=lambda _config: client,
                download_function=fake_download,
            )

        self.assertEqual(result.exit_code, 0)
        self.assertTrue(result.payload["files"][0].endswith("generated.png"))
        self.assertEqual(download_calls[0][2], "task-download")

    def test_download_failure_preserves_submitted_task_id(self) -> None:
        """提交成功后的下载失败应返回已有任务 ID，避免用户重复生图。"""
        client = FakeClient(
            generate_result={
                "id": "task-download-failed",
                "status": "succeeded",
                "results": [{"url": "https://images.example/result.png"}],
            }
        )

        def fail_download(*_arguments: Any, **_context: Any) -> list[str]:
            """模拟下载层已经结构化的失败。"""
            raise GrsaiError(
                "无法下载生成结果",
                code="DOWNLOAD_FAILED",
                phase="download",
            )

        with TemporaryDirectory(prefix="grsai-cli-output-") as directory:
            result = run_command(
                [
                    "generate",
                    "--prompt",
                    "未来城市",
                    "--output-dir",
                    directory,
                ],
                {"GRSAI_API_KEY": "test-key"},
                client_factory=lambda _config: client,
                download_function=fail_download,
            )

        self.assertEqual(result.exit_code, 3)
        self.assertEqual(result.payload["id"], "task-download-failed")
        self.assertEqual(result.payload["error"]["phase"], "download")

    def test_get_waits_for_existing_native_task(self) -> None:
        """get 命令应只查询并等待已有原生任务。"""
        client = FakeClient(
            get_result={"id": "task-get", "status": "running"},
            wait_result={
                "id": "task-get",
                "status": "succeeded",
                "results": [{"url": "https://images.example/get.png"}],
            },
        )

        result = run_command(
            ["get", "--id", "task-get", "--wait-timeout-seconds", "10"],
            {"GRSAI_API_KEY": "test-key"},
            client_factory=lambda _config: client,
        )

        self.assertEqual(result.exit_code, 0)
        self.assertEqual(result.payload["status"], "succeeded")
        self.assertEqual(client.get_calls[0][0], "task-get")
        self.assertEqual(client.wait_calls[0][1], 10_000)

    def test_get_rejects_openai_synthetic_id(self) -> None:
        """兼容后端合成 ID 不得被错误地用于原生查询。"""
        result = run_command(
            ["get", "--id", "openai-123"],
            {"GRSAI_API_KEY": "test-key"},
            client_factory=lambda _config: FakeClient(),
        )

        self.assertEqual(result.exit_code, 2)
        self.assertEqual(result.payload["error"]["code"], "INVALID_TASK_ID")

    def test_unexpected_get_error_reports_poll_phase(self) -> None:
        """查询链路的未知异常应保留 poll 阶段和已有任务 ID。"""
        client = FakeClient(get_result=RuntimeError("unexpected"))

        result = run_command(
            ["get", "--id", "task-unexpected"],
            {"GRSAI_API_KEY": "test-key"},
            client_factory=lambda _config: client,
        )

        self.assertEqual(result.exit_code, 3)
        self.assertEqual(result.payload["id"], "task-unexpected")
        self.assertEqual(result.payload["error"]["code"], "UNKNOWN_ERROR")
        self.assertEqual(result.payload["error"]["phase"], "poll")

    def test_acceptance_unknown_is_preserved_in_error_output(self) -> None:
        """提交超时的潜在计费风险必须进入结构化输出。"""
        client = FakeClient(
            generate_result=GrsaiError(
                "Grsai 请求超时",
                code="REQUEST_TIMEOUT",
                retryable=True,
                phase="submit",
                request_id="request-submit",
                timeout_ms=120_000,
                acceptance_unknown=True,
            )
        )

        result = run_command(
            ["generate", "--prompt", "未来城市", "--no-wait"],
            {"GRSAI_API_KEY": "test-key"},
            client_factory=lambda _config: client,
        )

        self.assertEqual(result.exit_code, 3)
        self.assertEqual(result.payload["status"], "failed")
        self.assertTrue(result.payload["error"]["acceptance_unknown"])
        self.assertEqual(result.payload["error"]["phase"], "submit")

    def test_error_output_redacts_api_key_from_client_message(self) -> None:
        """CLI 应对依赖层异常再做一次密钥脱敏。"""
        client = FakeClient(
            generate_result=GrsaiError(
                "上游回显 test-key",
                code="HTTP_ERROR",
                phase="submit",
            )
        )

        result = run_command(
            ["generate", "--prompt", "未来城市", "--no-wait"],
            {"GRSAI_API_KEY": "test-key"},
            client_factory=lambda _config: client,
        )

        serialized = json.dumps(result.payload, ensure_ascii=False)
        self.assertNotIn("test-key", serialized)
        self.assertNotIn("test-key", result.diagnostic)


if __name__ == "__main__":
    unittest.main()
