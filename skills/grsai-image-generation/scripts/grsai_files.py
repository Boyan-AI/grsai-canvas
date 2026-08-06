"""Grsai 参考图归一化与结果图片安全下载。"""

from __future__ import annotations

import base64
from collections.abc import Callable, Mapping, Sequence
from dataclasses import dataclass
from pathlib import Path
import re
import socket
import time
from urllib.error import HTTPError, URLError
from urllib.parse import urlsplit
from urllib.request import Request, urlopen

from grsai_client import GrsaiError


MIME_TYPES = {
    ".avif": "image/avif",
    ".gif": "image/gif",
    ".jpeg": "image/jpeg",
    ".jpg": "image/jpeg",
    ".png": "image/png",
    ".webp": "image/webp",
}
CONTENT_TYPE_EXTENSIONS = {
    "image/avif": ".avif",
    "image/gif": ".gif",
    "image/jpeg": ".jpg",
    "image/png": ".png",
    "image/webp": ".webp",
}


@dataclass(frozen=True)
class DownloadResponse:
    """保存下载器返回的状态、响应头、内容和最终地址。"""

    status: int
    headers: Mapping[str, str]
    body: bytes
    final_url: str


DownloadFetcher = Callable[[Request, float, int], DownloadResponse]


class _BodyTooLarge(Exception):
    """标记分块读取已超过下载大小预算。"""


def normalize_image_inputs(
    inputs: Sequence[str] | None,
    max_bytes: int,
    max_total_bytes: int | None = None,
) -> list[str]:
    """把 HTTPS URL、data URL 或本地图片转换为 API 输入。"""
    if not inputs:
        return []
    total_limit = max_total_bytes if max_total_bytes is not None else max_bytes * 8
    normalized: list[str] = []
    total_inline_bytes = 0
    for item in inputs:
        value, inline_bytes = _normalize_image_input(item, max_bytes)
        total_inline_bytes += inline_bytes
        if total_inline_bytes > total_limit:
            raise GrsaiError(
                "参考图内联总量超过限制："
                f"约 {_format_megabytes(total_inline_bytes)} MB，"
                f"限制 {_format_megabytes(total_limit)} MB；"
                "请减少图片、压缩图片或改用 HTTPS URL",
                code="REFERENCE_PAYLOAD_TOO_LARGE",
                phase="input",
            )
        normalized.append(value)
    return normalized


def download_images(
    urls: Sequence[str],
    output_dir: str,
    task_id: str,
    max_bytes: int,
    *,
    fetcher: DownloadFetcher | None = None,
    timeout_ms: int = 45_000,
    request_id: str | None = None,
) -> list[str]:
    """下载 HTTPS 图片并使用独占创建保证不覆盖已有文件。"""
    directory = Path(output_dir).expanduser().resolve()
    directory.mkdir(parents=True, exist_ok=True)
    resolved_fetcher = fetcher or _default_download_fetcher
    downloaded: list[str] = []
    for index, source in enumerate(urls, start=1):
        _require_https_url(source, "生成结果 URL", "INVALID_RESULT_URL")
        started_at = time.monotonic()
        request = Request(source, method="GET", headers={"Accept": "image/*"})
        try:
            response = resolved_fetcher(request, timeout_ms / 1_000, max_bytes)
            _require_https_url(
                response.final_url, "生成结果最终 URL", "INVALID_RESULT_URL"
            )
            if response.status < 200 or response.status >= 300:
                raise GrsaiError(
                    f"下载生成结果失败，HTTP {response.status}",
                    code="DOWNLOAD_FAILED",
                    status=response.status,
                    retryable=response.status >= 500,
                    phase="download",
                    request_id=request_id,
                    elapsed_ms=_elapsed_ms(started_at),
                )
            declared_length = _content_length(response.headers)
            if declared_length is not None and declared_length > max_bytes:
                raise _download_too_large_error(request_id)
            if len(response.body) > max_bytes:
                raise _download_too_large_error(request_id)
            extension = _infer_extension(
                _header(response.headers, "content-type"), response.final_url
            )
            base_name = f"grsai-{_safe_task_id(task_id)}-{index}"
            downloaded.append(
                str(
                    _write_without_overwrite(
                        directory, base_name, extension, response.body
                    )
                )
            )
        except GrsaiError:
            raise
        except _BodyTooLarge as error:
            raise _download_too_large_error(request_id) from error
        except (TimeoutError, socket.timeout) as error:
            raise _download_timeout_error(
                request_id, started_at, timeout_ms
            ) from error
        except URLError as error:
            if isinstance(error.reason, (TimeoutError, socket.timeout)):
                raise _download_timeout_error(
                    request_id, started_at, timeout_ms
                ) from error
            raise _download_network_error(request_id, started_at) from error
        except OSError as error:
            raise _download_network_error(request_id, started_at) from error
    return downloaded


