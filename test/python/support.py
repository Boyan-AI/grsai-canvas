"""Grsai Python 测试共用的无网络桩。"""

from __future__ import annotations

from collections.abc import Callable, Mapping
from dataclasses import replace
from typing import Any
from urllib.request import Request

from grsai_client import GrsaiConfig, HttpResponse


class StubRequester:
    """按顺序返回响应或抛出异常，并记录请求。"""

    def __init__(self, outcomes: list[HttpResponse | BaseException]) -> None:
        """保存预设结果，测试期间不会访问网络。"""
        self.outcomes = list(outcomes)
        self.calls: list[tuple[Request, float]] = []

    def __call__(self, request: Request, timeout_seconds: float) -> HttpResponse:
        """记录请求并消费一个预设结果。"""
        self.calls.append((request, timeout_seconds))
        if not self.outcomes:
            raise AssertionError("没有为请求准备测试响应")
        outcome = self.outcomes.pop(0)
        if isinstance(outcome, BaseException):
            raise outcome
        return outcome


def response(
    status: int,
    body: bytes,
    headers: Mapping[str, str] | None = None,
) -> HttpResponse:
    """创建供客户端解析的最小 HTTP 响应。"""
    return HttpResponse(status=status, headers=dict(headers or {}), body=body)


def json_response(
    payload: str,
    status: int = 200,
    headers: Mapping[str, str] | None = None,
) -> HttpResponse:
    """创建已经编码为 UTF-8 的 JSON 响应。"""
    return response(status, payload.encode("utf-8"), headers)


def make_config(**overrides: Any) -> GrsaiConfig:
    """创建使用虚构 HTTPS 节点的安全测试配置。"""
    config = GrsaiConfig(
        api_key="test-key",
        base_url="https://example.test",
        submit_timeout_ms=1_000,
        status_timeout_ms=1_000,
        sync_generation_timeout_ms=1_000,
        download_timeout_ms=1_000,
        poll_interval_ms=1,
        max_reference_image_bytes=1_024,
        max_reference_total_bytes=2_048,
        max_download_bytes=1_024,
    )
    return replace(config, **overrides)


def advancing_clock(values: list[int]) -> Callable[[], int]:
    """创建按顺序推进的毫秒时钟。"""
    remaining = list(values)

    def read() -> int:
        """返回下一个时钟值，耗尽后保持最后值。"""
        if len(remaining) > 1:
            return remaining.pop(0)
        return remaining[0]

    return read
