import { z } from "zod";
import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { options, resolvePath, run } from "../cli.js";
import { DESTROYS, EDITS, failed, layer, ok, project } from "../shared.js";

const FILTERS = ["Gaussian Blur", "Motion Blur", "Add Noise", "Lens Correction", "Curves", "Exposure", "Gradient Map", "Grain"] as const;
const ADJUSTMENTS = ["Hue/Saturation", "Levels", "Curves", "Exposure", "Gradient Map", "Grain"] as const;

/** Tools that mask, adjust or filter. Masks and adjustment layers are non-destructive; filters rewrite pixels. */
export function registerPixelTools(server: McpServer) {
  server.registerTool(
    "compositor_set_mask",
    {
      title: "Give a layer a mask",
      description:
        "Sets a layer's mask from a grayscale image (white reveals, black hides, gray is partial; the image is fitted " +
        "to the layer's own pixels), or switches the mask on or off, or removes it. A mask hides without erasing, so " +
        "prefer it to deleting pixels. Works on folders too, masking everything inside.",
      inputSchema: {
        project, layer,
        image: z.string().min(1).optional().describe("Grayscale image file to use as the mask. Replaces any existing mask."),
        enabled: z.boolean().optional().describe("Switch the mask on or off without removing it."),
        remove: z.boolean().optional().describe("Delete the mask."),
      },
      annotations: EDITS,
    },
    async ({ project, layer, image, enabled, remove }) => {
      try {
        if (!image && enabled === undefined && !remove) throw new Error("give image, enabled or remove");
        return ok(await run("set-mask", [resolvePath(project), layer, ...(image ? [resolvePath(image)] : []),
          ...options({ enabled, remove }, ["remove"])]));
      } catch (error) { return failed(error); }
    },
  );

  server.registerTool(
    "compositor_remove_background",
    {
      title: "Mask out a layer's background",
      description:
        "Finds the layer's foreground subject on-device and hides everything else behind a layer mask. No pixels are " +
        "erased: disable or remove the mask with compositor_set_mask to get the background back. Fails with a clear " +
        "message when the image has no distinct subject. Use advanced for hair, fur and fine edges.",
      inputSchema: {
        project, layer,
        advanced: z.boolean().optional().describe("Refine the mask onto the image's own edges (slower, much better on hair and fur)."),
        refine: z.number().min(0).optional().describe("Advanced: how far, in layer pixels, the mask is pulled onto the image's edges (default 12)."),
        contrast: z.number().min(0).max(100).optional().describe("Advanced: pushes mask grays toward black and white, clearing haze (default 25)."),
        shift: z.number().optional().describe("Advanced: moves the mask edge in layer pixels; negative contracts, dropping a rim of background color."),
      },
      annotations: EDITS,
    },
    async ({ project, layer, advanced, refine, contrast, shift }) => {
      try {
        return ok(await run("remove-background", [resolvePath(project), layer, ...options({ advanced, refine, contrast, shift }, ["advanced"])]));
      } catch (error) { return failed(error); }
    },
  );

  server.registerTool(
    "compositor_add_adjustment",
    {
      title: "Add an adjustment layer",
      description:
        "Adds a non-destructive adjustment layer that recolors everything below it in the stack (or below it within " +
        "its folder). It can be hidden, faded, masked, re-blended or deleted later like any layer, and edited by " +
        "double-clicking it in the app. Settings by kind — Levels: black, white (input 0–255), gamma, output_black, " +
        "output_white (swap them to invert). Hue/Saturation: hue (−180–180), saturation, lightness (−100–100), " +
        "colorize. Exposure: exposure (stops), offset, gamma. Curves, Gradient Map and Grain are added at their " +
        "defaults for editing in the app.",
      inputSchema: {
        project,
        kind: z.enum(ADJUSTMENTS),
        above: layer.optional().describe("Layer to add it directly above; defaults to the top of the stack."),
        name: z.string().min(1).optional(),
        black: z.number().min(0).max(254).optional(), white: z.number().min(1).max(255).optional(),
        gamma: z.number().min(0.01).max(9.99).optional(),
        output_black: z.number().min(0).max(255).optional(), output_white: z.number().min(0).max(255).optional(),
        hue: z.number().min(-180).max(180).optional(), saturation: z.number().min(-100).max(100).optional(),
        lightness: z.number().min(-100).max(100).optional(), colorize: z.boolean().optional(),
        exposure: z.number().min(-20).max(20).optional(), offset: z.number().min(-0.5).max(0.5).optional(),
      },
      annotations: EDITS,
    },
    async (input) => {
      try {
        return ok(await run("add-adjustment", [resolvePath(input.project), input.kind, ...options({
          above: input.above, name: input.name, black: input.black, white: input.white, gamma: input.gamma,
          "output-black": input.output_black, "output-white": input.output_white, hue: input.hue,
          saturation: input.saturation, lightness: input.lightness, colorize: input.colorize,
          exposure: input.exposure, offset: input.offset,
        }, ["colorize"])]));
      } catch (error) { return failed(error); }
    },
  );

  server.registerTool(
    "compositor_apply_filter",
    {
      title: "Apply a filter to a layer's pixels",
      description:
        "Rewrites one layer's pixels; there is no undo from here, so for color changes prefer compositor_add_adjustment. " +
        "Settings by filter — Gaussian Blur: radius (0.1–250 px). Motion Blur: angle (−90–90°), distance (px). " +
        "Add Noise: amount (0.1–400 %), gaussian, monochromatic. Lens Correction: distortion (−100–100). " +
        "Exposure: exposure, offset, gamma. Blurs spread past the layer's edges: the layer grows, and its original " +
        "border becomes about half transparent, fading over roughly three times the radius. So a blurred layer that " +
        "filled the canvas no longer covers its borders; scale it up first so the fade falls outside the canvas, and " +
        "confirm with compositor_sample_color on a border pixel (alpha 255) rather than assuming.",
      inputSchema: {
        project, layer,
        filter: z.enum(FILTERS),
        radius: z.number().min(0.1).max(250).optional(), angle: z.number().min(-90).max(90).optional(),
        distance: z.number().min(1).max(2000).optional(), amount: z.number().min(0.1).max(400).optional(),
        gaussian: z.boolean().optional(), monochromatic: z.boolean().optional(),
        distortion: z.number().min(-100).max(100).optional(),
        exposure: z.number().min(-20).max(20).optional(), offset: z.number().min(-0.5).max(0.5).optional(),
        gamma: z.number().min(0.01).max(9.99).optional(),
      },
      annotations: DESTROYS,
    },
    async (input) => {
      try {
        return ok(await run("filter", [resolvePath(input.project), input.layer, input.filter, ...options({
          radius: input.radius, angle: input.angle, distance: input.distance, amount: input.amount,
          gaussian: input.gaussian, monochromatic: input.monochromatic, distortion: input.distortion,
          exposure: input.exposure, offset: input.offset, gamma: input.gamma,
        }, ["gaussian", "monochromatic"])]));
      } catch (error) { return failed(error); }
    },
  );
}
