import { z } from "zod";
import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { options, resolvePath, run } from "../cli.js";
import { EDITS, failed, ok, project } from "../shared.js";

const WRITES_FILES = { ...EDITS, idempotentHint: true };

/** Tools that turn a finished texture into the set of maps a game material needs. They write files only. */
export function registerTextureTools(server: McpServer) {
  server.registerTool(
    "compositor_derive_maps",
    {
      title: "Derive a material's maps from a texture",
      description:
        "From the finished picture, writes NAME_albedo, NAME_height, NAME_normal, NAME_roughness and NAME_ao as PNGs " +
        "into a folder. They are estimates from brightness alone (bright is treated as high, smooth and open), a " +
        "starting point rather than measured data: say so to the user, and expect metals, painted surfaces and " +
        "strongly colored textures to need their roughness adjusted. Make the texture tileable first; the normal " +
        "map reads across the edges on that assumption. Pack the results with compositor_pack_channels. " +
        "The project is not changed. These file-based map tools have no screen in the app yet.",
      inputSchema: {
        project,
        out_dir: z.string().min(1).describe("Folder to write into; created if missing. e.g. ~/game/assets/materials/wall"),
        name: z.string().min(1).describe("Base file name, e.g. wall."),
        strength: z.number().min(0.1).max(50).optional().describe("Normal map slope strength (default 4)."),
        y_down: z.boolean().optional().describe("Normal map green points down (Unreal, DirectX). Leave false for Godot, Unity, Blender."),
      },
      annotations: WRITES_FILES,
    },
    async ({ project, out_dir, name, strength, y_down }) => {
      try {
        return ok(await run("derive-maps", [resolvePath(project), ...options({ "out-dir": resolvePath(out_dir), name, strength, "y-down": y_down }, ["y-down"])]));
      } catch (error) { return failed(error); }
    },
  );

  server.registerTool(
    "compositor_pack_channels",
    {
      title: "Pack grayscale maps into one texture's channels",
      description:
        "Writes one PNG whose channels each carry a grayscale map, which is how engines want occlusion, roughness " +
        "and metallic delivered. layout 'orm' is glTF's and Godot's (red occlusion, green roughness, blue metallic); " +
        "'unity-mask' is Unity HDRP's mask map (red metallic, green occlusion, alpha smoothness, which is roughness " +
        "inverted for you). Or place any map with red/green/blue/alpha. Missing color channels are 0 and a missing " +
        "alpha is 1. All maps must be the same size. Values are written exactly, never multiplied by alpha.",
      inputSchema: {
        output: z.string().min(1).describe("PNG file to write, e.g. ~/game/assets/materials/wall/wall_orm.png"),
        layout: z.enum(["orm", "unity-mask"]).optional(),
        ao: z.string().optional().describe("Ambient occlusion map (with layout)."),
        roughness: z.string().optional().describe("Roughness map (with layout)."),
        metallic: z.string().optional().describe("Metallic map (with layout); omit for non-metals."),
        red: z.string().optional(), green: z.string().optional(), blue: z.string().optional(), alpha: z.string().optional(),
      },
      annotations: WRITES_FILES,
    },
    async ({ output, layout, ...maps }) => {
      try {
        const files = Object.fromEntries(Object.entries(maps).map(([key, value]) => [key, value ? resolvePath(value) : undefined]));
        return ok(await run("pack-channels", options({ out: resolvePath(output), layout, ...files })));
      } catch (error) { return failed(error); }
    },
  );

  server.registerTool(
    "compositor_heightmap_normal",
    {
      title: "Make a normal map from a 16-bit heightmap",
      description:
        "Reads a grayscale heightmap file at its full 16-bit precision and writes a normal map PNG. Use this for " +
        "terrain and any smooth, gentle slopes: Compositor's layers are 8-bit, where such slopes turn into visible " +
        "steps, so heightmaps are handled as files rather than layers. For an ordinary 8-bit texture in a project, " +
        "use compositor_apply_filter with 'Height to Normal Map' instead.",
      inputSchema: {
        heightmap: z.string().min(1).describe("Grayscale image, ideally 16-bit PNG or TIFF; white is high."),
        output: z.string().min(1).describe("PNG file to write."),
        strength: z.number().min(0.1).max(200).optional().describe("Slope strength (default 4); gentle terrain needs far more, e.g. 50."),
        y_down: z.boolean().optional().describe("Green points down (Unreal, DirectX)."),
        no_wrap: z.boolean().optional().describe("Do not read slopes across the edges; set for terrain that does not tile."),
      },
      annotations: WRITES_FILES,
    },
    async ({ heightmap, output, strength, y_down, no_wrap }) => {
      try {
        return ok(await run("heightmap-normal", [resolvePath(heightmap), ...options({ out: resolvePath(output), strength, "y-down": y_down, "no-wrap": no_wrap }, ["y-down", "no-wrap"])]));
      } catch (error) { return failed(error); }
    },
  );
}
