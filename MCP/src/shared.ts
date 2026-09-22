import { z } from "zod";
import type { CallToolResult } from "@modelcontextprotocol/sdk/types.js";

export const BLEND_MODES = [
  "Normal", "Multiply", "Screen", "Overlay", "Darken", "Lighten", "Difference", "Color Dodge", "Color Burn",
  "Hue", "Saturation", "Color", "Luminosity", "Soft Light", "Hard Light", "Exclusion", "Linear Dodge (Add)", "Linear Burn",
  "Vivid Light", "Linear Light", "Pin Light", "Hard Mix", "Divide", "Subtract",
] as const;

export const project = z
  .string()
  .min(1)
  .describe("Path to the .comp project, e.g. ~/Desktop/wall.comp. Absolute or starting with ~.");

export const layer = z
  .string()
  .min(1)
  .describe("The layer's id (from compositor_get_info) or its exact name. A name shared by several layers is refused; use the id then.");

/** Where a layer sits. Everything is optional; only what is given changes. */
export const placement = {
  x: z.number().optional().describe("Left edge in document pixels (0 is the canvas's left edge; y grows downward)."),
  y: z.number().optional().describe("Top edge in document pixels."),
  width: z.number().positive().optional().describe("Drawn width in document pixels. Prefer scale to keep proportions."),
  height: z.number().positive().optional().describe("Drawn height in document pixels."),
  scale: z.number().positive().optional().describe("Size as a percentage of the layer's own pixels, keeping its center; 100 is 1:1."),
  rotation: z.number().optional().describe("Degrees clockwise around the layer's center."),
  flip_x: z.boolean().optional().describe("Mirror left to right."),
  flip_y: z.boolean().optional().describe("Mirror top to bottom."),
  sampling: z.enum(["nearest", "smooth", "high"]).optional().describe("Resampling when scaled: nearest keeps pixel art crisp; high is the default."),
};

export const appearance = {
  opacity: z.number().min(0).max(100).optional().describe("0–100."),
  blend: z.enum(BLEND_MODES).optional().describe("Blend mode."),
};

export function placementOptions(input: Record<string, unknown>) {
  return {
    x: input.x, y: input.y, width: input.width, height: input.height, scale: input.scale, rotation: input.rotation,
    "flip-x": input.flip_x, "flip-y": input.flip_y, sampling: input.sampling, opacity: input.opacity, blend: input.blend,
  } as Record<string, string | number | boolean | undefined>;
}

export function ok(value: Record<string, unknown>, note?: string): CallToolResult {
  const text = JSON.stringify(value, null, 2);
  return { content: [{ type: "text", text: note ? `${note}\n${text}` : text }], structuredContent: value };
}

export function failed(error: unknown): CallToolResult {
  const message = error instanceof Error ? error.message : String(error);
  return { isError: true, content: [{ type: "text", text: `Error: ${message}` }] };
}

export const READ_ONLY = { readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false };
export const EDITS = { readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false };
export const DESTROYS = { readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: false };
