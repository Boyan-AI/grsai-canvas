#!/usr/bin/env python3
"""Grsai 自包含 Skill 的命令行入口。"""

from __future__ import annotations

import argparse
from collections.abc import Callable, Mapping, Sequence
from dataclasses import dataclass
import json
import os
from pathlib import Path
import sys
from typing import Any
from uuid import uuid4

from grsai_client import (
    GrsaiClient,
    GrsaiConfig,
    GrsaiError,
    load_config,
    redact_sensitive_text,
    to_safe_error_message,
)
from grsai_files import download_images, normalize_image_inputs


SCRIPT_VERSION = "0.1.0"
MINIMUM_PYTHON = (3, 9)
IMAGE_MODELS = (
    "nano-banana",
    "nano-banana-fast",
    "nano-banana-2",
    "nano-banana-2-cl",
    "nano-banana-2-2k-cl",
    "nano-banana-2-4k-cl",
    "nano-banana-pro",
    "nano-banana-pro-vt",
    "nano-banana-pro-cl",
    "nano-banana-pro-vip",
    "nano-banana-pro-4k-vip",
    "gpt-image-2",
    "gpt-image-2-vip",
)
ASPECT_RATIOS = (
    "auto",
    "1:1",
    "16:9",
    "9:16",
    "4:3",
    "3:4",
    "3:2",
    "2:3",
    "5:4",
    "4:5",
    "21:9",
    "9:21",
    "1:2",
    "2:1",
    "1:3",
    "3:1",
    "1:4",
    "4:1",
    "1:8",
    "8:1",
)
GPT_IMAGE_PIXEL_SIZES = ("1024x1024", "1536x1024", "1024x1536")
IMAGE_SIZES = ("1K", "2K", "4K")


ClientFactory = Callable[[GrsaiConfig], GrsaiClient]
DownloadFunction = Callable[..., list[str]]


class CliArgumentError(Exception):
    """表示 argparse 检测到可序列化的输入错误。"""


class JsonArgumentParser(argparse.ArgumentParser):
    """保留标准帮助，但把参数错误交给 JSON 输出层。"""

    def error(self, message: str) -> None:
        """阻止 argparse 直接写 stderr 和退出进程。"""
        raise CliArgumentError(message)


@dataclass(frozen=True)
class CommandResult:
    """保存业务命令的退出码、结构化输出和安全诊断。"""

    exit_code: int
    payload: dict[str, Any]
    diagnostic: str = ""


def run_command(
    arguments: Sequence[str],
    environ: Mapping[str, str] | None = None,
    *,
    client_factory: ClientFactory = GrsaiClient,
    download_function: DownloadFunction = download_images,
) -> CommandResult:
    """解析并执行一个 CLI 命令，不直接写标准输出。"""
    request_id = str(uuid4())
    backend: str | None = None
    task_id: str | None = None
    source = os.environ if environ is None else environ
    api_key = source.get("GRSAI_API_KEY", "").strip()
    try:
        parser = _build_parser()
        parsed = parser.parse_args(list(arguments))
        if parsed.command == "doctor":
            return _doctor_result(load_config(environ))
        if parsed.command == "generate":
            backend = parsed.backend
            _validate_generate_arguments(parsed, request_id)
            config = load_config(environ)
            client = client_factory(config)
            output = _run_generate(
                parsed,
                config,
                client,
                request_id,
                download_function,
            )
            return CommandResult(0, output)
        if parsed.command == "get":
            backend = "native"
            _validate_get_arguments(parsed, request_id)
            task_id = parsed.id.strip()
            config = load_config(environ)
            client = client_factory(config)
            output = _run_get(parsed, client, request_id)
            return CommandResult(0, output)
        raise CliArgumentError("必须指定 generate、get 或 doctor 子命令")
    except CliArgumentError as error:
        grsai_error = GrsaiError(
            str(error),
            code="INVALID_ARGUMENTS",
            phase="input",
            request_id=request_id,
        )
        return _failure_result(
            grsai_error, request_id, backend, task_id, api_key
        )
    except ValueError as error:
        grsai_error = GrsaiError(
            str(error),
            code="INVALID_CONFIGURATION",
            phase="input",
            request_id=request_id,
        )
        return _failure_result(
            grsai_error, request_id, backend, task_id, api_key
        )
    except GrsaiError as error:
        return _failure_result(error, request_id, backend, task_id, api_key)
    except Exception:
        error = GrsaiError(
            "发生未知错误",
            code="UNKNOWN_ERROR",
            request_id=request_id,
        )
        return _failure_result(error, request_id, backend, task_id, api_key)


