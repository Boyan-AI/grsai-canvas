"""Grsai 生图接口的标准库客户端、配置与安全错误模型。"""

from __future__ import annotations

from collections.abc import Callable, Mapping
from dataclasses import dataclass
import json
import os
import socket
import time
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode, urlsplit
from urllib.request import Request, urlopen
from uuid import uuid4


DEFAULT_BASE_URL = "https://grsai.dakka.com.cn"
GENERATION_STATUSES = {"running", "violation", "succeeded", "failed"}


@dataclass(frozen=True)
class GrsaiConfig:
    """保存 Grsai CLI 的运行时配置与安全预算。"""

    api_key: str
    base_url: str
    submit_timeout_ms: int
    status_timeout_ms: int
    sync_generation_timeout_ms: int
    download_timeout_ms: int
    poll_interval_ms: int
    max_reference_image_bytes: int
    max_reference_total_bytes: int
    max_download_bytes: int


@dataclass(frozen=True)
class HttpResponse:
    """隔离 urllib 细节的最小 HTTP 响应。"""

    status: int
    headers: Mapping[str, str]
    body: bytes


class GrsaiError(Exception):
    """对外稳定暴露且不携带敏感响应内容的调用错误。"""

    def __init__(
        self,
        message: str,
        *,
        code: str,
        status: int | None = None,
        retryable: bool = False,
        phase: str | None = None,
        request_id: str | None = None,
        task_id: str | None = None,
        upstream_request_id: str | None = None,
        elapsed_ms: int | None = None,
        timeout_ms: int | None = None,
        acceptance_unknown: bool = False,
    ) -> None:
        """保存可安全序列化的错误诊断字段。"""
        super().__init__(message)
        self.code = code
        self.status = status
        self.retryable = retryable
        self.phase = phase
        self.request_id = request_id
        self.task_id = task_id
        self.upstream_request_id = upstream_request_id
        self.elapsed_ms = elapsed_ms
        self.timeout_ms = timeout_ms
        self.acceptance_unknown = acceptance_unknown


Requester = Callable[[Request, float], HttpResponse]
Sleep = Callable[[float], None]
Clock = Callable[[], int]


def load_config(environ: Mapping[str, str] | None = None) -> GrsaiConfig:
    """从环境变量读取配置，并保持旧版超时变量兼容性。"""
    source = os.environ if environ is None else environ
    legacy_timeout = _read_optional_positive_integer(
        source.get("GRSAI_REQUEST_TIMEOUT_MS")
    )
    return GrsaiConfig(
        api_key=source.get("GRSAI_API_KEY", "").strip(),
        base_url=_normalize_base_url(
            source.get("GRSAI_BASE_URL", DEFAULT_BASE_URL)
        ),
        submit_timeout_ms=_read_positive_integer(
            source.get("GRSAI_SUBMIT_TIMEOUT_MS"), legacy_timeout or 120_000
        ),
        status_timeout_ms=_read_positive_integer(
            source.get("GRSAI_STATUS_TIMEOUT_MS"), legacy_timeout or 30_000
        ),
        sync_generation_timeout_ms=_read_positive_integer(
            source.get("GRSAI_SYNC_GENERATION_TIMEOUT_MS"),
            legacy_timeout or 300_000,
        ),
        download_timeout_ms=_read_positive_integer(
            source.get("GRSAI_DOWNLOAD_TIMEOUT_MS"), 45_000
        ),
        poll_interval_ms=_read_positive_integer(
            source.get("GRSAI_POLL_INTERVAL_MS"), 2_000
        ),
        max_reference_image_bytes=_read_positive_integer(
            source.get("GRSAI_MAX_REFERENCE_BYTES"), 10 * 1024 * 1024
        ),
        max_reference_total_bytes=_read_positive_integer(
            source.get("GRSAI_MAX_REFERENCE_TOTAL_BYTES"), 8 * 1024 * 1024
        ),
        max_download_bytes=_read_positive_integer(
            source.get("GRSAI_MAX_DOWNLOAD_BYTES"), 50 * 1024 * 1024
        ),
    )


def redact_sensitive_text(value: str, secret: str | None) -> str:
    """把指定密钥从外部可见文本中替换为固定占位符。"""
    normalized_secret = (secret or "").strip()
    if not normalized_secret:
        return value
    return value.replace(normalized_secret, "[REDACTED]")


def to_safe_error_message(
    error: BaseException,
    secret: str | None = None,
) -> str:
    """把异常转换为不含密钥和完整响应体的简短文本。"""
    if not isinstance(error, GrsaiError):
        return redact_sensitive_text(str(error) or "发生未知错误", secret)
    details = [error.code]
    if error.phase:
        details.append(f"阶段 {error.phase}")
    if error.request_id:
        details.append(f"请求 {error.request_id}")
    warning = (
        "；上游是否已接收任务未知，请勿直接重复提交"
        if error.acceptance_unknown
        else ""
    )
    return redact_sensitive_text(
        f"{error}（{'；'.join(details)}）{warning}", secret
    )