def _normalize_image_input(value: str, max_bytes: int) -> tuple[str, int]:
    """校验单个参考图并返回规范值与内联字节数。"""
    normalized = value.strip()
    parsed = urlsplit(normalized)
    if parsed.scheme.lower() == "https":
        _require_https_url(normalized, "参考图 URL", "INVALID_IMAGE_URL")
        return normalized, 0
    if normalized.lower().startswith("data:image/"):
        return normalized, _validate_data_url(normalized, max_bytes)
    if parsed.scheme:
        raise GrsaiError(
            "参考图 URL 必须使用 HTTPS",
            code="INVALID_IMAGE_URL",
            phase="input",
        )

    file_path = Path(normalized).expanduser().resolve()
    if not file_path.is_file():
        raise GrsaiError(
            f"参考图不存在或不是文件：{file_path}",
            code="IMAGE_NOT_FOUND",
            phase="input",
        )
    file_size = file_path.stat().st_size
    if file_size > max_bytes:
        raise GrsaiError(
            f"参考图超过大小限制：{file_path}",
            code="IMAGE_TOO_LARGE",
            phase="input",
        )
    mime_type = MIME_TYPES.get(file_path.suffix.lower())
    if mime_type is None:
        raise GrsaiError(
            f"不支持的参考图格式：{file_path}",
            code="UNSUPPORTED_IMAGE_TYPE",
            phase="input",
        )
    encoded = base64.b64encode(file_path.read_bytes()).decode("ascii")
    return f"data:{mime_type};base64,{encoded}", file_size