def main(arguments: Sequence[str] | None = None) -> int:
    """执行命令并保证业务路径 stdout 只包含一个 JSON 对象。"""
    result = run_command(sys.argv[1:] if arguments is None else arguments, os.environ)
    print(json.dumps(result.payload, ensure_ascii=False, separators=(",", ":")))
    if result.diagnostic:
        print(result.diagnostic, file=sys.stderr)
    return result.exit_code


def _build_parser() -> JsonArgumentParser:
    """创建三个公开子命令及其稳定参数。"""
    parser = JsonArgumentParser(
        prog="grsai-image",
        description="通过 Grsai 生成、查询并下载图片",
    )
    commands = parser.add_subparsers(dest="command", metavar="COMMAND")

    generate = commands.add_parser("generate", help="生成或参考图片编辑")
    generate.add_argument("--prompt", help="生图提示词")
    generate.add_argument("--model", choices=IMAGE_MODELS, default="gpt-image-2")
    generate.add_argument(
        "--reference-image",
        action="append",
        default=[],
        help="可重复传入 HTTPS URL、data URL 或本地图片路径",
    )
    generate.add_argument(
        "--aspect-ratio",
        choices=ASPECT_RATIOS + GPT_IMAGE_PIXEL_SIZES,
    )
    generate.add_argument("--image-size", choices=IMAGE_SIZES)
    generate.add_argument(
        "--backend",
        choices=("native", "openai-compatible"),
        default="native",
    )
    generate.add_argument(
        "--no-wait",
        action="store_false",
        dest="wait",
        default=True,
        help="提交原生任务后立即返回任务 ID",
    )
    generate.add_argument("--wait-timeout-seconds", type=int, default=180)
    generate.add_argument("--output-dir", help="成功后下载图片的本地绝对目录")

    get = commands.add_parser("get", help="查询已有原生生图任务")
    get.add_argument("--id", help="generate 返回的原生任务 ID")
    get.add_argument("--wait-timeout-seconds", type=int, default=0)

    commands.add_parser("doctor", help="检查 Python 运行时与 Grsai 配置")
    return parser


def _validate_generate_arguments(
    arguments: argparse.Namespace,
    request_id: str,
) -> None:
    """在客户端创建前校验提示词、路径和模型参数组合。"""
    prompt = (arguments.prompt or "").strip()
    if not prompt:
        raise CliArgumentError("generate 必须提供非空 --prompt")
    if len(prompt) > 32_000:
        raise CliArgumentError("--prompt 最多允许 32000 个字符")
    arguments.prompt = prompt
    if len(arguments.reference_image) > 8:
        raise CliArgumentError("--reference-image 最多允许 8 个")
    if arguments.wait_timeout_seconds < 5 or arguments.wait_timeout_seconds > 300:
        raise CliArgumentError("--wait-timeout-seconds 必须在 5 到 300 之间")
    if arguments.output_dir and not Path(arguments.output_dir).is_absolute():
        raise CliArgumentError("--output-dir 必须是绝对路径")
    _validate_generation_combination(
        arguments.model,
        arguments.backend,
        arguments.aspect_ratio,
        arguments.image_size,
        request_id,
    )


def _validate_get_arguments(
    arguments: argparse.Namespace,
    request_id: str,
) -> None:
    """校验任务 ID 和查询等待预算。"""
    task_id = (arguments.id or "").strip()
    if not task_id or len(task_id) > 200:
        raise CliArgumentError("get 必须提供 1 到 200 字符的 --id")
    if task_id.startswith("openai-"):
        raise GrsaiError(
            "openai-compatible 返回的是合成 ID，不能用于原生任务查询",
            code="INVALID_TASK_ID",
            phase="input",
            request_id=request_id,
        )
    if arguments.wait_timeout_seconds < 0 or arguments.wait_timeout_seconds > 300:
        raise CliArgumentError("--wait-timeout-seconds 必须在 0 到 300 之间")
    arguments.id = task_id


