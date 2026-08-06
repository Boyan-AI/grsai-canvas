"""Grsai 标准库 HTTP 客户端测试。"""

from __future__ import annotations

import json
from pathlib import Path
import sys
import unittest
from urllib.error import URLError


SCRIPT_DIRECTORY = (
    Path(__file__).resolve().parents[2]
    / "skills"
    / "grsai-image-generation"
    / "scripts"
)
TEST_DIRECTORY = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIRECTORY))
sys.path.insert(0, str(TEST_DIRECTORY))

from grsai_client import GrsaiClient, GrsaiError, load_config  # noqa: E402
from support import (  # noqa: E402
    StubRequester,
    advancing_clock,
    json_response,
    make_config,
)


class ConfigTests(unittest.TestCase):
    """验证环境变量兼容性和安全默认值。"""

    def test_load_config_preserves_existing_defaults(self) -> None:
        """默认配置应与 TypeScript 实现保持一致。"""
        config = load_config({"GRSAI_API_KEY": " key-with-space "})

        self.assertEqual(config.api_key, "key-with-space")
        self.assertEqual(config.base_url, "https://grsai.dakka.com.cn")
        self.assertEqual(config.submit_timeout_ms, 120_000)
        self.assertEqual(config.status_timeout_ms, 30_000)
        self.assertEqual(config.sync_generation_timeout_ms, 300_000)
        self.assertEqual(config.download_timeout_ms, 45_000)
        self.assertEqual(config.poll_interval_ms, 2_000)

    def test_load_config_uses_legacy_timeout_as_fallback(self) -> None:
        """旧共享超时应继续作为三个请求阶段的回退值。"""
        config = load_config(
            {
                "GRSAI_API_KEY": "test-key",
                "GRSAI_REQUEST_TIMEOUT_MS": "4321",
                "GRSAI_STATUS_TIMEOUT_MS": "1234",
            }
        )

        self.assertEqual(config.submit_timeout_ms, 4_321)
        self.assertEqual(config.status_timeout_ms, 1_234)
        self.assertEqual(config.sync_generation_timeout_ms, 4_321)

    def test_load_config_rejects_insecure_or_invalid_values(self) -> None:
        """非 HTTPS 节点和非正整数预算应在请求前被拒绝。"""
        with self.assertRaisesRegex(ValueError, "HTTPS"):
            load_config(
                {
                    "GRSAI_API_KEY": "test-key",
                    "GRSAI_BASE_URL": "http://example.test",
                }
            )
        with self.assertRaisesRegex(ValueError, "正整数"):
            load_config(
                {
                    "GRSAI_API_KEY": "test-key",
                    "GRSAI_SUBMIT_TIMEOUT_MS": "0",
                }
            )


