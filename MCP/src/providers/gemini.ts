import { readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import type { Adapter, ProviderConfig } from "./types.js";

/** Google's Gemini image models over the public API. The key is read from the environment, never from a file here. */
const MIME: Record<string, string> = { ".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".webp": "image/webp", ".heic": "image/heic" };

function key(config: ProviderConfig): string {
  const name = config.apiKeyEnv ?? "GEMINI_API_KEY";
  const value = process.env[name];
  if (!value) throw new Error(`${name} is not set; add it to the environment the MCP server starts with`);
  return value;
}

async function request(config: ProviderConfig, parts: unknown[], output: string): Promise<void> {
  const model = config.model ?? "gemini-2.5-flash-image";
  const response = await fetch(`https://generativelanguage.googleapis.com/v1beta/models/${encodeURIComponent(model)}:generateContent`, {
    method: "POST",
    headers: { "Content-Type": "application/json", "x-goog-api-key": key(config) },
    body: JSON.stringify({ contents: [{ parts }], generationConfig: { responseModalities: ["IMAGE"] } }),
  });
  const body = await response.json() as { error?: { message?: string }; candidates?: { content?: { parts?: { inlineData?: { data?: string } }[] } }[] };
  if (!response.ok) throw new Error(`Gemini (${model}) refused the request: ${body.error?.message ?? response.statusText}`);
  const data = body.candidates?.[0]?.content?.parts?.find((part) => part.inlineData?.data)?.inlineData?.data;
  if (!data) throw new Error(`Gemini (${model}) returned no image; it may have declined the prompt`);
  await writeFile(output, Buffer.from(data, "base64"));
}

export const gemini: Adapter = {
  async unavailable(config) {
    const name = config.apiKeyEnv ?? "GEMINI_API_KEY";
    return process.env[name] ? null : `${name} is not set`;
  },
  async generate(config, generate) {
    // The model chooses its own pixel size; the shape is asked for in words and the caller fits the result.
    await request(config, [{ text: `${generate.prompt}\n\nImage shape: ${generate.width} by ${generate.height} pixels.` }], generate.output);
  },
  async edit(config, edit) {
    const mimeType = MIME[path.extname(edit.image).toLowerCase()] ?? "image/png";
    await request(config, [{ text: edit.instruction }, { inlineData: { mimeType, data: (await readFile(edit.image)).toString("base64") } }], edit.output);
  },
};
