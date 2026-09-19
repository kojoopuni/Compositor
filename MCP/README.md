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
| `compositor_sample_color` | The color at one pixel, as the eyedropper reads it |
| `compositor_new_project` | A new transparent canvas |
| `compositor_add_image_layer` | An image file as a new layer, placed, scaled, blended |
| `compositor_add_empty_layer` | A blank layer or a folder |
| `compositor_set_layer` | Name, visibility, position, size, rotation, flips, opacity, blend mode |
| `compositor_move_layer` | Reorder, or move into and out of folders |
| `compositor_delete_layer` | Remove a layer |
| `compositor_set_mask` | Set a mask from a grayscale image, switch it, or remove it |
| `compositor_cutout` | One step from a photo to its subject on transparency, cropped to the subject |
| `compositor_crop` | Crop to a box, or to the visible content; layers keep their pixels |
| `compositor_remove_background` | Hide a layer's background behind a mask (on-device) |
| `compositor_subject_mask` | Save a layer's subject as a mask image |
| `compositor_add_adjustment` | Levels, Hue/Saturation, Exposure and the other adjustment layers |
| `compositor_apply_filter` | Blur, noise, lens correction and the app's other filters |
| `compositor_resize` | Image Size (resample) or Canvas Size (no resampling) |
| `compositor_export` | PNG or JPEG at full size |

## Safety

If a project changes on disk while a command is running — most likely because it is open in the app and was saved — the project is left as it is, the result is saved beside it as `<name> (agent copy).comp`, and the tool call fails saying so. Even so, do not point the agent at a project that is open in the app with unsaved changes.
