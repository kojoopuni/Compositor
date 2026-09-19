import { z } from "zod";
import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { options, resolvePath, run } from "../cli.js";
import { DESTROYS, EDITS, appearance, failed, layer, ok, placement, placementOptions, project } from "../shared.js";

const SAVED_NOTE =
  "If this fails saying the project changed while the command ran, the project is open elsewhere (usually in the " +
  "Compositor app): the original was left alone and the result was saved beside it as an '(agent copy)'.";

/** Tools that create a project and arrange its layers. */
export function registerLayerTools(server: McpServer) {
  server.registerTool(
    "compositor_new_project",
    {
      title: "Create a project",
      description:
        "Creates a .comp project with a transparent canvas and one blank layer, and returns its info. 1–30,000 px a " +
        "side, at most 100 megapixels. Refuses to replace an existing project unless overwrite is true.",
      inputSchema: {
        project,
        width: z.number().int().min(1).max(30000).describe("Canvas width in pixels, e.g. 2048."),
        height: z.number().int().min(1).max(30000).describe("Canvas height in pixels."),
        overwrite: z.boolean().optional().describe("Replace an existing project at this path. Destroys it."),
      },
      annotations: DESTROYS,
    },
    async ({ project, width, height, overwrite }) => {
      try {
        return ok(await run("new", [resolvePath(project), ...options({ width, height, overwrite }, ["overwrite"])]));
      } catch (error) { return failed(error); }
    },
  );

  server.registerTool(
    "compositor_add_image_layer",
    {
      title: "Add an image as a layer",
      description:
        "Places a JPEG, PNG, HEIC or TIFF file as a new layer on top of the stack, centered unless x and y are given. " +
        "The pixels are copied into the project, so the source file can move or go. Returns the new layer's id. " +
        "The layer keeps its full resolution however small it is scaled. " + SAVED_NOTE,
      inputSchema: {
        project,
        image: z.string().min(1).describe("Image file to add, e.g. ~/Downloads/moss.png."),
        name: z.string().min(1).optional().describe("Layer name; defaults to the file's name. Unique names make later calls simpler."),
        ...placement,
        ...appearance,
      },
      annotations: EDITS,
    },
    async (input) => {
      try {
        return ok(await run("add-layer", [resolvePath(input.project), resolvePath(input.image),
          ...options({ name: input.name, ...placementOptions(input) })]));
      } catch (error) { return failed(error); }
    },
  );

  server.registerTool(
    "compositor_add_empty_layer",
    {
      title: "Add a blank layer or a folder",
      description:
        "Adds an empty pixel layer (kind 'blank') or an empty folder (kind 'folder') above the named layer, or on " +
        "top. Move layers into a folder with compositor_move_layer. " + SAVED_NOTE,
      inputSchema: {
        project,
        kind: z.enum(["blank", "folder"]),
        name: z.string().min(1).optional(),
        above: layer.optional().describe("Layer to add it above; defaults to the top of the stack."),
      },
      annotations: EDITS,
    },
    async ({ project, kind, name, above }) => {
      try {
        return ok(await run(kind === "folder" ? "add-folder" : "add-blank-layer", [resolvePath(project), ...options({ name, above })]));
      } catch (error) { return failed(error); }
    },
  );

  server.registerTool(
    "compositor_set_layer",
    {
      title: "Change a layer",
      description:
        "Renames, shows or hides, moves, scales, rotates, flips, fades or re-blends one layer. Only the properties " +
        "given change. Nothing here alters the layer's pixels, so every change can be revised later. Hiding a folder " +
        "hides everything in it. " + SAVED_NOTE,
      inputSchema: {
        project, layer,
        name: z.string().min(1).optional().describe("New name."),
        visible: z.boolean().optional(),
        ...placement,
        ...appearance,
      },
      annotations: { ...EDITS, idempotentHint: true },
    },
    async (input) => {
      try {
        return ok(await run("set-layer", [resolvePath(input.project), input.layer,
          ...options({ name: input.name, visible: input.visible, ...placementOptions(input) })]));
      } catch (error) { return failed(error); }
    },
  );

  server.registerTool(
    "compositor_move_layer",
    {
      title: "Reorder or nest a layer",
      description:
        "Changes where a layer sits in the stack. 'top' and 'bottom' stay within its current folder; 'above' puts it " +
        "directly above the target layer (joining the target's folder); 'into' puts it on top inside the target " +
        "folder; 'out' takes it to the top level. Layers higher in the stack cover those below. " + SAVED_NOTE,
      inputSchema: {
        project, layer,
        to: z.enum(["top", "bottom", "out", "above", "into"]),
        target: layer.optional().describe("Required for 'above' (any layer) and 'into' (a folder)."),
      },
      annotations: EDITS,
    },
    async ({ project, layer, to, target }) => {
      try {
        if ((to === "above" || to === "into") && !target) throw new Error(`'${to}' needs a target layer`);
        const where = to === "above" || to === "into" ? [`--${to}`, target as string] : [`--${to}`];
        return ok(await run("move-layer", [resolvePath(project), layer, ...where]));
      } catch (error) { return failed(error); }
    },
  );

  server.registerTool(
    "compositor_delete_layer",
    {
      title: "Delete a layer",
      description:
        "Removes a layer and its pixels from the project. There is no undo from here: prefer hiding it with " +
        "compositor_set_layer (visible false) unless the user asked for it to go. Layers clipped to it are released. " + SAVED_NOTE,
      inputSchema: { project, layer },
      annotations: DESTROYS,
    },
    async ({ project, layer }) => {
      try { return ok(await run("delete-layer", [resolvePath(project), layer])); } catch (error) { return failed(error); }
    },
  );

  server.registerTool(
    "compositor_crop",
    {
      title: "Crop the canvas",
      description:
        "Crops the document to a box, or with to_content to everything that is not transparent in the finished " +
        "picture (after compositor_remove_background, that is the subject), with optional padding. Layers keep all " +
        "their pixels, so growing the canvas later with compositor_resize brings back what was cropped away. " +
        "Returns the box that was kept, in the old document's pixels. " + SAVED_NOTE,
      inputSchema: {
        project,
        box: z.object({ x: z.number(), y: z.number(), width: z.number().positive(), height: z.number().positive() })
          .optional().describe("The part of the canvas to keep, in document pixels."),
        to_content: z.boolean().optional().describe("Crop to the visible content instead of a box."),
        padding: z.number().min(0).optional().describe("With to_content: pixels of margin to leave around the content."),
      },
      annotations: EDITS,
    },
    async ({ project, box, to_content, padding }) => {
      try {
        if (!box && !to_content) throw new Error("give box or to_content");
        return ok(await run("crop", [resolvePath(project), ...options({
          box: box ? `${box.x},${box.y},${box.width},${box.height}` : undefined, "to-content": to_content, padding,
        }, ["to-content"])]));
      } catch (error) { return failed(error); }
    },
  );

  server.registerTool(
    "compositor_resize",
    {
      title: "Resize the whole document",
      description:
        "With mode 'image', resamples every layer to a new document size (give width or height alone to keep the " +
        "proportions, or scale as a percentage). With mode 'canvas', grows or trims the canvas without resampling; " +
        "anchor says which part of the picture stays put. Both rewrite layer pixels or positions across the project. " + SAVED_NOTE,
      inputSchema: {
        project,
        mode: z.enum(["image", "canvas"]),
        width: z.number().int().min(1).max(30000).optional(),
        height: z.number().int().min(1).max(30000).optional(),
        scale: z.number().positive().optional().describe("Image mode only: percentage of the current size."),
        resolution: z.number().min(1).max(9600).optional().describe("Image mode only: pixels per inch metadata."),
        sampling: z.enum(["nearest", "smooth", "high"]).optional().describe("Image mode only."),
        anchor: z.enum(["top-left", "top", "top-right", "left", "center", "right", "bottom-left", "bottom", "bottom-right"])
          .optional().describe("Canvas mode only; default center."),
      },
      annotations: DESTROYS,
    },
    async ({ project, mode, width, height, scale, resolution, sampling, anchor }) => {
      try {
        const args = mode === "image" ? options({ width, height, scale, resolution, sampling }) : options({ width, height, anchor });
        return ok(await run(mode === "image" ? "resize" : "canvas-size", [resolvePath(project), ...args]));
      } catch (error) { return failed(error); }
    },
  );
}
