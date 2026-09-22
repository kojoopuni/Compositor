# Compositor (kojoopuni fork)

A fork of `robbietilton/Compositor`, a Photoshop-style Mac image editor (Swift, macOS 26, Xcode 26). The fork adds a command-line build, an MCP server, texture tools and general editing features, while staying mergeable with upstream. The full plan is in `~/.claude/plans/so-what-if-we-prancy-sparrow.md`.

## Build and test

```sh
# Full unit suite (Swift Testing). ENABLE_DEBUG_DYLIB=NO matches upstream's own benchmark command.
xcodebuild -project Compositor.xcodeproj -scheme Compositor -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO ENABLE_DEBUG_DYLIB=NO -only-testing:CompositorTests test

# One suite
… -only-testing:CompositorTests/FilterTests test

# Brush benchmark — run alone, before and after any brush change (see docs/brush-performance.md)
TEST_RUNNER_BRUSH_BENCHMARK=1 xcodebuild … -parallel-testing-enabled NO \
  -only-testing:CompositorTests/BrushPerformanceTests test
```

### Baseline (upstream `a19db90`, 2026-09-18)

Upstream's suite did not compile at that commit; branch `fix/stale-tests` brings seven stale tests back in line with the app. Two real rendering bugs the tests then caught are fixed on `fix/rendering-bugs` (merged here, not yet sent upstream):

