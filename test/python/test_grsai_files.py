"""Grsai 参考图处理与安全下载测试。"""

from __future__ import annotations

import base64
from pathlib import Path
import sys
from tempfile import TemporaryDirectory
import unittest
from urllib.request import Request


SCRIPT_DIRECTORY = (
    Path(__file__).resolve().parents[2]
    / "skills"
    / "grsai-image-generation"
    / "scripts"
)
sys.path.insert(0, str(SCRIPT_DIRECTORY))

from grsai_client import GrsaiError  # noqa: E402
from grsai_files import (  # noqa: E402
    DownloadResponse,
    download_images,
    normalize_image_inputs,
)


class StubDownloadFetcher:
    """按顺序返回下载响应或异常，并记录限制参数。"""

    def __init__(self, outcomes: list[DownloadResponse | BaseException]) -> None:
        """保存测试响应，避免访问真实图片地址。"""
        self.outcomes = list(outcomes)
        self.calls: list[tuple[Request, float, int]] = []

    def __call__(
        self,
        request: Request,
        timeout_seconds: float,
        max_bytes: int,
    ) -> DownloadResponse:
        """记录下载参数并消费一个预设结果。"""
        self.calls.append((request, timeout_seconds, max_bytes))
        if not self.outcomes:
            raise AssertionError("没有为下载准备测试响应")
        outcome = self.outcomes.pop(0)
        if isinstance(outcome, BaseException):
            raise outcome
        return outcome


def image_response(
    body: bytes,
    *,
    status: int = 200,
    headers: dict[str, str] | None = None,
    final_url: str = "https://images.example/result.png",
) -> DownloadResponse:
    """创建图片下载测试响应。"""
    return DownloadResponse(
        status=status,
        headers=headers or {"Content-Type": "image/png"},
        body=body,
        final_url=final_url,
    )


class ImageInputTests(unittest.TestCase):
    """验证参考图 URL、data URL 与本地文件处理。"""

    def test_local_png_is_converted_to_data_url(self) -> None:
        """本地 PNG 应按绝对路径读取并内联。"""
        with TemporaryDirectory(prefix="grsai-input-") as directory:
            path = Path(directory) / "reference.png"
            path.write_bytes(b"\x89PNG")

            result = normalize_image_inputs([str(path)], 1_024)

        self.assertTrue(result[0].startswith("data:image/png;base64,"))

    def test_https_url_is_preserved_and_http_is_rejected(self) -> None:
        """远程参考图只允许包含主机的 HTTPS URL。"""
        https_url = "https://images.example/reference.png"

        self.assertEqual(normalize_image_inputs([https_url], 1_024), [https_url])
        with self.assertRaises(GrsaiError) as raised:
            normalize_image_inputs(["http://images.example/reference.png"], 1_024)
        self.assertEqual(raised.exception.code, "INVALID_IMAGE_URL")

    def test_data_url_must_be_valid_base64_and_within_limit(self) -> None:
        """data URL 应校验编码和真实解码大小。"""
        with self.assertRaises(GrsaiError) as invalid:
            normalize_image_inputs(["data:image/png;base64,%%%"], 1_024)
        oversized = base64.b64encode(b"x" * 11).decode("ascii")
        with self.assertRaises(GrsaiError) as too_large:
            normalize_image_inputs(
                [f"data:image/png;base64,{oversized}"], max_bytes=10
            )

        self.assertEqual(invalid.exception.code, "INVALID_IMAGE_DATA_URL")
        self.assertEqual(too_large.exception.code, "IMAGE_TOO_LARGE")

    def test_inline_total_limit_is_enforced(self) -> None:
        """多张内联参考图的解码总量不得突破预算。"""
        first = base64.b64encode(b"a" * 60).decode("ascii")
        second = base64.b64encode(b"b" * 60).decode("ascii")

        with self.assertRaises(GrsaiError) as raised:
            normalize_image_inputs(
                [
                    f"data:image/png;base64,{first}",
                    f"data:image/png;base64,{second}",
                ],
                max_bytes=1_024,
                max_total_bytes=100,
            )

        self.assertEqual(raised.exception.code, "REFERENCE_PAYLOAD_TOO_LARGE")

    def test_unsupported_local_extension_is_rejected(self) -> None:
        """本地参考图只允许受支持的图片扩展名。"""
        with TemporaryDirectory(prefix="grsai-input-type-") as directory:
            path = Path(directory) / "reference.txt"
            path.write_text("not an image", encoding="utf-8")

            with self.assertRaises(GrsaiError) as raised:
                normalize_image_inputs([str(path)], 1_024)

        self.assertEqual(raised.exception.code, "UNSUPPORTED_IMAGE_TYPE")


