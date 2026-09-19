import { readFile } from "node:fs/promises";
import { z } from "zod";
import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { resolvePath } from "../cli.js";
import { live } from "../live.js";
import { BLEND_MODES, EDITS, READ_ONLY, failed, ok } from "../shared.js";

const layer = z.string().min(1).optional().describe("Layer id or exact name in the open project; defaults to the active layer.");

/**
 * Tools that act on the project the user has open in the running app, while they watch. Each change is an ordinary
 * undo step in the app (⌘Z). The user must have switched on Compositor > Allow Assistant Control.
 */
export function registerLiveTools(server: McpServer) {
  server.registerTool(
    "compositor_live_status",
    {
      title: "See what the user has open in the app",
      description:
        "The project in the front tab of the running Compositor app: its size, layers (top first, with the active one " +
        "marked), any selection, its file path, and whether it has unsaved changes. Use the compositor_live_ tools to " +
        "work on it while the user watches; use the file tools for projects that are not open. Fails, saying how to " +
        "enable it, when the app is not running or Allow Assistant Control is off.",
      inputSchema: {},
      annotations: READ_ONLY,
    },
    async () => { try { return ok(await live("info")); } catch (error) { return failed(error); } },
  );

  server.registerTool(
    "compositor_live_render",
    {
      title: "Look at the canvas the user has open",
      description: "The open project's finished picture, unsaved changes included, as an image. region looks closely at part of it.",
      inputSchema: {
        region: z.object({ x: z.number(), y: z.number(), width: z.number().positive(), height: z.number().positive() }).optional(),
        max_size: z.number().int().min(16).max(4096).default(1024),
      },
      annotations: READ_ONLY,
    },
    async ({ region, max_size }) => {
      try {
        const view = await live("render", { region, maxSize: max_size });
        return { content: [{ type: "image", data: String(view.png), mimeType: "image/png" }, { type: "text", text: `Rendered ${view.width} × ${view.height} px from the open project.` }] };
      } catch (error) { return failed(error); }
    },
  );

  server.registerTool(
    "compositor_live_add_image_layer",
    {
      title: "Add an image to the open project",
      description: "Places an image file as a new layer on top of the project open in the app, as one undo step. Centered unless x and y are given.",
      inputSchema: {
        image: z.string().min(1).describe("Image file to add (PNG, JPEG, HEIC or TIFF)."),
        name: z.string().min(1).optional(),
        x: z.number().optional(), y: z.number().optional(), width: z.number().positive().optional(), height: z.number().positive().optional(),
        opacity: z.number().min(0).max(100).optional(), blend: z.enum(BLEND_MODES).optional(),
      },
      annotations: EDITS,
    },
    async ({ image, ...rest }) => {
      try {
        // The sandboxed app cannot open arbitrary paths, so the pixels travel over the connection.
        return ok(await live("addLayer", { png: (await readFile(resolvePath(image))).toString("base64"), ...rest }));
      } catch (error) { return failed(error); }
    },
  );

  server.registerTool(
    "compositor_live_set_layer",
    {
      title: "Change a layer in the open project",
      description: "Renames, shows or hides, moves, resizes, rotates, fades or re-blends a layer of the project open in the app. Only what is given changes.",
      inputSchema: {
        layer, name: z.string().min(1).optional(), visible: z.boolean().optional(),
        x: z.number().optional(), y: z.number().optional(), width: z.number().positive().optional(), height: z.number().positive().optional(),
        rotation: z.number().optional(), opacity: z.number().min(0).max(100).optional(), blend: z.enum(BLEND_MODES).optional(),
      },
      annotations: { ...EDITS, idempotentHint: true },
    },
    async (input) => { try { return ok(await live("setLayer", input)); } catch (error) { return failed(error); } },
  );

  server.registerTool(
    "compositor_live_apply_filter",
    {
      title: "Apply a filter in the open project",
      description:
        "Runs one of the app's filters on a layer of the open project, limited to the user's selection if there is " +
        "one, as one undo step. filter is a name from the app's Filter menu, e.g. Gaussian Blur, Remove Background, " +
        "Content-Aware Fill (needs a selection), Make Tileable, Height to Normal Map. settings keys: radius, angle, " +
        "distance, amount, distortion, horizontal, vertical, band, lighting, strength, highPassRadius, sharpenAmount, " +
        "sharpenRadius, threshold, normalStrength, cells, refine, contrast, shift, and the switches gaussian, " +
        "monochromatic, keepEdges, yDown, wrap.",
      inputSchema: { layer, filter: z.string().min(1), settings: z.record(z.union([z.number(), z.boolean()])).optional() },
      annotations: EDITS,
    },
    async (input) => { try { return ok(await live("filter", input)); } catch (error) { return failed(error); } },
  );

  server.registerTool(
    "compositor_live_add_adjustment",
    {
      title: "Add an adjustment layer in the open project",
      description: "Adds an adjustment layer (Hue/Saturation, Levels, Curves, Exposure, Gradient Map, Grain) above a layer of the open project and opens its panel in the app, for the user to tune.",
      inputSchema: { kind: z.enum(["Hue/Saturation", "Levels", "Curves", "Exposure", "Gradient Map", "Grain"]), above: layer },
      annotations: EDITS,
    },
    async (input) => { try { return ok(await live("addAdjustment", input)); } catch (error) { return failed(error); } },
  );

  server.registerTool(
    "compositor_live_undo",
    {
      title: "Undo the last step in the open project",
      description: "Undoes the most recent step in the app, whoever made it, and says which it was. Use it to take back your own last change when a result looks wrong.",
      inputSchema: {},
      annotations: EDITS,
    },
    async () => { try { return ok(await live("undo")); } catch (error) { return failed(error); } },
  );
}