- Color Dodge and Color Burn blended in linear light, because `SeparableBlend`'s Core Image context was left color-managed; every other mode blends sRGB values. 0.8 dodged over 0.4 exported as 0.616 instead of white.
- Levels applied its alpha handling twice (once in `levels_apply`, again in Swift since upstream's "Fix dark soft edges" commit), darkening soft edges.

One test still fails on unmodified app code and is the regression baseline — anything else failing is ours:

- `CursorTests.optionOverALayerRowOffersDuplicatingExceptOverThumbnails` — compares `NSCursor.current`, which depends on the test window being frontmost; likely environmental.

`SelectionEditTests.invertIsFast…` has a 1.5 s time limit and fails only under parallel load; run suites with `-parallel-testing-enabled NO` when timing matters.

## The fork's features, and the parity rule

**Every feature must be reachable from the app's menus, not only from the tools.** Build it into the app first, then have `compositor-cli` and the MCP server call that same code. If something needs new UI before it can be in the app, say so plainly ("no GUI yet") rather than leaving it silent.

In the app (each reachable from a menu; the fork's menu items live in `UI/ForkMenus.swift`, one small view per menu, so `CompositorApp.swift` carries one added line per menu):

- **Filter** (generated from `FilterKind`, so a new case appears by itself): Offset, Make Tileable, Even Lighting, High Pass, Unsharp Mask, Height to Normal Map, Clouds; "Keep edges solid" on the blurs. `Document/TextureFilters.swift`, `Rendering/TexturePixels.c`.
- **Image**: Black & White, Threshold, Posterize, Vibrance, Color Balance, Photo Filter (also adjustment layers; one settings struct, `Document/ColorAdjustments.swift`, `Rendering/ColorPixels.c`), Trim Transparent Pixels (`Document/Trim.swift`).
- **Layer**: New Text Layer… / Edit Text… (`Document/TextLayers.swift`, `UI/TextPanel.swift`; the text style rides in the shape slot, `LayerShapeStyle.text`, so saving, copying, resizing and undo needed no changes), Layer Effects (`Document/LayerEffects.swift`, generated layers beneath their source).
- **Select**: Subject, Color Range (`Document/SmartSelections.swift`).
- **View**: Tile Preview (`UI/TilePreview.swift`, `Rendering/TileSheet.swift`).
- **File**: Export TIFF, TGA, PNG with Edge Bleed; Open Photoshop Document… (`IO/ExportFormats.swift`, `IO/PSDImporter.swift`, `IO/ProjectController+Formats.swift`).
- **App menu**: Allow Assistant Control (`Control/`, a loopback, token-protected server; off by default).
- Blend modes: ten more at the end of `LayerBlendMode`; those Core Graphics lacks go through `SeparableBlend` via `coreImageFilter`.
- Pen pressure: `Document/PenPressure.swift` reads it from the current event; a pen stroke uses the brush's software path with per-dab size, a mouse stroke is untouched (GPU path).

Upstream's five busiest files (`EditorCanvas`, `EditorSession`, `ContentView`, `NativeLayerList`, `project.pbxproj`) have no fork edits. Keep it that way.

No GUI yet (command-line and MCP only): `derive-maps`, `pack-channels`, `heightmap-normal`, `cutout`, `run-action`, and everything that needs an image model (generate, edit, generative fill, model-based seam healing, upscale; `MCP/src/providers/`). Not built: pen tool, warp/perspective, smart objects, on-canvas text editing, live layer styles.

Hands-on checks for a person are in `Fork/TESTING.md`. `Fork/sync-upstream.sh` dry-runs a merge of upstream's latest and rebuilds the tool against it.

Build the fork's own app with `Fork/build-app.sh` (`--install` copies it to /Applications as "Compositor Fork", with its own bundle id and upstream's update feed replaced by the fork's empty one).

## Command-line tool (`CLI/`, fork-only)

`compositor-cli` is the app's engine without a window, built from its own project so `Compositor.xcodeproj` is never edited. It compiles everything under `Compositor/` except `UI/` and the handful of files that build views or windows.

```sh
python3 CLI/make_project.py      # regenerate the project; run after merging upstream (new UI files are excluded from disk)
python3 CLI/Tests/run.py         # build, then run the end-to-end tests
CLI/build/Debug/compositor-cli help
```

- If upstream adds a file outside `UI/` that needs a window, the CLI build fails on it: add it to `WINDOWED` in `CLI/make_project.py`.
- Commands open the project into a bare `EditorSession` and call the same methods the app does (`Workspace.swift`), so edits follow the app's rules. Resizing uses the `ImageResizer`/`CanvasResizer` actors on the saved snapshot.
- Automatic filters (Remove Background) commit only after their preview settles; `Commands.apply` waits for that.
- The app's blurs spread past a layer's edges by default; pass `--keep-edges` for a texture or background that must keep covering the canvas.
- Never edit a `.comp` from the CLI while the app has it open with unsaved changes.

## MCP server (`MCP/`, fork-only)

A stdio MCP server (TypeScript) that shells out to `compositor-cli`; see `MCP/README.md` for setup and the tool list. `cd MCP && npm test` builds it and drives the real server as an MCP client. A new CLI command becomes a tool in `MCP/src/tools/`: inputs validated with Zod, a description that says when to use it, and annotations (`READ_ONLY`, `EDITS` or `DESTROYS` from `shared.ts`). `compositor_render_view` returns the canvas as image content, which is how the agent checks its own work.

## Rules that keep the fork mergeable

Upstream commits daily, mostly to `Rendering/EditorCanvas.swift`, `Document/EditorSession.swift`, `ContentView.swift`, `CompositorApp.swift`, `UI/NativeLayerList.swift` and `project.pbxproj`.

1. `origin` is the fork, `upstream` is robbietilton. Merge `upstream/main` before starting each piece of work.
2. New code goes in **new files**. The project uses file-system-synchronized groups, so a new file under `Compositor/` or `CompositorTests/` joins its target with no `project.pbxproj` edit. Session API goes in an `extension EditorSession { }` file, which is the codebase's own pattern.
3. Edits to the hot files above are one-line hooks only. Never restructure them.
4. Never bump `ProjectManifest.version` in the fork. Add optional fields only (as `shape` was). Version bumps go through an upstream PR.
5. A new `ImageLayer` property must be added to `ImageLayer.==` (`Document/EditorSession.swift`), or `DocumentHistory.end` sees no change and silently drops the undo step.
6. Features upstream could take (filters, adjustments, blend modes, export formats, pressure, text) are built on a branch cut from `upstream/main`, then merged into the fork. Fork-only work (`CLI/`, `MCP/`, `Compositor/Control/`) branches from the fork's `main`.
7. Open pull requests against upstream only when Kojo asks.

## Style

Match upstream: prose comments that explain why, `///` on stored properties, full-word names, booleans that read as sentences (`canPaint`, `showsBusy`), one-line bodies where they fit, almost no `// MARK:`. Tests use Swift Testing (`@Test`, `#expect`, `#require`) in `@MainActor struct` suites with sentence-style names. Commit subjects are one sentence-case line.

## Adding a filter (7 places)

1. `FilterKind` case in `Document/Filters.swift` — the raw value is the menu title and the undo name.
2. Fields in `FilterSettings`, with clamps in `normalized`.
3. An arm in `PixelFilter.run` — honour `job.scale` (preview pixels per layer pixel) and `job.seed`.
4. Rows in `UI/FilterSheet.swift`.
5. The Filter menu is generated from `FilterKind.allCases`; only Image-menu or shortcut placement needs a line in `CompositorApp.swift`.
6. A `@Test` in `CompositorTests/FilterTests.swift`: build a fixture, call `PixelFilter.run(FilterJob(...))`, read bytes.
7. If it must preview at full size (noise-like), add it to the opt-out list in `FilterEdit.prepared`.

A C kernel is a new `Rendering/<Name>Pixels.c/.h` plus one `#import` in `Compositor-Bridging-Header.h`. Selection limiting, live preview, undo and background execution come from the shared filter machinery.

## Adding an adjustment layer kind (9 places)

1. Settings struct in `Document/ImageAdjustments.swift`: static ranges, `isValid`, `normalized`, `apply(_:)`.
2–4. `AdjustmentKind` case, `symbol` arm, `filterKind` arm (`Document/LayerAdjustment.swift`).
5. An **optional** stored property plus a non-optional computed accessor on `LayerAdjustment`, so older projects decode and re-save unchanged.
6. `isValid` and `apply` arms.
7. Per-kind seeding in `addAdjustment`, if needed.
8. The shared-panel lists in `Document/AdjustmentEditing.swift` (begin and `editedAdjustment`).
9. Rows in `UI/FilterSheet.swift`, and switch arms in `CompositorTests/AdjustmentLayerTests.swift` — that suite is parameterised over `AdjustmentKind.allCases` and will not compile until they exist.

No `ProjectStore` or menu change is needed.

## Making an operation undoable

Guard on `canEditLayers` / `canAdjustColors` first. Do slow work before `beginEdit("<Name>")`, then re-check the target layer is unchanged, mutate `document`, and call `endEdit()`. Nested begin/end pairs collapse into one step. Previews must not be wrapped in `beginEdit`.

## Engine entry points that need no window

`ProjectStore.shared.load/save`, `ImageExporter.shared.render/pngData/jpeg`, `ImageImporter.shared.decode`, `CanvasResizer`, `ImageResizer`, `PixelFilter.run`, `LevelsFilter.run`, `HueSaturationFilter.run`, `SubjectRemoval.run`, `ContentFill.run`, `MagicWand.select`. `ImageExporter.render` composites a whole document from a `ProjectSnapshot` alone. A bare `EditorSession()` can be driven programmatically, as the tests do.
