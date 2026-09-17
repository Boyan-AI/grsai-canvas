#!/usr/bin/env python3
"""Grsai 自包含 Skill 的命令行入口。"""

from __future__ import annotations

import argparse
from collections.abc import Callable, Mapping, Sequence
from dataclasses import dataclass
import json
import os
from pathlib import Path
import re
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
from grsai_files import download_media, normalize_audio_inputs, normalize_image_inputs


SCRIPT_VERSION = "0.2.0"
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
    "gpt-image-2.5",
    "gpt-image-2.5-flare",
    "gpt-image-2.5-sunburst",
)
VIDEO_MODELS = ("minimax-h3",)
VIDEO_ASPECT_RATIOS = ("portrait", "landscape", "square")
VIDEO_RESOLUTIONS = ("480p", "768p", "1080p")
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
GPT_PREMIUM_MODELS = (
    "gpt-image-2-vip",
    "gpt-image-2.5-flare",
    "gpt-image-2.5-sunburst",
)
GPT_STANDARD_MODELS = ("gpt-image-2", "gpt-image-2.5")
GPT_STANDARD_ASPECT_RATIOS = (
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
)
GPT_PREMIUM_PIXEL_SIZES = (
    "1024x1024", "2048x2048", "2880x2880",
    "1280x720", "2048x1152", "3840x2160",
    "720x1280", "1152x2048", "2160x3840",
    "1152x864", "2304x1728", "3264x2448",
    "864x1152", "1728x2304", "2448x3264",
    "1536x1024", "2048x1360", "3504x2336",
    "1024x1536", "1360x2048", "2336x3504",
    "1120x896", "2240x1792", "3200x2560",
    "896x1120", "1792x2240", "2560x3200",
    "1456x624", "2912x1248", "3840x1648",
    "624x1456", "1248x2912", "1648x3840",
    "688x2048", "1280x3840", "2048x688", "3840x1280",
    "1536x768", "3072x1536", "3840x1920",
    "768x1536", "1536x3072", "1920x3840",
)
QUALITY_VALUES = ("auto", "low", "medium", "high", "xhigh", "max")
QUALITY_BY_MODEL = {
    "gpt-image-2": ("auto",),
    "gpt-image-2.5": ("auto",),
    "gpt-image-2-vip": ("medium",),
    "gpt-image-2.5-flare": ("low", "medium", "high"),
    "gpt-image-2.5-sunburst": ("low", "medium", "high", "xhigh", "max"),
}
GPT_MASK_PATTERN = re.compile(r"^https://[^\s/]+(?:/[^\s]*)?$")


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
    download_function: DownloadFunction = download_media,
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
            output = _run_get(parsed, config, client, request_id, download_function)
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
    generate.add_argument("--model", choices=IMAGE_MODELS + VIDEO_MODELS, default="gpt-image-2")
    generate.add_argument(
        "--reference-image",
        action="append",
        default=[],
        help="可重复传入 HTTPS URL、data URL 或本地图片路径",
    )
    generate.add_argument(
        "--aspect-ratio",
        help="图片比例/像素尺寸，或视频 portrait、landscape、square",
    )
    generate.add_argument(
        "--reference-audio",
        action="append",
        default=[],
        help="视频可重复传入 HTTPS URL、data URL 或本地音频路径",
    )
    generate.add_argument("--resolution", choices=VIDEO_RESOLUTIONS)
    generate.add_argument("--duration", type=int, help="视频时长，单位秒，范围 1-15")
    generate.add_argument("--seed", type=int, help="视频随机种子")
    generate.add_argument("--image-size", choices=IMAGE_SIZES)
    generate.add_argument("--quality", choices=QUALITY_VALUES)
    generate.add_argument("--background", choices=("transparent",))
    generate.add_argument("--mask", help="HTTPS 遮罩图片地址")
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
    get.add_argument("--media-type", choices=("image", "video"), default="image")
    get.add_argument("--output-dir", help="成功后下载结果的本地绝对目录")

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
    maximum_images = 9 if arguments.model in VIDEO_MODELS else 8
    if len(arguments.reference_image) > maximum_images:
        raise CliArgumentError(f"--reference-image 最多允许 {maximum_images} 个")
    if len(arguments.reference_audio) > 3:
        raise CliArgumentError("--reference-audio 最多允许 3 个")
    if arguments.wait_timeout_seconds < 5 or arguments.wait_timeout_seconds > 300:
        raise CliArgumentError("--wait-timeout-seconds 必须在 5 到 300 之间")
    if arguments.output_dir and not Path(arguments.output_dir).is_absolute():
        raise CliArgumentError("--output-dir 必须是绝对路径")
    _validate_generation_combination(
        arguments.model,
        arguments.backend,
        arguments.aspect_ratio,
        arguments.image_size,
        arguments.quality,
        arguments.background,
        arguments.mask,
        arguments.reference_audio,
        arguments.resolution,
        arguments.duration,
        arguments.seed,
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
    if arguments.output_dir and not Path(arguments.output_dir).is_absolute():
        raise CliArgumentError("--output-dir 必须是绝对路径")
    arguments.id = task_id


def _validate_generation_combination(
    model: str,
    backend: str,
    aspect_ratio: str | None,
    image_size: str | None,
    quality: str | None,
    background: str | None,
    mask: str | None,
    reference_audio: Sequence[str],
    resolution: str | None,
    duration: int | None,
    seed: int | None,
    request_id: str,
) -> None:
    """依据最新接口文档拒绝不会可靠处理的模型与参数组合。"""
    is_video = model in VIDEO_MODELS
    is_gpt_image = model.startswith("gpt-image-2")
    if is_video:
        invalid = []
        if backend != "native":
            invalid.append("视频仅支持 native 后端")
        if aspect_ratio is not None and aspect_ratio not in VIDEO_ASPECT_RATIOS:
            invalid.append("视频比例必须是 portrait、landscape 或 square")
        if image_size or quality or background or mask:
            invalid.append("视频不支持 image-size、quality、background 或 mask")
        if len(reference_audio) > 3:
            invalid.append("视频最多支持 3 个参考音频")
        if duration is not None and not 1 <= duration <= 15:
            invalid.append("视频时长必须在 1 到 15 秒之间")
        if resolution == "1080p" and duration is not None and duration > 10:
            invalid.append("1080p 视频时长最多 10 秒")
        if invalid:
            raise GrsaiError(
                "；".join(invalid),
                code="INVALID_PARAMETER_COMBINATION",
                phase="input",
                request_id=request_id,
            )
        return
    if reference_audio or resolution or duration is not None or seed is not None:
        raise GrsaiError(
            "视频参数只适用于 minimax-h3",
            code="INVALID_PARAMETER_COMBINATION",
            phase="input",
            request_id=request_id,
        )
    is_pixel_size = aspect_ratio in GPT_IMAGE_PIXEL_SIZES
    is_openai_pixel_size = is_pixel_size or aspect_ratio in GPT_PREMIUM_PIXEL_SIZES
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
        and not is_openai_pixel_size
    ):
        message = "openai-compatible 仅接受 auto 或标准像素尺寸"
    elif aspect_ratio and is_gpt_image:
        message = _validate_gpt_aspect_ratio(model, aspect_ratio)
    elif aspect_ratio and not is_gpt_image and aspect_ratio not in ASPECT_RATIOS:
        message = "nano-banana 仅接受文档列出的比例"
    if quality and quality not in QUALITY_BY_MODEL.get(model, ()):
        message = f"{model} 不支持 quality={quality}"
    if background and model not in GPT_PREMIUM_MODELS:
        message = "只有 gpt-image-2-vip、gpt-image-2.5-flare 和 gpt-image-2.5-sunburst 支持透明背景"
    if mask:
        if not GPT_MASK_PATTERN.match(mask):
            message = "--mask 必须是 HTTPS 图片地址"
        elif not is_gpt_image:
            message = "--mask 仅适用于 gpt-image-2 系列"
        elif backend == "openai-compatible":
            message = "openai-compatible 图片生成接口不支持 --mask，请使用原生接口"
    if message:
        raise GrsaiError(
            message,
            code="INVALID_PARAMETER_COMBINATION",
            phase="input",
            request_id=request_id,
        )


