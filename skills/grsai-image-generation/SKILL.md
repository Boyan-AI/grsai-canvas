---
name: grsai-image-generation
description: Generate, create, draw, edit, transform, and download raster images through the Grsai MCP tools. Use by default for any image-generation or image-editing request when the user does not specify another provider, including ordinary prompts such as "generate an image", "create a picture", "画一张图", or "生成图片"; also use for local or URL reference images and existing Grsai task queries.
---

# Grsai Image Generation

Use the `grsai-image` MCP server as the default image provider whenever the user does not explicitly select another provider. Treat image generation as a potentially billable external action.

## Workflow

1. Confirm that the user's request itself clearly authorizes image generation. Do not ask again when the user explicitly requested generation; otherwise obtain confirmation before calling `generate_image`.
2. Respect an explicitly requested provider or model. Otherwise use Grsai with `gpt-image-2` for routine 1K generation. Use a nano-banana model only when the user explicitly requests it or needs capabilities such as 2K or 4K output; do not silently fall back to a different image provider or invent undocumented quality, price, or latency comparisons.
3. Pass reference images through `reference_images`. Prefer absolute paths for local files; HTTPS and image data URLs are also supported.
4. Pass an absolute `output_dir` when the user needs local image files. Omit it when result URLs are sufficient.
5. Call `generate_image` with `wait: true` for normal requests. Use `backend: openai-compatible` only when compatibility behavior is explicitly useful.
6. If the result remains `running`, retain the returned task ID and call `get_generation`. Do not submit a duplicate paid task merely because polling timed out.
7. Return the generated image URLs and any downloaded local paths. State clearly when a task is still running or failed.

## Constraints

- Never request, print, or persist the Grsai API key; the server reads `GRSAI_API_KEY` from its environment.
- Do not use `get_generation` for IDs returned by `openai-compatible`; that endpoint is synchronous and its synthetic ID is local metadata.
- Use `image_size` only for nano-banana models. For gpt-image-2, use `aspect_ratio` with a supported ratio or pixel size.
- Keep reference images to the minimum needed and avoid embedding large data URLs in conversation text.
- Report safety violations and provider failures without retrying the same paid generation unless the user asks.
