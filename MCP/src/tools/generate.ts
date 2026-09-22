import { existsSync } from "node:fs";
import { copyFile, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { z } from "zod";
import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { options, resolvePath, run } from "../cli.js";
import { grayPNG } from "../png.js";
import { describeProviders, edit, generate, setCurrent, upscale } from "../providers/index.js";
import { EDITS, READ_ONLY, failed, ok, project } from "../shared.js";

const provider = z.string().min(1).optional().describe(
  "Provider name from compositor_list_providers. Omit to use the one the user has set as current for this kind of work; " +
  "if none is set the call fails and says so, because nothing is built in as a default.");
const OPEN_WORLD = { ...EDITS, openWorldHint: true };

async function scratch<T>(work: (folder: string) => Promise<T>): Promise<T> {
  const folder = await mkdtemp(path.join(tmpdir(), "compositor-generate-"));
  try { return await work(folder); } finally { await rm(folder, { recursive: true, force: true }); }
}

/** Tools that make or change pictures with an image model, cloud or local, chosen per request. */
export function registerGenerateTools(server: McpServer) {
  server.registerTool(
    "compositor_list_providers",
    {
      title: "List image model providers",
      description:
        "The image models this Mac can use — local ones (mflux on Apple silicon) and cloud ones (Gemini) alike — with " +
        "what each can do (generate, edit, upscale), whether it can run right now and why not, a note on speed and " +
        "license, and which one the user has set as current for each kind of work. Local models are free and private " +
        "but take tens of seconds to minutes; cloud models take seconds and need a key. Call this before generating.",
      inputSchema: {},
      annotations: READ_ONLY,
    },
    async () => { try { return ok(await describeProviders()); } catch (error) { return failed(error); } },
  );

  server.registerTool(
    "compositor_set_current_provider",
    {
      title: "Choose the provider used when none is named",
      description:
        "Sets, or with provider null clears, the provider used for one kind of work when a request names none. This " +
        "is the user's standing choice, saved in their config file: change it only when they ask.",
      inputSchema: {
        capability: z.enum(["generate", "edit", "upscale"]),
        provider: z.string().min(1).nullable().describe("A provider name, or null to clear the choice."),
      },
      annotations: { ...EDITS, idempotentHint: true },
    },
    async ({ capability, provider }) => {
      try { return ok({ current: (await setCurrent(capability, provider)).current }); } catch (error) { return failed(error); }
    },
  );

  server.registerTool(
    "compositor_generate_image",
    {
      title: "Generate an image from a description",
      description:
        "Makes a new picture with an image model and either adds it to a project as a new layer (give project; it is " +
        "created at this size if it does not exist) or writes it to a file (give output). Textures: ask for a flat, " +
        "evenly lit, top-down surface with no perspective and no objects, then use compositor_make_tileable and " +
        "compositor_tile_preview. The first run of a local model downloads its weights (several GB) and can take many " +
        "minutes; later runs take tens of seconds. Returns how long it took and the seed, so a result can be repeated.",
      inputSchema: {
        prompt: z.string().min(3).describe("What to make. Be specific about material, lighting, viewpoint and style."),
        width: z.number().int().min(256).max(4096).default(1024),
        height: z.number().int().min(256).max(4096).default(1024),
        seed: z.number().int().min(0).optional().describe("Same seed and prompt gives the same image on local models."),
        provider,
        project: project.optional().describe("Add the result to this .comp project as a new layer."),
        layer_name: z.string().min(1).optional().describe("Name for the new layer; defaults to the start of the prompt."),
        output: z.string().min(1).optional().describe("Or: PNG file to write."),
      },
      annotations: OPEN_WORLD,
    },
    async ({ prompt, width, height, seed, provider, project, layer_name, output }) => {
      try {
        if (!project && !output) throw new Error("give project (to add a layer) or output (to write a file)");
        return await scratch(async (folder) => {
          const file = path.join(folder, "generated.png");
          const used = seed ?? Math.floor(Math.random() * 2 ** 31);
          const result = await generate({ prompt, width, height, seed: used, output: file }, provider);
          const summary: Record<string, unknown> = { provider: result.provider, model: result.model, seconds: result.seconds, seed: used };
          if (output) { await copyFile(file, resolvePath(output)); summary.output = resolvePath(output); }
          if (project) {
            const target = resolvePath(project);
            if (!existsSync(target)) await run("new", [target, ...options({ width, height })]);
            // Fitted to the size asked for: cloud models choose their own pixel dimensions.
            const added = await run("add-layer", [target, file, ...options({ name: layer_name ?? `Generated: ${prompt.slice(0, 48)}`, width, height, x: 0, y: 0 })]);
            summary.project = target; summary.layer = added.added;
          }
          return ok(summary, "Look at the result with compositor_render_view before building on it.");
        });
      } catch (error) { return failed(error); }
    },
  );

  server.registerTool(
    "compositor_edit_image",
    {
      title: "Change a picture by instruction",
      description:
        "Hands a picture and an instruction ('make it autumn', 'remove the power lines', 'paint over this blockout in " +
        "a hand-painted style') to an image model. The picture is an image file, or a project's finished canvas. With " +
        "a project the result is added on top as a new layer, leaving everything beneath untouched, so it can be " +
        "masked, faded or deleted; otherwise it is written to output. Models redraw the whole picture, so details " +
        "outside the change can drift: for a change to one area use compositor_generative_fill instead.",
      inputSchema: {
        instruction: z.string().min(3),
        image: z.string().min(1).optional().describe("Image file to edit."),
        project: project.optional().describe("Or: edit this project's finished canvas and add the result as a layer."),
        layer_name: z.string().min(1).optional(),
        output: z.string().min(1).optional().describe("PNG file to write (required when editing an image file)."),
        seed: z.number().int().min(0).optional(),
        provider,
      },
      annotations: OPEN_WORLD,
    },
    async ({ instruction, image, project, layer_name, output, seed, provider }) => {
      try {
        if (!image && !project) throw new Error("give image or project");
        if (image && !project && !output) throw new Error("give output, the file to write the edited image to");
        return await scratch(async (folder) => {
          let source = image ? resolvePath(image) : path.join(folder, "canvas.png");
          let size: { width?: unknown; height?: unknown } = {};
          if (!image && project) {
            await run("export", [resolvePath(project), "--out", source]);
            size = await run("info", [resolvePath(project)]);
          }
          const file = path.join(folder, "edited.png");
          const result = await edit({ image: source, instruction, seed, output: file }, provider);
          const summary: Record<string, unknown> = { provider: result.provider, model: result.model, seconds: result.seconds };
          if (output) { await copyFile(file, resolvePath(output)); summary.output = resolvePath(output); }
          if (project) {
            const placed = size.width ? { width: size.width as number, height: size.height as number, x: 0, y: 0 } : {};
            const added = await run("add-layer", [resolvePath(project), file, ...options({ name: layer_name ?? `Edit: ${instruction.slice(0, 48)}`, ...placed })]);
            summary.project = resolvePath(project); summary.layer = added.added;
          }
          return ok(summary, "Look at the result with compositor_render_view; mask the new layer to keep only the part that improved.");
        });
      } catch (error) { return failed(error); }
    },
  );

  server.registerTool(
    "compositor_generative_fill",
    {
      title: "Regenerate one area of a project",
      description:
        "Changes just one rectangle of a project's canvas: the area (with some surroundings for context) is given to an " +
        "image model with the instruction, and the result comes back as a new layer over that area with a soft-edged " +
        "mask, so it blends into what is around it and everything else is untouched. Use it to remove or replace an " +
        "object, extend a surface, or repair a region. For plain texture-like repairs with no new content, the app's " +
        "Content-Aware Fill needs no model. Check the join with compositor_render_view on that region.",
      inputSchema: {
        project,
        region: z.object({ x: z.number().int().min(0), y: z.number().int().min(0), width: z.number().int().min(16), height: z.number().int().min(16) })
          .describe("The area to regenerate, in document pixels."),
        instruction: z.string().min(3).describe("What the area should become, e.g. 'empty grass, matching the surroundings'."),
        context: z.number().int().min(0).max(1024).default(96).describe("Pixels of surroundings shown to the model around the area."),
        feather: z.number().int().min(0).max(256).default(24).describe("Width of the soft edge where the new layer blends in."),
        layer_name: z.string().min(1).optional(),
        seed: z.number().int().min(0).optional(),
        provider,
      },
      annotations: OPEN_WORLD,
    },
    async ({ project, region, instruction, context, feather, layer_name, seed, provider }) => {
      try {
        return await scratch(async (folder) => {
          const target = resolvePath(project);
          const info = await run("info", [target]) as { width: number; height: number };
          const left = Math.max(0, region.x - context), top = Math.max(0, region.y - context);
          const right = Math.min(info.width, region.x + region.width + context), bottom = Math.min(info.height, region.y + region.height + context);
          const box = { x: left, y: top, width: right - left, height: bottom - top };
          const source = path.join(folder, "area.png"), file = path.join(folder, "filled.png"), mask = path.join(folder, "mask.png");
          await run("render", [target, ...options({ out: source, region: `${box.x},${box.y},${box.width},${box.height}`, "max-size": 8192 })]);
          const result = await edit({ image: source, instruction: `${instruction}. Keep everything else exactly as it is.`, seed, output: file }, provider);
          const added = await run("add-layer", [target, file, ...options({ name: layer_name ?? `Fill: ${instruction.slice(0, 48)}`, x: box.x, y: box.y, width: box.width, height: box.height })]);
          // White over the requested area, fading to black across the feather, and black over the context around it.
          const inner = { x: region.x - box.x, y: region.y - box.y };
          await writeFile(mask, grayPNG(box.width, box.height, (x, y) => {
            const inside = Math.min(x - inner.x, inner.x + region.width - 1 - x, y - inner.y, inner.y + region.height - 1 - y);
            return feather === 0 ? (inside >= 0 ? 255 : 0) : 255 * (inside + feather / 2) / feather;
          }));
          await run("set-mask", [target, String(added.added), mask]);
          return ok({ provider: result.provider, model: result.model, seconds: result.seconds, project: target, layer: added.added, area: box },
            "Look at the join with compositor_render_view on this area. Hide or delete the layer to go back.");
        });
      } catch (error) { return failed(error); }
    },
  );

  server.registerTool(
    "compositor_upscale_image",
    {
      title: "Enlarge an image with added detail",
      description:
        "Enlarges an image file with an upscaling model, which adds plausible detail, unlike compositor_resize, which " +
        "only resamples and leaves a small image soft. The detail is invented, not recovered: fine for textures and " +
        "backgrounds, to be checked carefully on faces and text. Writes a new file; the source is not changed.",
      inputSchema: {
        image: z.string().min(1).describe("Image file to enlarge."),
        output: z.string().min(1).describe("PNG file to write."),
        scale: z.number().min(1.5).max(4).default(2).describe("Enlargement factor."),
        provider,
      },
      annotations: OPEN_WORLD,
    },
    async ({ image, output, scale, provider }) => {
      try {
        const result = await upscale({ image: resolvePath(image), scale, output: resolvePath(output) }, provider);
        return ok({ provider: result.provider, model: result.model, seconds: result.seconds, output: result.output });
      } catch (error) { return failed(error); }
    },
  );
}
