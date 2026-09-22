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

### Baseline (upstream 1.2.2, `609dbea`, 2026-09-22)

Upstream moved fast after launch: 74 commits and 15 releases in four days, adding its own type tool, PSD import, layer effects, all Photoshop blend modes, Black & White, Color Balance, Invert, object selection, rulers and guides, RAW import, brush smoothing, and the same bug fixes and test repairs this fork had made. The fork was rebased onto 1.2.2 on 2026-09-22 and **everything upstream now does was dropped from the fork in favor of upstream's own**. Kojo uses upstream's released app; the fork's app build exists only for the few app-side features below.

One test fails on unmodified upstream code and is the regression baseline: `CursorTests.optionOverALayerRow…` (depends on the test window being frontmost).

## The fork's features, and the parity rule

**Every feature must be reachable from the app's menus, not only from the tools.** If something needs new UI before it can be in the app, say so plainly ("no GUI yet").

In the app (the fork's menu items live in `UI/ForkMenus.swift`, one small view per menu; `CompositorApp.swift` carries one added line per menu):

- **Filter** (generated from `FilterKind`): Offset, Make Tileable, Even Lighting, High Pass, Unsharp Mask, Height to Normal Map, Clouds; "Keep edges solid" on the blurs. `Document/TextureFilters.swift`, `Rendering/TexturePixels.c`.
- **Image**: Threshold, Posterize, Vibrance, Photo Filter (also adjustment layers; `Document/ColorAdjustments.swift`, `Rendering/ColorPixels.c`), Trim Transparent Pixels (`Document/Trim.swift`).
- **Select**: Color Range (`Document/SmartSelections.swift`).
- **View**: Tile Preview (`UI/TilePreview.swift`, `Rendering/TileSheet.swift`).
- **File**: Export TIFF, TGA, PNG with Edge Bleed (`IO/ExportFormats.swift`, `IO/ProjectController+Formats.swift`).
- **App menu**: Allow Assistant Control (`Control/`, a loopback, token-protected server; off by default; needs the `network.server` entitlement).
- Pen pressure: `Document/PenPressure.swift`; a pen stroke uses the brush's software path with per-dab size, a mouse stroke is untouched.

Edits to upstream's own files, all small: `Filters.swift` (cases, settings, run arms), `LayerAdjustment.swift` and `AdjustmentEditing.swift` (four kinds), `FilterSheet.swift` (rows), `BrushStroke.swift` and `EditorSession+Brush.swift` (pressure), `CompositorApp.swift` (five one-line hooks), `CompositorApplicationDelegate.swift` (one line), the entitlements and bridging header, and four test files that switch over adjustment kinds. Upstream's `EditorCanvas`, `EditorSession`, `ContentView`, `NativeLayerList` and `project.pbxproj` have no fork edits. Keep it that way.

The tools call upstream's own code for text (`applyText`), effects (`setEffects`), PSD (`PSDReader`, `insertPhotoshop`) and subject selection. `CLI/make_project.py` must exclude any new upstream file that needs a window (`WINDOWED`) and include any `UI/` file the engine itself refers to (`ENGINE_UI`); the build tells you which.

No GUI yet (command-line and MCP only): `derive-maps`, `pack-channels`, `heightmap-normal`, `cutout`, `run-action`, and everything that needs an image model (generate, edit, generative fill, model-based seam healing, upscale; `MCP/src/providers/`).

Hands-on checks for a person are in `Fork/TESTING.md`. `Fork/sync-upstream.sh` dry-runs a merge of upstream's latest and rebuilds the tool against it.

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
