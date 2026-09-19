import { z } from "zod";
import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { options, resolvePath, run } from "../cli.js";
import { DESTROYS, EDITS, failed, layer, ok, project } from "../shared.js";

const FILTERS = ["Gaussian Blur", "Motion Blur", "Add Noise", "Lens Correction", "Offset", "Make Tileable",
  "Even Lighting", "High Pass", "Unsharp Mask", "Height to Normal Map", "Clouds", "Curves", "Exposure", "Gradient Map", "Grain"] as const;
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
        "message when the image has no distinct subject. The default 'clean' edge gives a crisp outline sized to the " +
        "image; 'soft' is the detector's raw mask, which is hazy on large images. Afterwards, check the edge at full " +
        "resolution with compositor_render_view and a region around the subject's outline, not only the whole canvas: " +
        "look for a hazy fringe (lower shift, e.g. -2, or raise contrast), a hard scissor-cut look (raise refine, " +
        "lower contrast), and background left in enclosed gaps such as between an arm and the body, which the " +
        "detector can miss and which needs saying to the user.",
      inputSchema: {
        project, layer,
        edge: z.enum(["clean", "soft"]).default("clean").describe("clean: crisp outline scaled to the image size. soft: the detector's raw mask."),
        refine: z.number().min(0).optional().describe("Override: how far, in layer pixels, the mask is pulled onto the image's own edges."),
        contrast: z.number().min(0).max(100).optional().describe("Override: pushes mask grays toward black and white, clearing haze."),
        shift: z.number().optional().describe("Override: moves the mask edge in layer pixels; negative contracts, dropping a rim of background."),
      },
      annotations: EDITS,
    },
    async ({ project, layer, edge, refine, contrast, shift }) => {
      try {
        return ok(await run("remove-background", [resolvePath(project), layer, ...options({ edge, refine, contrast, shift })]));
      } catch (error) { return failed(error); }
    },
  );

  server.registerTool(
    "compositor_cutout",
    {
      title: "Cut a subject out of a photo in one step",
      description:
        "The quick path for 'remove the background from this image': takes an image file and writes its subject on " +
        "transparency as a PNG, cropped to the subject. The source file is not changed. Give project as well to keep " +
        "the layered project, where the background is still there behind an editable mask; do that whenever the user " +
        "may want to touch up the result. For several images, call this once per image. Afterwards, open the PNG's " +
        "project with compositor_render_view, or tell the user plainly, if the detector is likely to have missed " +
        "enclosed gaps (between an arm and the body, through a handle): it often does. Fails with a clear message " +
        "when the image has no distinct subject.",
      inputSchema: {
        image: z.string().min(1).describe("Image file to cut out: JPEG, PNG, HEIC or TIFF."),
        output: z.string().min(1).describe("PNG file to write, e.g. ~/Desktop/portrait (cutout).png. Overwrites an existing file."),
        padding: z.number().min(0).optional().describe("Transparent margin to leave around the subject, in pixels (default 0)."),
        edge: z.enum(["clean", "soft"]).default("clean").describe("clean: crisp outline scaled to the image size. soft: the detector's raw mask."),
        project: z.string().min(1).optional().describe("Also save the layered .comp project here."),
        overwrite: z.boolean().optional().describe("Replace an existing project at that path."),
      },
      annotations: { ...EDITS, idempotentHint: true },
    },
    async ({ image, output, padding, edge, project, overwrite }) => {
      try {
        return ok(await run("cutout", [resolvePath(image), ...options({
          out: resolvePath(output), padding, edge, project: project ? resolvePath(project) : undefined, overwrite,
        }, ["overwrite"])]));
      } catch (error) { return failed(error); }
    },
  );

  server.registerTool(
    "compositor_make_tileable",
    {
      title: "Make a texture layer tile without seams",
      description:
        "The app's Filter > Make Tileable. Rewrites one layer so it repeats cleanly: evens out broad lighting differences (a texture brighter on one " +
        "side can never tile), slides the pixels half way round so the seams meet in the middle, rebuilds a " +
        "cross-shaped band over them from the surrounding texture, and slides them back. Works best on fairly " +
        "uniform surfaces (stone, soil, bark, fabric, plaster); distinct objects crossing the seam band will be " +
        "smeared. Always judge the result with compositor_tile_preview, looking for strips along the tile joins " +
        "(try a wider or narrower band) and for features that repeat too obviously. The layer should fill the " +
        "canvas and be unrotated. There is no undo from here, so work on a copy of a texture you cannot regenerate.",
      inputSchema: {
        project, layer,
        band: z.number().min(2).max(40).optional().describe("Width of the rebuilt band, as a percentage of the layer's shorter side (default 12)."),
        lighting: z.number().min(0).max(100).optional().describe("How much broad light and shade is flattened first (default 100). Lower it, or use 0, for a texture whose large light and dark areas are part of its look."),
      },
      annotations: DESTROYS,
    },
    async ({ project, layer, band, lighting }) => {
      try {
        return ok(await run("make-tileable", [resolvePath(project), layer, ...options({ band, lighting })]));
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
        "Rewrites one layer's pixels with one of the app's filters (the same ones as its Filter menu); there is no " +
        "undo from here, so for color changes prefer compositor_add_adjustment. " +
        "High Pass: radius. Unsharp Mask: amount (1–500 %), radius, threshold. Even Lighting: strength (0–100). " +
        "Height to Normal Map: strength (0.1–50), y_down (true for Unreal/DirectX; leave false for Godot, Unity, " +
        "Blender), no_wrap (true unless the texture tiles). Clouds: cells (1–64), tiling gray noise that replaces " +
        "the layer's pixels. Make Tileable: use compositor_make_tileable. " +
        "Settings by filter — Gaussian Blur: radius (0.1–250 px). Motion Blur: angle (−90–90°), distance (px). " +
        "Add Noise: amount (0.1–400 %), gaussian, monochromatic. Lens Correction: distortion (−100–100). " +
        "Offset: horizontal, vertical (percent of the layer's size; pixels leaving one edge return at the other, " +
        "copied exactly, so the opposite values undo it). Offset 50/50 brings a texture's seams to the middle for " +
        "retouching; check tiling with compositor_tile_preview. Exposure: exposure, offset, gamma. " +
        "Blurs spread past the layer's edges by default: the layer grows and its original border becomes about half " +
        "transparent. For a texture or a background that must keep covering the canvas, pass keep_edges true: the " +
        "inside is blurred and the outline stays solid.",
      inputSchema: {
        project, layer,
        filter: z.enum(FILTERS),
        radius: z.number().min(0.1).max(250).optional(), angle: z.number().min(-90).max(90).optional(),
        distance: z.number().min(1).max(2000).optional(), amount: z.number().min(0.1).max(500).optional().describe("Add Noise 0.1–400 %, Unsharp Mask 1–500 %."),
        gaussian: z.boolean().optional(), monochromatic: z.boolean().optional(),
        distortion: z.number().min(-100).max(100).optional(),
        keep_edges: z.boolean().optional().describe("Blurs: keep the layer's outline solid instead of fading it."),
        threshold: z.number().min(0).max(255).optional().describe("Unsharp Mask: smaller differences are left alone."),
        strength: z.number().min(0).max(100).optional().describe("Even Lighting 0–100, or Height to Normal Map 0.1–50."),
        y_down: z.boolean().optional().describe("Height to Normal Map: green points down (Unreal, DirectX)."),
        no_wrap: z.boolean().optional().describe("Height to Normal Map: do not read slopes across the edges."),
        cells: z.number().min(1).max(64).optional().describe("Clouds: large features across the layer."),
        horizontal: z.number().min(-100).max(100).optional().describe("Offset: slide right, percent of the layer's width (default 50)."),
        vertical: z.number().min(-100).max(100).optional().describe("Offset: slide down, percent of the layer's height (default 50)."),
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
          horizontal: input.horizontal, vertical: input.vertical, "keep-edges": input.keep_edges,
          threshold: input.threshold, strength: input.strength, "y-down": input.y_down, "no-wrap": input.no_wrap, cells: input.cells,
          exposure: input.exposure, offset: input.offset, gamma: input.gamma,
        }, ["gaussian", "monochromatic", "keep-edges", "y-down", "no-wrap"])]));
      } catch (error) { return failed(error); }
    },
  );
}