def _validate_gpt_aspect_ratio(model: str, value: str) -> str | None:
    """校验 GPT 图片模型的比例、标准像素值和 VIP 自定义像素值。"""
    if value == "auto":
        return None
    if model in GPT_STANDARD_MODELS:
        if value in GPT_STANDARD_ASPECT_RATIOS or value in GPT_IMAGE_PIXEL_SIZES:
            return None
        return f"{model} 仅接受文档列出的比例或 1K 像素值"
    if value in GPT_PREMIUM_PIXEL_SIZES:
        return None
    if model != "gpt-image-2-vip":
        return f"{model} 仅接受文档列出的像素尺寸，不支持比例"
    match = re.fullmatch(r"(\d+)x(\d+)", value)
    if not match:
        return "gpt-image-2-vip 自定义尺寸必须写成宽x高"
    width, height = (int(part) for part in match.groups())
    long_edge, short_edge = max(width, height), min(width, height)
    if long_edge > 3840 or width % 16 or height % 16:
        return "gpt-image-2-vip 自定义尺寸的边长必须不超过 3840 且为 16 的倍数"
    if long_edge > short_edge * 3:
        return "gpt-image-2-vip 自定义尺寸的长短边比例不能超过 3:1"
    area = width * height
    if area < 655_360 or area > 8_294_400:
        return "gpt-image-2-vip 自定义尺寸的像素数必须在 655360 到 8294400 之间"
    return None