class DownloadTests(unittest.TestCase):
    """验证图片下载限制和本地文件写入。"""

    def test_download_never_overwrites_existing_file(self) -> None:
        """相同任务重复下载应使用递增后缀。"""
        fetcher = StubDownloadFetcher(
            [image_response(b"first"), image_response(b"second")]
        )
        with TemporaryDirectory(prefix="grsai-output-") as directory:
            first = download_images(
                ["https://images.example/result.png"],
                directory,
                "task/unsafe",
                1_024,
                fetcher=fetcher,
            )
            second = download_images(
                ["https://images.example/result.png"],
                directory,
                "task/unsafe",
                1_024,
                fetcher=fetcher,
            )

            self.assertNotEqual(first[0], second[0])
            self.assertEqual(Path(first[0]).read_bytes(), b"first")
            self.assertEqual(Path(second[0]).read_bytes(), b"second")
            self.assertNotIn("/unsafe", first[0])

    def test_declared_or_actual_oversize_response_is_rejected(self) -> None:
        """响应声明大小和实际读取大小都必须受限。"""
        declared = StubDownloadFetcher(
            [image_response(b"x", headers={"Content-Length": "2048"})]
        )
        actual = StubDownloadFetcher([image_response(b"x" * 11)])
        with TemporaryDirectory(prefix="grsai-output-size-") as directory:
            with self.assertRaises(GrsaiError) as declared_error:
                download_images(
                    ["https://images.example/result.png"],
                    directory,
                    "task-size",
                    10,
                    fetcher=declared,
                )
            with self.assertRaises(GrsaiError) as actual_error:
                download_images(
                    ["https://images.example/result.png"],
                    directory,
                    "task-size",
                    10,
                    fetcher=actual,
                )

        self.assertEqual(declared_error.exception.code, "DOWNLOAD_TOO_LARGE")
        self.assertEqual(actual_error.exception.code, "DOWNLOAD_TOO_LARGE")

    def test_timeout_returns_download_diagnostics(self) -> None:
        """下载超时应保留阶段、请求 ID 和超时预算。"""
        fetcher = StubDownloadFetcher([TimeoutError("timed out")])
        with TemporaryDirectory(prefix="grsai-output-timeout-") as directory:
            with self.assertRaises(GrsaiError) as raised:
                download_images(
                    ["https://images.example/result.png"],
                    directory,
                    "task-timeout",
                    1_024,
                    fetcher=fetcher,
                    timeout_ms=12,
                    request_id="request-download",
                )

        error = raised.exception
        self.assertEqual(error.code, "DOWNLOAD_TIMEOUT")
        self.assertEqual(error.phase, "download")
        self.assertEqual(error.request_id, "request-download")
        self.assertEqual(error.timeout_ms, 12)

    def test_extension_falls_back_to_safe_url_suffix(self) -> None:
        """未知内容类型应使用白名单内的 URL 扩展名。"""
        fetcher = StubDownloadFetcher(
            [
                image_response(
                    b"webp",
                    headers={"Content-Type": "application/octet-stream"},
                    final_url="https://cdn.example/final.webp",
                )
            ]
        )
        with TemporaryDirectory(prefix="grsai-output-extension-") as directory:
            files = download_images(
                ["https://images.example/result"],
                directory,
                "task-extension",
                1_024,
                fetcher=fetcher,
            )

        self.assertTrue(files[0].endswith(".webp"))

    def test_insecure_initial_or_redirect_url_is_rejected(self) -> None:
        """初始地址和重定向后的最终地址都必须保持 HTTPS。"""
        with TemporaryDirectory(prefix="grsai-output-url-") as directory:
            with self.assertRaises(GrsaiError) as initial:
                download_images(
                    ["http://images.example/result.png"],
                    directory,
                    "task-url",
                    1_024,
                    fetcher=StubDownloadFetcher([]),
                )
            with self.assertRaises(GrsaiError) as redirected:
                download_images(
                    ["https://images.example/result.png"],
                    directory,
                    "task-url",
                    1_024,
                    fetcher=StubDownloadFetcher(
                        [image_response(b"x", final_url="http://cdn.example/result.png")]
                    ),
                )

        self.assertEqual(initial.exception.code, "INVALID_RESULT_URL")
        self.assertEqual(redirected.exception.code, "INVALID_RESULT_URL")


if __name__ == "__main__":
    unittest.main()