class GrsaiClient:
    """封装 Grsai 原生与 OpenAI 兼容接口及异步轮询。"""

    def __init__(
        self,
        config: GrsaiConfig,
        *,
        requester: Requester | None = None,
        sleep: Sleep = time.sleep,
        clock_ms: Clock | None = None,
    ) -> None:
        """注入网络、休眠和时钟依赖，便于无网络测试。"""
        self.config = config
        self.requester = requester or _default_requester
        self.sleep = sleep
        self.clock_ms = clock_ms or (lambda: int(time.monotonic() * 1_000))

    def generate(
        self,
        payload: Mapping[str, Any],
        *,
        request_id: str | None = None,
        timeout_ms: int | None = None,
    ) -> dict[str, Any]:
        """提交原生 Grsai 异步生图任务。"""
        resolved_request_id = request_id or str(uuid4())
        response = self._request_json(
            "/v1/api/generate",
            method="POST",
            payload=payload,
            request_id=resolved_request_id,
            timeout_ms=timeout_ms or self.config.submit_timeout_ms,
            phase="submit",
            acceptance_unknown_on_timeout=True,
        )
        return _parse_generation_response(
            response, phase="submit", request_id=resolved_request_id
        )

    def get_result(
        self,
        task_id: str,
        *,
        request_id: str | None = None,
        timeout_ms: int | None = None,
    ) -> dict[str, Any]:
        """查询一个已经存在的异步生图任务。"""
        resolved_request_id = request_id or str(uuid4())
        path = f"/v1/api/result?{urlencode({'id': task_id})}"
        response = self._request_json(
            path,
            method="GET",
            payload=None,
            request_id=resolved_request_id,
            timeout_ms=timeout_ms or self.config.status_timeout_ms,
            phase="poll",
            acceptance_unknown_on_timeout=False,
        )
        return _parse_generation_response(
            response, phase="poll", request_id=resolved_request_id
        )

    def wait_for_result(
        self,
        task_id: str,
        timeout_ms: int,
        *,
        poll_interval_ms: int | None = None,
        request_id: str | None = None,
    ) -> dict[str, Any]:
        """在总截止时间内轮询任务，超时后保留任务 ID 供续查。"""
        started_at = self.clock_ms()
        deadline = started_at + timeout_ms
        interval_ms = poll_interval_ms or self.config.poll_interval_ms
        resolved_request_id = request_id or str(uuid4())
        result = self._get_result_within_deadline(
            task_id, deadline, resolved_request_id
        )
        while result["status"] == "running":
            if self.clock_ms() + interval_ms > deadline:
                raise GrsaiError(
                    "等待生图任务超时，可使用任务 ID 稍后查询",
                    code="POLL_TIMEOUT",
                    retryable=True,
                    phase="poll",
                    request_id=resolved_request_id,
                    elapsed_ms=max(0, self.clock_ms() - started_at),
                    timeout_ms=timeout_ms,
                )
            self.sleep(interval_ms / 1_000)
            result = self._get_result_within_deadline(
                task_id, deadline, resolved_request_id
            )
        return result

    def generate_openai(
        self,
        payload: Mapping[str, Any],
        *,
        request_id: str | None = None,
        timeout_ms: int | None = None,
    ) -> dict[str, Any]:
        """调用 OpenAI 兼容的同步图片生成接口。"""
        resolved_request_id = request_id or str(uuid4())
        response = self._request_json(
            "/v1/images/generations",
            method="POST",
            payload=payload,
            request_id=resolved_request_id,
            timeout_ms=timeout_ms or self.config.sync_generation_timeout_ms,
            phase="sync_generate",
            acceptance_unknown_on_timeout=True,
        )
        return _parse_openai_response(response, resolved_request_id)

    def _get_result_within_deadline(
        self,
        task_id: str,
        deadline: int,
        request_id: str,
    ) -> dict[str, Any]:
        """用轮询剩余预算执行一次状态查询。"""
        remaining_ms = deadline - self.clock_ms()
        if remaining_ms <= 0:
            raise GrsaiError(
                "等待生图任务超时，可使用任务 ID 稍后查询",
                code="POLL_TIMEOUT",
                retryable=True,
                phase="poll",
                request_id=request_id,
                timeout_ms=0,
            )
        return self.get_result(
            task_id,
            request_id=request_id,
            timeout_ms=min(self.config.status_timeout_ms, remaining_ms),
        )

    def _request_json(
        self,
        path: str,
        *,
        method: str,
        payload: Mapping[str, Any] | None,
        request_id: str,
        timeout_ms: int,
        phase: str,
        acceptance_unknown_on_timeout: bool,
    ) -> Any:
        """发送 JSON 请求，并统一转换 HTTP、网络与超时错误。"""
        if not self.config.api_key:
            raise GrsaiError(
                "缺少 GRSAI_API_KEY 环境变量",
                code="MISSING_API_KEY",
                phase=phase,
                request_id=request_id,
            )
        started_at = self.clock_ms()
        data = (
            json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode(
                "utf-8"
            )
            if payload is not None
            else None
        )
        request = Request(
            f"{self.config.base_url}{path}",
            data=data,
            method=method,
            headers={
                "Authorization": f"Bearer {self.config.api_key}",
                "Content-Type": "application/json",
                "Accept": "application/json",
            },
        )
        try:
            response = self.requester(request, timeout_ms / 1_000)
        except (TimeoutError, socket.timeout) as error:
            raise self._request_timeout_error(
                phase,
                request_id,
                started_at,
                timeout_ms,
                acceptance_unknown_on_timeout,
            ) from error
        except URLError as error:
            if isinstance(error.reason, (TimeoutError, socket.timeout)):
                raise self._request_timeout_error(
                    phase,
                    request_id,
                    started_at,
                    timeout_ms,
                    acceptance_unknown_on_timeout,
                ) from error
            raise GrsaiError(
                "无法连接 Grsai 服务",
                code="NETWORK_ERROR",
                retryable=True,
                phase=phase,
                request_id=request_id,
                elapsed_ms=max(0, self.clock_ms() - started_at),
                acceptance_unknown=acceptance_unknown_on_timeout,
            ) from error
        except OSError as error:
            raise GrsaiError(
                "无法连接 Grsai 服务",
                code="NETWORK_ERROR",
                retryable=True,
                phase=phase,
                request_id=request_id,
                elapsed_ms=max(0, self.clock_ms() - started_at),
                acceptance_unknown=acceptance_unknown_on_timeout,
            ) from error

        parsed = _parse_json(response, phase, request_id)
        if response.status < 200 or response.status >= 300:
            raise GrsaiError(
                _extract_error_message(
                    parsed,
                    response.status,
                    self.config.api_key,
                ),
                code="HTTP_ERROR",
                status=response.status,
                retryable=response.status == 429 or response.status >= 500,
                phase=phase,
                request_id=request_id,
                upstream_request_id=_extract_upstream_request_id(
                    response.headers
                ),
                elapsed_ms=max(0, self.clock_ms() - started_at),
            )
        return parsed

    def _request_timeout_error(
        self,
        phase: str,
        request_id: str,
        started_at: int,
        timeout_ms: int,
        acceptance_unknown: bool,
    ) -> GrsaiError:
        """构造带阶段和潜在计费风险的请求超时错误。"""
        return GrsaiError(
            "Grsai 请求超时",
            code="REQUEST_TIMEOUT",
            retryable=True,
            phase=phase,
            request_id=request_id,
            elapsed_ms=max(0, self.clock_ms() - started_at),
            timeout_ms=timeout_ms,
            acceptance_unknown=acceptance_unknown,
        )


