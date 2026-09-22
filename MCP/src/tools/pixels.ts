import { z } from "zod";
import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { options, resolvePath, run } from "../cli.js";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { grayPNG } from "../png.js";
import { edit } from "../providers/index.js";
import { DESTROYS, EDITS, failed, layer, ok, project } from "../shared.js";

const FILTERS = ["Gaussian Blur", "Motion Blur", "Add Noise", "Lens Correction", "Offset", "Make Tileable",
  "Even Lighting", "High Pass", "Unsharp Mask", "Height to Normal Map", "Clouds", "Black & White", "Threshold", "Posterize",
  "Vibrance", "Color Balance", "Photo Filter", "Curves", "Exposure", "Gradient Map", "Grain"] as const;
const ADJUSTMENTS = ["Hue/Saturation", "Levels", "Curves", "Exposure", "Gradient Map", "Grain", "Black & White", "Threshold",
  "Posterize", "Vibrance", "Color Balance", "Photo Filter"] as const;
const rgb = (what: string, low: number, high: number) => z.object({ red: z.number().min(low).max(high), green: z.number().min(low).max(high), blue: z.number().min(low).max(high) }).optional().describe(what);
const colorInputs = {
  reds: z.number().min(-200).max(300).optional().describe("Black & White: how much red contributes to the gray, percent (default 30)."),
  greens: z.number().min(-200).max(300).optional().describe("Black & White: green's share (default 59)."),
  blues: z.number().min(-200).max(300).optional().describe("Black & White: blue's share (default 11)."),
  level: z.number().min(1).max(255).optional().describe("Threshold: brightness at and above which a pixel turns white."),
  levels: z.number().int().min(2).max(255).optional().describe("Posterize: levels per channel."),
  vibrance: z.number().min(-100).max(100).optional().describe("Vibrance: lifts muted colors more than vivid ones."),
  density: z.number().min(0).max(100).optional().describe("Photo Filter: strength of the tint (default 25)."),
  filter_color: rgb("Photo Filter: the filter's color, 0–255 per channel (default a warming orange).", 0, 255),
  shadows: rgb("Color Balance, shadows: red is cyan–red, green is magenta–green, blue is yellow–blue, each −100–100.", -100, 100),
  midtones: rgb("Color Balance, midtones.", -100, 100),
  highlights: rgb("Color Balance, highlights.", -100, 100),
};
function colorOptions(input: Record<string, any>) {
  const triple = (value?: { red: number; green: number; blue: number }) => (value ? `${value.red},${value.green},${value.blue}` : undefined);
  return { reds: input.reds, greens: input.greens, blues: input.blues, level: input.level, levels: input.levels, vibrance: input.vibrance,
    density: input.density, "filter-color": triple(input.filter_color), shadows: triple(input.shadows), midtones: triple(input.midtones), highlights: triple(input.highlights) };
}

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
        "Makes one layer repeat cleanly. Both methods first slide the pixels half way round so the seams meet in the " +
        "middle, repair a cross-shaped band over them, and slide the pixels back; they differ in how the band is " +
        "repaired. method 'patch' is the app's Filter > Make Tileable: it also evens broad lighting, and rebuilds the " +
        "band from small patches of the surrounding texture. It is instant and right for fine-grained surfaces (soil, " +
        "sand, plaster, concrete, fabric, noise) but smears anything made of distinct shapes. method 'model' asks an " +
        "image model (an 'edit' provider) to redraw the band, keeping only that band from its answer, so everything " +
        "else stays pixel-identical: right for bricks, cobbles, planks, tiles, leaves, and takes as long as one edit " +
        "(under a minute locally). Models tend to settle the seam with one long straight gap between shapes, which passes " +
        "on gridded surfaces and can show on irregular ones; try another seed if it does. It leaves the original layer " +
        "hidden beneath a new '(tileable)' layer. Always judge " +
        "the result with compositor_tile_preview. The layer should fill the canvas and be unrotated. The model method " +
        "has no screen in the app yet.",
      inputSchema: {
        project, layer,
        method: z.enum(["patch", "model"]).describe("patch: fine-grained surfaces. model: surfaces made of distinct shapes."),
        band: z.number().min(2).max(40).optional().describe("Width of the repaired band, as a percentage of the shorter side (default 12; the model method defaults to 16)."),
        lighting: z.number().min(0).max(100).optional().describe("patch only: how much broad light and shade is flattened first (default 100). Use 0 to keep it."),
        provider: z.string().min(1).optional().describe("model only: an 'edit' provider from compositor_list_providers; omit to use the user's current one."),
        seed: z.number().int().min(0).optional(),
      },
      annotations: DESTROYS,
    },
    async ({ project, layer, method, band, lighting, provider, seed }) => {
      try {
        const target = resolvePath(project);
        if (method === "patch") return ok(await run("make-tileable", [target, layer, ...options({ band, lighting })]));
        return await healSeamsWithModel(target, layer, band ?? 16, provider, seed);
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
        "colorize. Exposure: exposure (stops), offset, gamma. Black & White: reds, greens, blues. Threshold: level. " +
        "Posterize: levels. Vibrance: vibrance, saturation. Color Balance: shadows, midtones, highlights. Photo Filter: " +
        "filter_color, density. Curves, Gradient Map and Grain are added at their defaults for editing in the app.",
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
        ...colorInputs,
      },
      annotations: EDITS,
    },
    async (input) => {
      try {
        return ok(await run("add-adjustment", [resolvePath(input.project), input.kind, ...options({
          ...colorOptions(input),
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

/**
 * Seams healed by an image model. The model sees the whole texture with its seams in the middle and redraws it; only a
 * soft-edged cross over the seams is kept from its answer, so the rest of the texture is untouched.
 */
async function healSeamsWithModel(target: string, layerName: string, band: number, provider?: string, seed?: number) {
  const folder = await mkdtemp(path.join(tmpdir(), "compositor-tileable-"));
  try {
    const info = await run("info", [target]) as { width: number; height: number; layers: { id: string; name: string; width: number; height: number; x: number; y: number }[] };
    const source = info.layers.find((entry) => entry.id === layerName || entry.name === layerName);
    if (!source) throw new Error(`no layer has the id or name '${layerName}'`);
    if (source.width !== info.width || source.height !== info.height || source.x !== 0 || source.y !== 0) {
      throw new Error("the layer must fill the canvas exactly; crop or resize the project to the texture first");
    }
    const { width, height } = info;
    await run("filter", [target, source.id, "Offset", "--horizontal", "50", "--vertical", "50"]);
    const seams = path.join(folder, "seams.png"), healed = path.join(folder, "healed.png"), mask = path.join(folder, "mask.png"), flat = path.join(folder, "flat.png");
    await run("export", [target, "--out", seams]);
    const result = await edit({
      image: seams, seed, output: healed,
      instruction: "Repair this texture. A seam runs vertically down the exact center and another horizontally across the exact middle, " +
        "where shapes are cut off and do not line up. Redraw the surface along those two lines so every shape is whole and continues " +
        "naturally across them. Keep the same material, colors, scale and lighting, and keep everything away from those lines exactly as it is.",
    }, provider);
    const added = await run("add-layer", [target, healed, ...options({ name: "Seam repair", x: 0, y: 0, width, height })]);
    const half = Math.max(2, Math.min(width, height) * band / 100 / 2), soft = Math.max(1, half * 0.6);
    await writeFile(mask, grayPNG(width, height, (x, y) => {
      const distance = Math.min(Math.abs(x + 0.5 - width / 2), Math.abs(y + 0.5 - height / 2));
      return 255 * Math.max(0, Math.min(1, (half - distance) / soft));
    }));
    await run("set-mask", [target, String(added.added), mask]);
    // Flattened so the repaired texture can be slid back as one piece; the original stays beneath, hidden.
    await run("export", [target, "--out", flat]);
    await run("delete-layer", [target, String(added.added)]);
    await run("filter", [target, source.id, "Offset", "--horizontal", "-50", "--vertical", "-50"]);
    await run("set-layer", [target, source.id, "--visible", "false"]);
    const tileable = await run("add-layer", [target, flat, ...options({ name: `${source.name} (tileable)`, x: 0, y: 0 })]);
    await run("filter", [target, String(tileable.added), "Offset", "--horizontal", "-50", "--vertical", "-50"]);
    return ok({ tileable: tileable.added, original: source.id, method: "model", provider: result.provider, model: result.model, seconds: result.seconds, band },
      "Judge it with compositor_tile_preview. The original layer is hidden beneath; show it and delete the new one to go back.");
  } finally {
    await rm(folder, { recursive: true, force: true });
  }
}