def _validate_generation_combination(
    model: str,
    backend: str,
    aspect_ratio: str | None,
    image_size: str | None,
    request_id: str,
) -> None:
    """拒绝供应商不会可靠处理的模型与尺寸组合。"""
    is_gpt_image = model.startswith("gpt-image-2")
    is_pixel_size = aspect_ratio in GPT_IMAGE_PIXEL_SIZES
    message: str | None = None
    if is_gpt_image and image_size:
        message = "gpt-image-2 系列不支持 --image-size，请使用 --aspect-ratio"
    elif not is_gpt_image and is_pixel_size:
        message = "nano-banana 系列不接受像素尺寸，请使用比例和 --image-size"
    elif backend == "openai-compatible" and image_size:
        message = "openai-compatible 后端不会处理 --image-size"
    elif (
        backend == "openai-compatible"
        and aspect_ratio is not None
        and aspect_ratio != "auto"
        and not is_pixel_size
    ):
        message = "openai-compatible 仅接受 auto 或标准像素尺寸"
    if message:
        raise GrsaiError(
            message,
            code="INVALID_PARAMETER_COMBINATION",
            phase="input",
            request_id=request_id,
        )


def _run_generate(
    arguments: argparse.Namespace,
    config: GrsaiConfig,
    client: GrsaiClient,
    request_id: str,
    download_function: DownloadFunction,
) -> dict[str, Any]:
    """编排图片输入、两种后端、异步轮询和可选下载。"""
    phase = "input"
    task_id: str | None = None
    try:
        images = normalize_image_inputs(
            arguments.reference_image,
            config.max_reference_image_bytes,
            config.max_reference_total_bytes,
        )
        if arguments.backend == "openai-compatible":
            phase = "sync_generate"
            payload: dict[str, Any] = {
                "model": arguments.model,
                "prompt": arguments.prompt,
                "response_format": "url",
            }
            if images:
                payload["image"] = images
            if arguments.aspect_ratio:
                payload["size"] = arguments.aspect_ratio
            response = client.generate_openai(payload, request_id=request_id)
            result: dict[str, Any] = {
                "id": f"openai-{response['created']}",
                "status": "succeeded",
                "results": response["data"],
            }
        else:
            phase = "submit"
            payload = {
                "model": arguments.model,
                "prompt": arguments.prompt,
                "replyType": "async",
            }
            if images:
                payload["images"] = images
            if arguments.aspect_ratio:
                payload["aspectRatio"] = arguments.aspect_ratio
            if arguments.image_size:
                payload["imageSize"] = arguments.image_size
            result = client.generate(payload, request_id=request_id)
            task_id = result["id"]
            if arguments.wait and result["status"] == "running":
                phase = "poll"
                submitted = result
                try:
                    result = client.wait_for_result(
                        result["id"],
                        arguments.wait_timeout_seconds * 1_000,
                        request_id=request_id,
                    )
                except GrsaiError as error:
                    if not _is_recoverable_polling_error(error):
                        raise
                    result = submitted
        task_id = result["id"]
        phase = "download"
        return _prepare_output(
            result,
            request_id,
            output_dir=arguments.output_dir,
            config=config,
            download_function=download_function,
        )
    except GrsaiError as error:
        if error.task_id is None:
            error.task_id = task_id
        if error.phase is None:
            error.phase = phase
        if error.request_id is None:
            error.request_id = request_id
        raise
    except Exception as error:
        raise GrsaiError(
            "发生未知错误",
            code="UNKNOWN_ERROR",
            phase=phase,
            request_id=request_id,
            task_id=task_id,
        ) from error


def _run_get(
    arguments: argparse.Namespace,
    client: GrsaiClient,
    request_id: str,
) -> dict[str, Any]:
    """查询已有任务，并按需在同一任务 ID 上继续等待。"""
    try:
        try:
            result = client.get_result(arguments.id, request_id=request_id)
        except GrsaiError as error:
            if not _is_recoverable_polling_error(error):
                raise
            result = {"id": arguments.id, "status": "running"}
        if result["status"] == "running" and arguments.wait_timeout_seconds > 0:
            initial = result
            try:
                result = client.wait_for_result(
                    arguments.id,
                    arguments.wait_timeout_seconds * 1_000,
                    request_id=request_id,
                )
            except GrsaiError as error:
                if not _is_recoverable_polling_error(error):
                    raise
                result = initial
        return _prepare_output(result, request_id)
    except GrsaiError as error:
        if error.task_id is None:
            error.task_id = arguments.id
        if error.phase is None:
            error.phase = "poll"
        if error.request_id is None:
            error.request_id = request_id
        raise
    except Exception as error:
        raise GrsaiError(
            "发生未知错误",
            code="UNKNOWN_ERROR",
            phase="poll",
            request_id=request_id,
            task_id=arguments.id,
        ) from error