class GrsaiClientTests(unittest.TestCase):
    """验证 HTTP、轮询和错误诊断语义。"""

    def test_generate_sends_bearer_authentication_and_json(self) -> None:
        """原生异步提交应携带鉴权与 UTF-8 JSON。"""
        requester = StubRequester(
            [json_response('{"id":"task-1","status":"running","progress":10}')]
        )
        client = GrsaiClient(make_config(), requester=requester)

        result = client.generate(
            {
                "model": "nano-banana-2",
                "prompt": "一只猫",
                "replyType": "async",
            },
            request_id="request-1",
        )

        request, timeout_seconds = requester.calls[0]
        self.assertEqual(result["id"], "task-1")
        self.assertEqual(request.full_url, "https://example.test/v1/api/generate")
        self.assertEqual(request.get_header("Authorization"), "Bearer test-key")
        self.assertEqual(json.loads(request.data or b"{}")["prompt"], "一只猫")
        self.assertEqual(timeout_seconds, 1.0)

    def test_wait_for_result_reuses_id_until_success(self) -> None:
        """轮询应查询已有任务，不能重新提交付费请求。"""
        requester = StubRequester(
            [
                json_response('{"id":"task-2","status":"running","progress":50}'),
                json_response(
                    '{"id":"task-2","status":"succeeded",'
                    '"results":[{"url":"https://images.example/result.png"}]}'
                ),
            ]
        )
        client = GrsaiClient(
            make_config(),
            requester=requester,
            sleep=lambda _seconds: None,
            clock_ms=advancing_clock([0, 1, 2, 3]),
        )

        result = client.wait_for_result("task-2", 1_000, poll_interval_ms=1)

        self.assertEqual(result["status"], "succeeded")
        self.assertEqual(len(requester.calls), 2)
        self.assertTrue(
            all("/v1/api/result?id=task-2" in call[0].full_url for call in requester.calls)
        )

    def test_http_error_exposes_safe_retry_diagnostics(self) -> None:
        """限流响应应转换为可重试且可联查的安全错误。"""
        requester = StubRequester(
            [
                json_response(
                    '{"error":{"message":"quota exceeded"}}',
                    status=429,
                    headers={"X-Request-Id": "upstream-123"},
                )
            ]
        )
        client = GrsaiClient(make_config(), requester=requester)

        with self.assertRaises(GrsaiError) as raised:
            client.get_result("task-3", request_id="request-3")

        error = raised.exception
        self.assertEqual(error.code, "HTTP_ERROR")
        self.assertEqual(error.phase, "poll")
        self.assertTrue(error.retryable)
        self.assertEqual(error.upstream_request_id, "upstream-123")
        self.assertNotIn("test-key", str(error))

    def test_http_error_redacts_api_key_echoed_by_upstream(self) -> None:
        """上游错误即使回显鉴权值，也不得把 API Key 暴露给调用方。"""
        requester = StubRequester(
            [
                json_response(
                    '{"error":{"message":"Authorization: Bearer test-key"}}',
                    status=400,
                )
            ]
        )
        client = GrsaiClient(make_config(), requester=requester)

        with self.assertRaises(GrsaiError) as raised:
            client.get_result("task-redaction", request_id="request-redaction")

        self.assertNotIn("test-key", str(raised.exception))

    def test_failed_generation_preserves_task_id(self) -> None:
        """上游已分配任务 ID 后的生成失败应保留该 ID 供联查。"""
        requester = StubRequester(
            [
                json_response(
                    '{"id":"task-failed","status":"failed",'
                    '"error":"provider failed"}'
                )
            ]
        )
        client = GrsaiClient(make_config(), requester=requester)

        with self.assertRaises(GrsaiError) as raised:
            client.generate({"model": "gpt-image-2", "prompt": "一只猫"})

        self.assertEqual(raised.exception.task_id, "task-failed")

    def test_server_error_is_retryable(self) -> None:
        """上游 5xx 响应应标记为可重试，但不表示接收状态未知。"""
        requester = StubRequester(
            [json_response('{"error":"temporarily unavailable"}', status=503)]
        )
        client = GrsaiClient(make_config(), requester=requester)

        with self.assertRaises(GrsaiError) as raised:
            client.get_result("task-503", request_id="request-503")

        error = raised.exception
        self.assertEqual(error.status, 503)
        self.assertTrue(error.retryable)
        self.assertFalse(error.acceptance_unknown)

    def test_generate_openai_validates_response_urls(self) -> None:
        """同步兼容接口应返回经过校验的图片 URL。"""
        requester = StubRequester(
            [
                json_response(
                    '{"created":123,"data":['
                    '{"url":"https://images.example/result.png"}],'
                    '"usage":{"total_tokens":10}}'
                )
            ]
        )
        client = GrsaiClient(make_config(), requester=requester)

        result = client.generate_openai(
            {
                "model": "gpt-image-2",
                "prompt": "海边日落",
                "response_format": "url",
            }
        )

        self.assertEqual(
            result["data"][0]["url"], "https://images.example/result.png"
        )
        self.assertTrue(requester.calls[0][0].full_url.endswith("/v1/images/generations"))

    def test_missing_key_never_calls_requester(self) -> None:
        """缺少密钥时不得发出任何网络请求。"""
        requester = StubRequester([])
        client = GrsaiClient(make_config(api_key=""), requester=requester)

        with self.assertRaises(GrsaiError) as raised:
            client.get_result("task-without-key")

        self.assertEqual(raised.exception.code, "MISSING_API_KEY")
        self.assertEqual(requester.calls, [])

    def test_submit_timeout_marks_acceptance_unknown(self) -> None:
        """提交超时应警告任务可能已被接收或计费。"""
        requester = StubRequester([TimeoutError("timed out")])
        client = GrsaiClient(make_config(), requester=requester)

        with self.assertRaises(GrsaiError) as raised:
            client.generate(
                {"model": "gpt-image-2", "prompt": "一只猫"},
                request_id="request-submit",
                timeout_ms=12,
            )

        error = raised.exception
        self.assertEqual(error.code, "REQUEST_TIMEOUT")
        self.assertEqual(error.phase, "submit")
        self.assertEqual(error.request_id, "request-submit")
        self.assertEqual(error.timeout_ms, 12)
        self.assertTrue(error.acceptance_unknown)

    def test_sync_timeout_marks_acceptance_unknown(self) -> None:
        """同步生图超时也应保留潜在计费风险。"""
        requester = StubRequester([TimeoutError("timed out")])
        client = GrsaiClient(make_config(), requester=requester)

        with self.assertRaises(GrsaiError) as raised:
            client.generate_openai(
                {"model": "gpt-image-2", "prompt": "一只猫"},
                request_id="request-sync",
                timeout_ms=15,
            )

        error = raised.exception
        self.assertEqual(error.phase, "sync_generate")
        self.assertEqual(error.timeout_ms, 15)
        self.assertTrue(error.acceptance_unknown)

    def test_non_json_and_invalid_schema_are_rejected(self) -> None:
        """不可解析或不符合契约的响应不得进入业务流程。"""
        non_json = GrsaiClient(
            make_config(), requester=StubRequester([json_response("not json")])
        )
        invalid_schema = GrsaiClient(
            make_config(), requester=StubRequester([json_response('{"status":"running"}')])
        )

        with self.assertRaises(GrsaiError) as non_json_error:
            non_json.get_result("task-json")
        with self.assertRaises(GrsaiError) as schema_error:
            invalid_schema.get_result("task-schema")

        self.assertEqual(non_json_error.exception.code, "INVALID_JSON")
        self.assertEqual(schema_error.exception.code, "INVALID_RESPONSE")

    def test_network_error_does_not_expose_key(self) -> None:
        """网络故障应可重试，且不得泄露 API Key。"""
        requester = StubRequester([URLError("offline")])
        client = GrsaiClient(make_config(), requester=requester)

        with self.assertRaises(GrsaiError) as raised:
            client.get_result("task-offline", request_id="request-offline")

        error = raised.exception
        self.assertEqual(error.code, "NETWORK_ERROR")
        self.assertEqual(error.phase, "poll")
        self.assertTrue(error.retryable)
        self.assertNotIn("test-key", str(error))


if __name__ == "__main__":
    unittest.main()