def _default_requester(request: Request, timeout_seconds: float) -> HttpResponse:
    """通过 urllib 执行请求，并把 HTTPError 统一为响应对象。"""
    try:
        with urlopen(request, timeout=timeout_seconds) as response:
            return HttpResponse(
                status=response.getcode(),
                headers=dict(response.headers.items()),
                body=response.read(),
            )
    except HTTPError as error:
        return HttpResponse(
            status=error.code,
            headers=dict(error.headers.items()) if error.headers else {},
            body=error.read(),
        )


def _parse_json(
    response: HttpResponse,
    phase: str,
    request_id: str,
) -> Any:
    """解析 UTF-8 JSON，拒绝暴露不可解析的完整响应体。"""
    try:
        return json.loads(response.body.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise GrsaiError(
            "Grsai 返回了非 JSON 响应",
            code="INVALID_JSON",
            status=response.status,
            retryable=response.status >= 500,
            phase=phase,
            request_id=request_id,
        ) from error


def _parse_generation_response(
    payload: Any,
    *,
    phase: str,
    request_id: str,
) -> dict[str, Any]:
    """校验原生任务响应，并转换失败或违规状态。"""
    if not isinstance(payload, dict):
        raise _invalid_response_error(phase, request_id, "任务")
    task_id = payload.get("id")
    status = payload.get("status")
    if not isinstance(task_id, str) or not task_id or status not in GENERATION_STATUSES:
        raise _invalid_response_error(phase, request_id, "任务")
    progress = payload.get("progress")
    if progress is not None and (
        isinstance(progress, bool)
        or not isinstance(progress, int)
        or progress < 0
        or progress > 100
    ):
        raise _invalid_response_error(phase, request_id, "任务")
    results = payload.get("results")
    if results is not None:
        _validate_results(results, phase, request_id)
    error_message = payload.get("error")
    if error_message is not None and not isinstance(error_message, str):
        raise _invalid_response_error(phase, request_id, "任务")
    if status in {"failed", "violation"}:
        raise GrsaiError(
            error_message
            or ("生成内容未通过安全检查" if status == "violation" else "图片生成失败"),
            code=(
                "CONTENT_VIOLATION" if status == "violation" else "GENERATION_FAILED"
            ),
            phase=phase,
            request_id=request_id,
            task_id=task_id,
        )
    normalized: dict[str, Any] = {"id": task_id, "status": status}
    if results is not None:
        normalized["results"] = results
    if progress is not None:
        normalized["progress"] = progress
    if error_message is not None:
        normalized["error"] = error_message
    return normalized


def _parse_openai_response(payload: Any, request_id: str) -> dict[str, Any]:
    """校验 OpenAI 兼容生图响应。"""
    if not isinstance(payload, dict):
        raise _invalid_response_error("sync_generate", request_id, "兼容接口")
    created = payload.get("created")
    data = payload.get("data")
    if isinstance(created, bool) or not isinstance(created, int):
        raise _invalid_response_error("sync_generate", request_id, "兼容接口")
    _validate_results(data, "sync_generate", request_id)
    normalized: dict[str, Any] = {"created": created, "data": data}
    usage = payload.get("usage")
    if usage is not None:
        if not isinstance(usage, dict):
            raise _invalid_response_error(
                "sync_generate", request_id, "兼容接口"
            )
        normalized["usage"] = usage
    return normalized


def _validate_results(results: Any, phase: str, request_id: str) -> None:
    """校验结果数组中的 URL 结构。"""
    if not isinstance(results, list):
        raise _invalid_response_error(phase, request_id, "任务")
    for item in results:
        if not isinstance(item, dict) or not _is_http_url(item.get("url")):
            raise _invalid_response_error(phase, request_id, "任务")


def _invalid_response_error(
    phase: str,
    request_id: str,
    response_kind: str,
) -> GrsaiError:
    """创建统一的上游响应契约错误。"""
    return GrsaiError(
        f"Grsai 返回了无法识别的{response_kind}响应",
        code="INVALID_RESPONSE",
        phase=phase,
        request_id=request_id,
    )


def _is_http_url(value: Any) -> bool:
    """判断值是否为包含主机的 HTTP 或 HTTPS URL。"""
    if not isinstance(value, str):
        return False
    parsed = urlsplit(value)
    return parsed.scheme in {"http", "https"} and bool(parsed.netloc)


def _extract_upstream_request_id(headers: Mapping[str, str]) -> str | None:
    """从常见响应头中提取有限长度的上游请求标识。"""
    normalized = {key.lower(): value for key, value in headers.items()}
    for name in ("x-request-id", "request-id", "cf-ray"):
        value = normalized.get(name)
        if value:
            return value[:200]
    return None


def _extract_error_message(
    payload: Any,
    status: int,
    api_key: str,
) -> str:
    """从已解析响应中提取最多 500 字符的公开错误文本。"""
    message: str | None = None
    if isinstance(payload, dict):
        error = payload.get("error")
        if isinstance(error, str):
            message = error[:500]
        elif isinstance(error, dict) and isinstance(error.get("message"), str):
            message = error["message"][:500]
    return redact_sensitive_text(
        message or f"Grsai 请求失败，HTTP {status}",
        api_key,
    )


def _read_optional_positive_integer(value: str | None) -> int | None:
    """读取可选正整数环境变量。"""
    return None if value is None else _read_positive_integer(value, 1)


def _read_positive_integer(value: str | None, fallback: int) -> int:
    """读取正整数，未设置时返回指定默认值。"""
    if value is None:
        return fallback
    try:
        parsed = int(value)
    except ValueError as error:
        raise ValueError(f"环境变量必须是正整数，实际值为 {value}") from error
    if parsed <= 0 or str(parsed) != value.strip():
        raise ValueError(f"环境变量必须是正整数，实际值为 {value}")
    return parsed


def _normalize_base_url(value: str) -> str:
    """规范化 HTTPS 基础节点并拒绝凭据和查询参数。"""
    normalized = value.strip()
    parsed = urlsplit(normalized)
    if (
        parsed.scheme != "https"
        or not parsed.netloc
        or parsed.username is not None
        or parsed.password is not None
        or parsed.query
        or parsed.fragment
    ):
        raise ValueError("GRSAI_BASE_URL 必须使用不含凭据、查询或片段的 HTTPS URL")
    return normalized.rstrip("/")
