import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { registerLayerTools } from "./tools/layers.js";
import { registerLookTools } from "./tools/look.js";
import { registerPixelTools } from "./tools/pixels.js";
import { registerTextureTools } from "./tools/textures.js";
import { registerGenerateTools } from "./tools/generate.js";

export function createServer(): McpServer {
  const server = new McpServer(
    { name: "compositor-mcp-server", version: "0.1.0" },
    {
      instructions:
        "Builds and edits Compositor (.comp) projects: layered, non-destructive image documents the user can open " +
        "in the Compositor app and keep editing by hand. Work the way a careful retoucher does: start with " +
        "compositor_get_info, prefer masks and adjustment layers to erasing or filtering pixels, give layers clear " +
        "unique names, and call compositor_render_view after changes that matter to see the real result. Everything " +
        "these tools do is also in the app's menus (Filter, Image, File > Export, View > Tile Preview) unless a tool " +
        "says otherwise, so the user can repeat or refine any step by hand. For a game texture: make it tileable, " +
        "judge it with compositor_tile_preview, derive its maps, pack them, and export into the engine's folder. Do not edit " +
        "a project the user has open in the app with unsaved changes; if a command reports the project changed while " +
        "it ran, tell the user where the '(agent copy)' was saved.",
    },
  );
  registerLookTools(server);
  registerLayerTools(server);
  registerPixelTools(server);
  registerTextureTools(server);
  registerGenerateTools(server);
  return server;
}