def _run_generate(
    arguments: argparse.Namespace,
    config: GrsaiConfig,
    client: GrsaiClient,
    request_id: str,
    download_function: DownloadFunction,
) -> dict[str, Any]:
    """编排图片或视频输入、异步轮询和可选下载。"""
    phase = "input"
    task_id: str | None = None
    try:
        images = normalize_image_inputs(
            arguments.reference_image,
            config.max_reference_image_bytes,
            config.max_reference_total_bytes,
        )
        is_video = arguments.model in VIDEO_MODELS
        audios = normalize_audio_inputs(
            arguments.reference_audio,
            config.max_reference_image_bytes,
            config.max_reference_total_bytes,
        ) if is_video else []
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
            if arguments.quality:
                payload["quality"] = arguments.quality
            if arguments.background:
                payload["background"] = arguments.background
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
            if is_video:
                # 视频接口使用独立字段，默认值与文档允许范围保持一致。
                payload["aspectRatio"] = arguments.aspect_ratio or "landscape"
                payload["resolution"] = arguments.resolution or "768p"
                payload["duration"] = arguments.duration or 5
                if images:
                    payload["images"] = images
                if audios:
                    payload["audios"] = audios
                if arguments.seed is not None:
                    payload["seed"] = arguments.seed
                result = client.generate(payload, request_id=request_id)
                task_id = result["id"]
                result = {**result, "media_type": "video"}
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
                    result = {**result, "media_type": "video"}
                task_id = result["id"]
                phase = "download"
                return _prepare_output(
                    result,
                    request_id,
                    output_dir=arguments.output_dir,
                    config=config,
                    download_function=download_function,
                    media_type="video",
                )
            if images:
                payload["images"] = images
            if arguments.aspect_ratio:
                payload["aspectRatio"] = arguments.aspect_ratio
            if arguments.image_size:
                payload["imageSize"] = arguments.image_size
            if arguments.quality:
                payload["quality"] = arguments.quality
            if arguments.background:
                payload["background"] = arguments.background
            if arguments.mask:
                payload["mask"] = arguments.mask
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
    config: GrsaiConfig,
    client: GrsaiClient,
    request_id: str,
    download_function: DownloadFunction = download_media,
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
        return _prepare_output(
            result,
            request_id,
            output_dir=arguments.output_dir,
            config=config,
            download_function=download_function,
            media_type=arguments.media_type,
        )
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
    download_function: DownloadFunction = download_media,
    media_type: str | None = None,
) -> dict[str, Any]:
    """把任务结果转换为稳定 JSON，并按需下载成功媒体。"""
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
    resolved_media_type = media_type or str(result.get("media_type", "image"))
    output["media_type"] = resolved_media_type
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