def _validate_data_url(value: str, max_bytes: int) -> int:
    """严格校验 Base64 data URL 并返回真实解码大小。"""
    match = re.fullmatch(
        r"data:(image/[a-z0-9.+-]+);base64,(.*)",
        value,
        flags=re.IGNORECASE | re.DOTALL,
    )
    if match is None:
        raise GrsaiError(
            "参考图 data URL 必须使用 base64 编码",
            code="INVALID_IMAGE_DATA_URL",
            phase="input",
        )
    encoded = match.group(2)
    maximum_encoded_length = ((max_bytes + 2) // 3) * 4
    if len(encoded) > maximum_encoded_length:
        raise GrsaiError(
            "内联参考图超过大小限制",
            code="IMAGE_TOO_LARGE",
            phase="input",
        )
    try:
        decoded = base64.b64decode(encoded, validate=True)
    except (ValueError, base64.binascii.Error) as error:
        raise GrsaiError(
            "参考图 data URL 包含无效 base64 数据",
            code="INVALID_IMAGE_DATA_URL",
            phase="input",
        ) from error
    if len(decoded) > max_bytes:
        raise GrsaiError(
            "内联参考图超过大小限制",
            code="IMAGE_TOO_LARGE",
            phase="input",
        )
    return len(decoded)


def _default_download_fetcher(
    request: Request,
    timeout_seconds: float,
    max_bytes: int,
) -> DownloadResponse:
    """通过 urllib 下载响应，并以分块读取限制内存使用。"""
    try:
        with urlopen(request, timeout=timeout_seconds) as response:
            headers = dict(response.headers.items())
            declared_length = _content_length(headers)
            if declared_length is not None and declared_length > max_bytes:
                raise _BodyTooLarge
            return DownloadResponse(
                status=response.getcode(),
                headers=headers,
                body=_read_limited(response, max_bytes),
                final_url=response.geturl(),
            )
    except HTTPError as error:
        headers = dict(error.headers.items()) if error.headers else {}
        return DownloadResponse(
            status=error.code,
            headers=headers,
            body=_read_limited(error, max_bytes),
            final_url=error.geturl(),
        )


def _read_limited(stream: object, max_bytes: int) -> bytes:
    """分块读取文件对象，超过预算后立即终止。"""
    chunks: list[bytes] = []
    total = 0
    while True:
        chunk = stream.read(min(64 * 1024, max_bytes - total + 1))  # type: ignore[attr-defined]
        if not chunk:
            break
        total += len(chunk)
        if total > max_bytes:
            raise _BodyTooLarge
        chunks.append(chunk)
    return b"".join(chunks)


def _write_without_overwrite(
    directory: Path,
    base_name: str,
    extension: str,
    content: bytes,
) -> Path:
    """使用独占创建和递增后缀写入文件。"""
    for suffix in range(10_000):
        name = (
            f"{base_name}{extension}"
            if suffix == 0
            else f"{base_name}-{suffix}{extension}"
        )
        file_path = directory / name
        try:
            with file_path.open("xb") as output:
                output.write(content)
            return file_path
        except FileExistsError:
            continue
    raise GrsaiError(
        "无法为生成结果分配唯一文件名",
        code="OUTPUT_NAME_EXHAUSTED",
        phase="download",
    )


def _infer_extension(content_type: str | None, final_url: str) -> str:
    """按内容类型优先、URL 路径次之推断白名单扩展名。"""
    normalized_type = content_type.split(";", 1)[0].strip().lower() if content_type else ""
    if normalized_type in CONTENT_TYPE_EXTENSIONS:
        return CONTENT_TYPE_EXTENSIONS[normalized_type]
    extension = Path(urlsplit(final_url).path).suffix.lower()
    return extension if extension in CONTENT_TYPE_EXTENSIONS.values() else ".img"


def _safe_task_id(task_id: str) -> str:
    """清理任务 ID，避免上游值影响本地目录结构。"""
    cleaned = re.sub(r"[^a-zA-Z0-9_-]", "_", task_id)[:96]
    return cleaned or "task"


def _require_https_url(value: str, label: str, code: str) -> None:
    """要求 URL 使用 HTTPS、包含主机且不内嵌凭据。"""
    parsed = urlsplit(value)
    if (
        parsed.scheme.lower() != "https"
        or not parsed.netloc
        or parsed.username is not None
        or parsed.password is not None
    ):
        raise GrsaiError(
            f"{label} 必须使用 HTTPS",
            code=code,
            phase="download" if code == "INVALID_RESULT_URL" else "input",
        )


def _header(headers: Mapping[str, str], name: str) -> str | None:
    """以不区分大小写的方式读取响应头。"""
    target = name.lower()
    for key, value in headers.items():
        if key.lower() == target:
            return value
    return None


def _content_length(headers: Mapping[str, str]) -> int | None:
    """解析非负 Content-Length，无效值按未知长度处理。"""
    value = _header(headers, "content-length")
    if value is None:
        return None
    try:
        parsed = int(value)
    except ValueError:
        return None
    return parsed if parsed >= 0 else None


def _download_too_large_error(request_id: str | None) -> GrsaiError:
    """创建统一的下载大小超限错误。"""
    return GrsaiError(
        "生成结果超过下载大小限制",
        code="DOWNLOAD_TOO_LARGE",
        phase="download",
        request_id=request_id,
    )


def _download_timeout_error(
    request_id: str | None,
    started_at: float,
    timeout_ms: int,
) -> GrsaiError:
    """创建带请求 ID 与预算的下载超时错误。"""
    return GrsaiError(
        "下载生成结果超时",
        code="DOWNLOAD_TIMEOUT",
        retryable=True,
        phase="download",
        request_id=request_id,
        elapsed_ms=_elapsed_ms(started_at),
        timeout_ms=timeout_ms,
    )


def _download_network_error(
    request_id: str | None,
    started_at: float,
) -> GrsaiError:
    """创建不暴露底层异常内容的下载网络错误。"""
    return GrsaiError(
        "无法下载生成结果",
        code="DOWNLOAD_FAILED",
        retryable=True,
        phase="download",
        request_id=request_id,
        elapsed_ms=_elapsed_ms(started_at),
    )


def _elapsed_ms(started_at: float) -> int:
    """计算非负的单调时钟毫秒耗时。"""
    return max(0, int((time.monotonic() - started_at) * 1_000))


def _format_megabytes(value: int) -> str:
    """把字节数格式化为一位小数的 MB。"""
    return f"{value / (1024 * 1024):.1f}"
