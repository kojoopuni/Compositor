# Testing the fork

Two kinds of test. The automated ones check that pixels, files and tools behave; they cannot tell whether a panel feels right, a brush responds well, or a texture looks good. That part needs a person, and is the second half of this file.

## Automated

```sh
cd ~/dev/Compositor

# The app's own suite (about 5 minutes). Expect one known failure, CursorTests.optionOverALayerRow…,
# which depends on the test window being frontmost.
xcodebuild -project Compositor.xcodeproj -scheme Compositor -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO ENABLE_DEBUG_DYLIB=NO -parallel-testing-enabled NO -only-testing:CompositorTests test

python3 CLI/Tests/run.py          # the command-line tool, end to end (about a minute)
(cd MCP && npm test)              # the MCP server, driven as a real client (about a minute)
Fork/sync-upstream.sh             # dry run: would upstream's latest merge and build cleanly?
```

## By hand

Install the fork's app first: `Fork/build-app.sh --install`, then open **Compositor Fork** from Applications. Each check says what to do and what should happen. Note anything that looks or feels wrong, even slightly; a screenshot is the most useful report.

### 1. It is a separate app
- [ ] It sits beside the released Compositor, with its own name in the menu bar and Dock.
- [ ] Compositor Fork > Check for Updates… says it is up to date, and never offers upstream's release.

### 2. Textures (Filter menu, View menu)
Open a photo of a fine-grained surface (soil, sand, plaster, concrete) and, separately, one made of distinct shapes (bricks, cobbles, planks).
- [ ] **View > Tile Preview** (⌥⌘T) shows the canvas repeated; switching 2 × 2 / 3 × 3 / 4 × 4 works, and it updates after an edit.
- [ ] **Filter > Offset** at 50/50 brings the seams to the middle; −50/−50 afterwards restores the image exactly.
- [ ] **Filter > Make Tileable** on the fine-grained photo: the tile preview shows no seams. Try Seam Band at 8 and 25. Is there a visible strip along the joins? Does Even Lighting flatten the texture too much at 100?
- [ ] **Make Tileable on the brick or cobble photo is expected to smear** the band. That is the known limit of this method; the model method below is for these.
- [ ] **Filter > Even Lighting**, **High Pass**, **Unsharp Mask**, **Clouds**: each previews live, respects a selection, and is one undo step.
- [ ] **Filter > Height to Normal Map** on a grayscale texture gives the usual blue-purple map. In Godot or Unity (green up) the bumps should read as raised, not dented; tick "Green points down" only for Unreal.
- [ ] **Gaussian Blur with "Keep edges solid"** on a layer that fills the canvas: the borders stay opaque. Without it they fade, as upstream's does.

### 3. Cut-outs and export (Filter, Image, File menus)
- [ ] **Filter > Remove Background** on a portrait, then **Image > Trim Transparent Pixels**: the canvas shrinks to the subject, and ⌘Z brings it back.
- [ ] **File > Export PNG with Edge Bleed…**, then put that PNG on a plane in Godot or Unity with filtering on: no dark halo around the edges. Compare with a plain Export PNG of the same cut-out.
- [ ] **File > Export TGA…** and **Export TIFF…** open correctly in Blender or the engine, with transparency.

### 4. General editing (Image, Layer, Select menus)
- [ ] **Image >** Black & White, Threshold, Posterize, Vibrance, Color Balance, Photo Filter: each opens a panel with a live preview. The same six appear under **Layer > New Adjustment Layer**, and double-clicking such a layer reopens its panel with the saved values.
- [ ] The blend mode menu now ends with Soft Light, Hard Light, Exclusion, Linear Dodge, Linear Burn, Vivid Light, Linear Light, Pin Light, Divide, Subtract. Compare two or three against Photoshop 2025 with the same two layers.
- [ ] **Color Dodge** and **Levels with inverted output on a soft-edged layer** now match Photoshop (these were upstream bugs).
- [ ] **Layer > New Text Layer…** (⇧⌘T): type, change font, size, tracking, leading, alignment and color; the canvas follows. Done, then scale the layer with the Move tool: the text stays sharp. **Layer > Edit Text…** reopens it. Paint on it and Edit Text… is disabled (it is pixels now).
- [ ] **Layer > Layer Effects >** Drop Shadow, Outer Glow, Stroke on a cut-out or text layer: a new layer appears directly beneath, and the panel's sliders redraw it.
- [ ] **Select > Subject** on a portrait, and **Select > Color Range** after picking a color with the Eyedropper.
- [ ] **With a pen tablet**: the Brush is thin with a light touch and full width pressed hard, swelling smoothly between. With a mouse it is exactly as before. How does the response feel: too sensitive, not enough?
- [ ] **File > Open Photoshop Document…** on one of your own .psd files: layers, folders, masks and blend modes arrive in a new tab; a message lists anything Photoshop draws itself.

### 5. Working with Claude
In a new Claude Code session (it sees the `compositor_` tools automatically):
- [ ] "Using the compositor tools, list the image providers." The local ones should show as available; Gemini needs `GEMINI_API_KEY`.
- [ ] "Generate a 1024 px top-down mossy cobblestone texture with flux2-klein-4b into ~/Desktop/cobble.comp, make it tileable with the model method, show me the tile preview, then derive its maps and pack an ORM texture into ~/Desktop/cobble-material." About two minutes locally. Then open the .comp in the app.
- [ ] "Cut out ~/Desktop/<a photo> to a transparent PNG with 20 px padding and keep the project."
- [ ] "Upscale <a small image> 2× with seedvr2-upscale." Compare with Image > Image Size at 200%.
- [ ] Live: in the app switch on **Compositor Fork > Allow Assistant Control**, open a project, and ask Claude "what do I have open in Compositor?" then "blur the active layer by 4 px, keeping its edges". The change should appear in the app, and ⌘Z should undo it.
- [ ] With that project open and unsaved, ask Claude to edit the same file with the file tools: it should refuse and say why.

## Known limits, stated plainly
- Make Tileable's built-in (patch) method smears surfaces made of distinct shapes; the model method handles those, from Claude only.
- No GUI yet for: deriving map sets, packing channels, 16-bit heightmaps, actions, image generation, generative fill, model-based seam healing, AI upscaling. These are Claude-only until they get panels.
- Layer effects are generated layers, not live styles: move or edit the source and the effect must be added again.
- Text is edited in a panel, not by clicking on the canvas.
- PSD import is one way; text and smart objects arrive as pixels, styles are dropped, 16-bit/CMYK/.psb are refused.
- Not built: pen tool and vector paths, warp and perspective transform, smart objects, 16/32-bit color, CMYK.
- Untested because nothing was available to test with: the Gemini provider (no API key), the Qwen-Image-Edit and Z-Image providers (not downloaded), a real pen tablet (pressure is tested with simulated values).
