import { z } from "zod";

export const IMAGE_MODELS = [
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
] as const;

export const ASPECT_RATIOS = [
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
] as const;

export const IMAGE_SIZES = ["1K", "2K", "4K"] as const;

export const GPT_IMAGE_PIXEL_SIZES = [
  "1024x1024",
  "1536x1024",
  "1024x1536",
] as const;

export const GenerationStatusSchema = z.enum([
  "running",
  "violation",
  "succeeded",
  "failed",
]);

export const GenerationResultSchema = z.object({
  url: z.string().url(),
});

export const GenerationResponseSchema = z.object({
  id: z.string().min(1),
  status: GenerationStatusSchema,
  results: z.array(GenerationResultSchema).optional(),
  progress: z.number().int().min(0).max(100).optional(),
  error: z.string().optional(),
});

export const OpenAiGenerationResponseSchema = z.object({
  created: z.number().int(),
  data: z.array(GenerationResultSchema),
  usage: z
    .object({
      total_tokens: z.number().int().optional(),
      input_tokens: z.number().int().optional(),
      output_tokens: z.number().int().optional(),
    })
    .passthrough()
    .optional(),
});

export type ImageModel = (typeof IMAGE_MODELS)[number];
export type AspectRatio = (typeof ASPECT_RATIOS)[number];
export type ImageSize = (typeof IMAGE_SIZES)[number];
export type GptImagePixelSize = (typeof GPT_IMAGE_PIXEL_SIZES)[number];
export type GenerationResponse = z.infer<typeof GenerationResponseSchema>;
export type OpenAiGenerationResponse = z.infer<
  typeof OpenAiGenerationResponseSchema
>;

/** Grsai 原生生图接口的稳定输入。 */
export interface GenerateImageRequest {
  model: ImageModel;
  prompt: string;
  images?: string[];
  aspectRatio?: AspectRatio | GptImagePixelSize;
  imageSize?: ImageSize;
  replyType?: "json" | "async";
}

/** OpenAI 兼容生图接口的稳定输入。 */
export interface OpenAiGenerateImageRequest {
  model: ImageModel;
  prompt: string;
  image?: string[];
  size?: AspectRatio | GptImagePixelSize;
  response_format?: "url";
}
