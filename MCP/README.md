# compositor-mcp-server

Lets an AI agent build, edit and look at Compositor (`.comp`) projects. It is a thin layer over `compositor-cli` (see `../CLI`), which runs the app's own engine without a window, so everything the agent makes is an ordinary layered project that opens in the Compositor app and stays editable by hand.

Fork-only: nothing here touches the app's sources.

## Set up

```sh
cd ~/dev/Compositor
xcodebuild -project CLI/CompositorCLI.xcodeproj -target compositor-cli -configuration Release -arch arm64 \
  SYMROOT=$PWD/CLI/build OBJROOT=$PWD/CLI/build/obj build
cd MCP && npm install && npm test          # builds, then drives the real server as an MCP client

claude mcp add --scope user compositor -- node ~/dev/Compositor/MCP/dist/index.js
```

The server uses `CLI/build/Release/compositor-cli`, falling back to the Debug build; set `COMPOSITOR_CLI` to use a binary somewhere else. After pulling changes, rebuild both: the Swift tool with the `xcodebuild` line, the server with `npm run build`.

## Tools

| Tool | What it does |
|---|---|
| `compositor_get_info` | Canvas size and every layer, top first |
| `compositor_render_view` | Returns the finished picture as an image — the whole canvas or a region |
| `compositor_tile_preview` | Returns the canvas repeated as tiles, for judging seams and repetition |
| `compositor_sample_color` | The color at one pixel, as the eyedropper reads it |
| `compositor_new_project` | A new transparent canvas |
| `compositor_import_psd` | Opens a Photoshop document as a project: layers, folders, masks, opacity, blend modes |
| `compositor_run_action` | Replays a saved list of steps on a project |
| `compositor_add_text` / `compositor_set_text` | Live text layers |
| `compositor_add_layer_effect` | Drop shadow, outer glow or stroke, as a layer beneath its source |
| `compositor_add_image_layer` | An image file as a new layer, placed, scaled, blended |
| `compositor_add_empty_layer` | A blank layer or a folder |
| `compositor_set_layer` | Name, visibility, position, size, rotation, flips, opacity, blend mode |
| `compositor_move_layer` | Reorder, or move into and out of folders |
| `compositor_delete_layer` | Remove a layer |
| `compositor_set_mask` | Set a mask from a grayscale image, switch it, or remove it |
| `compositor_make_tileable` | Evens a texture's lighting and heals its seams so it repeats cleanly |
| `compositor_cutout` | One step from a photo to its subject on transparency, cropped to the subject |
| `compositor_crop` | Crop to a box, or to the visible content; layers keep their pixels |
| `compositor_remove_background` | Hide a layer's background behind a mask (on-device) |
| `compositor_subject_mask` | Save a layer's subject as a mask image |
| `compositor_add_adjustment` | Levels, Hue/Saturation, Exposure and the other adjustment layers |
| `compositor_apply_filter` | Any of the app's filters: blurs (optionally keeping edges solid), noise, Offset, Even Lighting, High Pass, Unsharp Mask, Height to Normal Map, Clouds… |
| `compositor_derive_maps` | Writes albedo, height, normal, roughness and AO maps from a finished texture |
| `compositor_pack_channels` | Packs grayscale maps into one texture (glTF/Godot ORM, Unity mask map, or any layout) |
| `compositor_heightmap_normal` | A normal map from a 16-bit heightmap file, at full precision |
| `compositor_resize` | Image Size (resample) or Canvas Size (no resampling) |
| `compositor_export` | PNG, JPEG, TIFF or TGA at full size, with optional edge bleed for engine cut-outs |

## Image models

Generation, editing, generative fill, model-based seam healing and upscaling go through providers, listed in `~/.config/compositor/providers.json` (created from `providers.example.json` on first use). Every provider is an equal entry and none is built in as a default: a request names one, or uses whichever the user has set as current with `compositor_set_current_provider`. Kinds: `mflux` (local, MLX; `uv tool install --upgrade mflux`), `gemini` (cloud; key from the `GEMINI_API_KEY` environment variable), and `command` (any scriptable runner, such as Draw Things' CLI or a ComfyUI script). Each result is logged with its prompt and seed in `~/.config/compositor/generations.jsonl`.

## Live control

With the fork's app running and **Compositor > Allow Assistant Control** switched on, the `compositor_live_` tools act on the project open in the front tab, each change an ordinary undo step. The app listens on the loopback address only and requires a token it writes inside its own container. The file tools refuse to edit a project the app has open with unsaved changes.

## Safety

If a project changes on disk while a command is running — most likely because it is open in the app and was saved — the project is left as it is, the result is saved beside it as `<name> (agent copy).comp`, and the tool call fails saying so. Even so, do not point the agent at a project that is open in the app with unsaved changes.