def _prepare_output(
    result: Mapping[str, Any],
    request_id: str,
    *,
    output_dir: str | None = None,
    config: GrsaiConfig | None = None,
    download_function: DownloadFunction = download_images,
) -> dict[str, Any]:
    """把任务结果转换为稳定 JSON，并按需下载成功图片。"""
    urls = [item["url"] for item in result.get("results", [])]
    files: list[str] = []
    if result["status"] == "succeeded" and output_dir and urls:
        if config is None:
            raise GrsaiError(
                "下载配置缺失",
                code="INVALID_CONFIGURATION",
                phase="download",
                request_id=request_id,
            )
        files = download_function(
            urls,
            output_dir,
            result["id"],
            config.max_download_bytes,
            timeout_ms=config.download_timeout_ms,
            request_id=request_id,
        )
    output: dict[str, Any] = {
        "request_id": request_id,
        "id": result["id"],
        "status": result["status"],
        "urls": urls,
        "files": files,
    }
    if "progress" in result:
        output["progress"] = result["progress"]
    return output


def _doctor_result(config: GrsaiConfig) -> CommandResult:
    """返回不泄露密钥值的运行时与配置诊断。"""
    current = sys.version_info
    runtime_supported = current >= MINIMUM_PYTHON
    payload = {
        "status": "succeeded",
        "script_version": SCRIPT_VERSION,
        "python_version": f"{current.major}.{current.minor}.{current.micro}",
        "minimum_python": f"{MINIMUM_PYTHON[0]}.{MINIMUM_PYTHON[1]}",
        "python_supported": runtime_supported,
        "api_key_configured": bool(config.api_key),
        "ready": runtime_supported and bool(config.api_key),
    }
    return CommandResult(0, payload)


def _failure_result(
    error: GrsaiError,
    fallback_request_id: str,
    backend: str | None,
    task_id: str | None,
    api_key: str,
) -> CommandResult:
    """创建稳定错误 JSON，并按错误类别映射退出码。"""
    request_id = error.request_id or fallback_request_id
    resolved_task_id = error.task_id or task_id
    error_payload: dict[str, Any] = {
        "code": error.code,
        "message": redact_sensitive_text(str(error), api_key),
        "phase": error.phase or "input",
        "retryable": error.retryable,
        "acceptance_unknown": error.acceptance_unknown,
    }
    if backend:
        error_payload["backend"] = backend
    if error.status is not None:
        error_payload["http_status"] = error.status
    if error.upstream_request_id:
        error_payload["upstream_request_id"] = error.upstream_request_id
    if error.elapsed_ms is not None:
        error_payload["elapsed_ms"] = error.elapsed_ms
    if error.timeout_ms is not None:
        error_payload["timeout_ms"] = error.timeout_ms
    payload: dict[str, Any] = {
        "request_id": request_id,
        "status": "failed",
        "urls": [],
        "files": [],
        "error": error_payload,
    }
    if resolved_task_id:
        payload["id"] = resolved_task_id
    input_codes = {
        "INVALID_ARGUMENTS",
        "INVALID_CONFIGURATION",
        "INVALID_PARAMETER_COMBINATION",
        "INVALID_TASK_ID",
        "MISSING_API_KEY",
    }
    exit_code = 2 if error.code in input_codes or error.phase == "input" else 3
    return CommandResult(
        exit_code,
        payload,
        to_safe_error_message(error, api_key),
    )


def _is_recoverable_polling_error(error: GrsaiError) -> bool:
    """判断查询故障是否可通过已有任务 ID 稍后恢复。"""
    return error.phase == "poll" and error.retryable


if __name__ == "__main__":
    raise SystemExit(main())
