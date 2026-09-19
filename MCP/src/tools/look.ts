import { readFile, rm, mkdtemp } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { z } from "zod";
import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { options, resolvePath, run } from "../cli.js";
import { READ_ONLY, EDITS, failed, ok, project } from "../shared.js";

/** Tools that read a project without changing it, plus export, which writes only the file it is asked for. */
export function registerLookTools(server: McpServer) {
  server.registerTool(
    "compositor_get_info",
    {
      title: "List a project's layers",
      description:
        "Canvas size and every layer, top first as the Layers panel shows them: id, name, kind (pixels, blank, folder, " +
        "adjustment), visibility, opacity, blend mode, position and size, parent folder, mask, and clipping base. " +
        "Call this first on any project, and again after edits when you need fresh ids.",
      inputSchema: { project },
      annotations: READ_ONLY,
    },
    async ({ project }) => {
      try { return ok(await run("info", [resolvePath(project)])); } catch (error) { return failed(error); }
    },
  );

  server.registerTool(
    "compositor_render_view",
    {
      title: "Look at the canvas",
      description:
        "Renders the finished picture exactly as Compositor would export it and returns it as an image, so you can " +
        "see the result of your edits. Use region to look closely at part of the canvas (full resolution of that " +
        "part), and max_size to keep the image small. Transparent areas stay transparent. Look after every change " +
        "that matters rather than assuming it worked.",
      inputSchema: {
        project,
        region: z.object({ x: z.number(), y: z.number(), width: z.number().positive(), height: z.number().positive() })
          .optional().describe("Part of the canvas to render, in document pixels."),
        max_size: z.number().int().min(16).max(4096).default(1024)
          .describe("Longest side of the returned image in pixels; larger renders are scaled down to this."),
      },
      annotations: READ_ONLY,
    },
    async ({ project, region, max_size }) => {
      const folder = await mkdtemp(path.join(tmpdir(), "compositor-view-"));
      try {
        const file = path.join(folder, "view.png");
        const result = await run("render", [resolvePath(project), ...options({
          out: file, "max-size": max_size,
          region: region ? `${region.x},${region.y},${region.width},${region.height}` : undefined,
        })]);
        const data = (await readFile(file)).toString("base64");
        return {
          content: [
            { type: "image", data, mimeType: "image/png" },
            { type: "text", text: `Rendered ${result.width} × ${result.height} px${region ? " (region)" : ""}.` },
          ],
        };
      } catch (error) {
        return failed(error);
      } finally {
        await rm(folder, { recursive: true, force: true });
      }
    },
  );

  server.registerTool(
    "compositor_tile_preview",
    {
      title: "Look at the canvas repeated as tiles",
      description:
        "Renders the finished picture repeated in a grid and returns it as an image, which is how a tiling texture " +
        "is judged. Look for seams where tiles meet (edges that do not match) and for features that repeat too " +
        "obviously (one bright stone showing up nine times). Use it after making a texture tileable and before " +
        "exporting it. The project is not changed.",
      inputSchema: {
        project,
        repeat: z.number().int().min(2).max(8).default(3).describe("Tiles each way."),
        max_size: z.number().int().min(64).max(4096).default(1536).describe("Longest side of the whole sheet in pixels."),
      },
      annotations: READ_ONLY,
    },
    async ({ project, repeat, max_size }) => {
      const folder = await mkdtemp(path.join(tmpdir(), "compositor-tiles-"));
      try {
        const file = path.join(folder, "tiles.png");
        const result = await run("tile-preview", [resolvePath(project), ...options({ out: file, repeat, "max-size": max_size })]);
        const data = (await readFile(file)).toString("base64");
        const tile = result.tile as { width: number; height: number };
        return {
          content: [
            { type: "image", data, mimeType: "image/png" },
            { type: "text", text: `${repeat} × ${repeat} tiles, each shown at ${tile.width} × ${tile.height} px.` },
          ],
        };
      } catch (error) {
        return failed(error);
      } finally {
        await rm(folder, { recursive: true, force: true });
      }
    },
  );

  server.registerTool(
    "compositor_sample_color",
    {
      title: "Read a color from the canvas",
      description:
        "The finished picture's color at one document pixel, as the eyedropper reads it: red, green, blue and alpha, " +
        "each 0–255 (not premultiplied). Use it to check exact values, e.g. that a mask hides a point (alpha 0).",
      inputSchema: { project, x: z.number().int().min(0), y: z.number().int().min(0) },
      annotations: READ_ONLY,
    },
    async ({ project, x, y }) => {
      try { return ok(await run("sample", [resolvePath(project), "--at", `${x},${y}`])); } catch (error) { return failed(error); }
    },
  );

  server.registerTool(
    "compositor_export",
    {
      title: "Export the finished image",
      description:
        "Writes the flattened picture at full size. The file extension chooses the format: .png, .tiff and .tga keep " +
        "transparency; .jpg is flattened onto the matte color (white by default). For a cut-out going into a game " +
        "engine (foliage, decals, sprites), pass bleed (16 is a good value) with .png or .tga: color is spread under " +
        "the transparent pixels around it so texture filtering leaves no dark halo. The project is not changed.",
      inputSchema: {
        project,
        output: z.string().min(1).describe("File to write, ending in .png, .jpg, .tiff or .tga, e.g. ~/game/assets/wall_albedo.png. Overwrites an existing file."),
        quality: z.number().min(0).max(100).optional().describe("JPEG quality, 0–100 (default 90)."),
        bleed: z.number().int().min(0).max(256).optional().describe("PNG and TGA: pixels of color to spread under the transparency around the contents."),
        matte: z.object({ red: z.number().int().min(0).max(255), green: z.number().int().min(0).max(255), blue: z.number().int().min(0).max(255) })
          .optional().describe("JPEG background color behind transparent areas."),
      },
      annotations: { ...EDITS, idempotentHint: true },
    },
    async ({ project, output, quality, matte, bleed }) => {
      try {
        return ok(await run("export", [resolvePath(project), ...options({
          out: resolvePath(output), quality, bleed, matte: matte ? `${matte.red},${matte.green},${matte.blue}` : undefined,
        })]));
      } catch (error) { return failed(error); }
    },
  );

  server.registerTool(
    "compositor_subject_mask",
    {
      title: "Save a layer's subject as a mask image",
      description:
        "Finds the foreground subject of a layer (on-device, Apple Vision) and writes it as a grayscale PNG, white " +
        "over the subject, without changing the project. Use compositor_remove_background instead to mask the layer " +
        "itself; use this when the mask is needed elsewhere, e.g. on another layer via compositor_set_mask.",
      inputSchema: {
        project,
        layer: z.string().min(1).describe("Layer id or exact name; it must have pixels."),
        output: z.string().min(1).describe("PNG file to write."),
        edge: z.enum(["clean", "soft"]).default("clean").describe("clean: crisp outline scaled to the image size. soft: the detector's raw mask."),
      },
      annotations: { ...EDITS, idempotentHint: true },
    },
    async ({ project, layer, output, edge }) => {
      try {
        return ok(await run("subject-mask", [resolvePath(project), layer, ...options({ out: resolvePath(output), edge })]));
      } catch (error) { return failed(error); }
    },
  );
}
