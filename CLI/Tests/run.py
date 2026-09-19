#!/usr/bin/env python3
"""End-to-end tests for compositor-cli: every command is run on fresh projects and checked through the tool's own
`info` and `sample` output, so a pass means the saved project really composites as expected.

    python3 CLI/Tests/run.py            # builds the tool first
    python3 CLI/Tests/run.py --no-build
"""
import json
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import zlib

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
BUILD = os.path.join(ROOT, "CLI", "build")
TOOL = os.path.join(BUILD, "Debug", "compositor-cli")


def build():
    subprocess.run(["python3", os.path.join(ROOT, "CLI", "make_project.py")], check=True, stdout=subprocess.DEVNULL)
    result = subprocess.run(
        ["xcodebuild", "-project", os.path.join(ROOT, "CLI", "CompositorCLI.xcodeproj"), "-target", "compositor-cli",
         "-configuration", "Debug", "-arch", "arm64", f"SYMROOT={BUILD}", f"OBJROOT={os.path.join(BUILD, 'obj')}", "build"],
        capture_output=True, text=True)
    if result.returncode != 0:
        print("\n".join(line for line in result.stdout.splitlines() if "error:" in line))
        sys.exit("the tool did not build")


def png(path, width, height, pixel):
    """A plain RGBA PNG; `pixel(x, y)` gives (red, green, blue, alpha)."""
    rows = b"".join(b"\x00" + bytes(c for x in range(width) for c in pixel(x, y)) for y in range(height))

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))

    with open(path, "wb") as file:
        file.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
                   + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))


def run(*arguments) -> dict:
    result = subprocess.run([TOOL, *map(str, arguments)], capture_output=True, text=True)
    assert result.returncode == 0, f"{arguments} failed: {result.stderr.strip()}"
    return json.loads(result.stdout)


def refused(*arguments) -> str:
    """The message a command fails with."""
    result = subprocess.run([TOOL, *map(str, arguments)], capture_output=True, text=True)
    assert result.returncode != 0, f"expected {arguments} to fail"
    return result.stderr.strip()


def sample(project, x, y):
    color = run("sample", project, "--at", f"{x},{y}")
    return color["red"], color["green"], color["blue"], color["alpha"]


def near(actual, expected, tolerance=2):
    return all(abs(a - e) <= tolerance for a, e in zip(actual, expected))


def layers(project):
    return run("info", project)["layers"]


def names(project):
    return [layer["name"] for layer in layers(project)]


tests = []


def test(function):
    tests.append(function)
    return function


@test
def a_new_project_is_one_blank_layer_and_refuses_to_overwrite(folder):
    project = os.path.join(folder, "new.comp")
    info = run("new", project, "--width", 64, "--height", 48)
    assert (info["width"], info["height"]) == (64, 48)
    assert [layer["kind"] for layer in info["layers"]] == ["blank"]
    assert sample(project, 10, 10)[3] == 0, "a new canvas is transparent"
    assert "already exists" in refused("new", project, "--width", 8, "--height", 8)
    run("new", project, "--width", 8, "--height", 8, "--overwrite")
    assert run("info", project)["width"] == 8
    assert "30,000" in refused("new", os.path.join(folder, "huge.comp"), "--width", 40000, "--height", 10)


@test
def added_layers_are_centered_then_placed_blended_and_faded(folder):
    project = os.path.join(folder, "layers.comp")
    run("new", project, "--width", 100, "--height", 100)
    run("add-layer", project, os.path.join(folder, "gray.png"), "--name", "Base")
    assert near(sample(project, 50, 50), (102, 102, 102, 255))
    run("add-layer", project, os.path.join(folder, "red.png"), "--name", "Red")
    red = next(layer for layer in layers(project) if layer["name"] == "Red")
    assert (red["x"], red["y"]) == (30, 30), "a 40 px layer is centered on a 100 px canvas"
    run("set-layer", project, "Red", "--x", 0, "--y", 0)
    assert near(sample(project, 10, 10), (255, 0, 0, 255)) and near(sample(project, 50, 50), (102, 102, 102, 255))
    run("set-layer", project, "Red", "--blend", "multiply")
    assert near(sample(project, 10, 10), (102, 0, 0, 255)), "multiply of red over 40% gray"
    run("set-layer", project, "Red", "--blend", "normal", "--opacity", 50)
    assert near(sample(project, 10, 10), (179, 51, 51, 255), 3)
    run("set-layer", project, "Red", "--visible", "false")
    assert near(sample(project, 10, 10), (102, 102, 102, 255))
    run("set-layer", project, "Red", "--visible", "true", "--opacity", 100, "--scale", 200, "--x", 0, "--y", 0)
    assert near(sample(project, 70, 70), (255, 0, 0, 255)), "scaled to 80 px it now covers this point"


@test
def layers_are_named_by_id_or_name_and_ambiguity_is_refused(folder):
    project = os.path.join(folder, "names.comp")
    run("new", project, "--width", 50, "--height", 50)
    first = run("add-layer", project, os.path.join(folder, "red.png"), "--name", "Twin")["added"]
    run("add-layer", project, os.path.join(folder, "red.png"), "--name", "Twin")
    assert "use a layer id" in refused("set-layer", project, "Twin", "--opacity", 10)
    run("set-layer", project, first, "--name", "First")
    assert "First" in names(project)
    assert "no layer" in refused("delete-layer", project, "Missing")
    run("delete-layer", project, "First")
    assert "First" not in names(project)


@test
def folders_hold_layers_and_order_can_change(folder):
    project = os.path.join(folder, "order.comp")
    run("new", project, "--width", 50, "--height", 50)
    run("add-layer", project, os.path.join(folder, "gray.png"), "--name", "Gray")
    run("add-layer", project, os.path.join(folder, "red.png"), "--name", "Red", "--x", 0, "--y", 0)
    assert near(sample(project, 5, 5), (255, 0, 0, 255))
    run("move-layer", project, "Red", "--bottom")
    assert near(sample(project, 5, 5), (102, 102, 102, 255)), "gray now covers red"
    run("move-layer", project, "Red", "--above", "Gray")
    assert near(sample(project, 5, 5), (255, 0, 0, 255))
    group = run("add-folder", project, "--name", "Group")["added"]
    run("move-layer", project, "Red", "--into", "Group")
    assert next(layer for layer in layers(project) if layer["name"] == "Red")["parent"] == group
    run("set-layer", project, "Group", "--visible", "false")
    assert near(sample(project, 5, 5), (102, 102, 102, 255)), "hiding a folder hides what is in it"
    run("set-layer", project, "Group", "--visible", "true")
    run("move-layer", project, "Red", "--out")
    assert "parent" not in next(layer for layer in layers(project) if layer["name"] == "Red")
    assert "not a folder" in refused("move-layer", project, "Red", "--into", "Gray")
    run("add-blank-layer", project, "--name", "Empty")
    assert names(project)[0] == "Empty"


@test
def masks_hide_without_erasing(folder):
    project = os.path.join(folder, "mask.comp")
    run("new", project, "--width", 40, "--height", 40)
    run("add-layer", project, os.path.join(folder, "red.png"), "--name", "Red")
    run("set-mask", project, "Red", os.path.join(folder, "halves.png"))
    assert sample(project, 5, 20)[3] == 0, "black hides"
    assert near(sample(project, 35, 20), (255, 0, 0, 255)), "white reveals"
    run("set-mask", project, "Red", "--enabled", "false")
    assert near(sample(project, 5, 20), (255, 0, 0, 255)), "a disabled mask shows everything"
    run("set-mask", project, "Red", "--enabled", "true")
    assert sample(project, 5, 20)[3] == 0
    assert run("set-mask", project, "Red", "--remove")["hasMask"] is False
    assert near(sample(project, 5, 20), (255, 0, 0, 255))


@test
def filters_change_pixels_and_adjustments_do_not(folder):
    project = os.path.join(folder, "pixels.comp")
    run("new", project, "--width", 40, "--height", 40)
    run("add-layer", project, os.path.join(folder, "split.png"), "--name", "Split")
    assert near(sample(project, 19, 20), (0, 0, 0, 255)) and near(sample(project, 20, 20), (255, 255, 255, 255))
    run("filter", project, "Split", "Gaussian Blur", "--radius", 3)
    edge = sample(project, 20, 20)
    assert 60 < edge[0] < 200, f"the hard edge is soft after a blur: {edge}"
    assert "filters:" in refused("filter", project, "Split", "Sharpen")

    adjusted = os.path.join(folder, "adjust.comp")
    run("new", adjusted, "--width", 40, "--height", 40)
    run("add-layer", adjusted, os.path.join(folder, "gray.png"), "--name", "Gray")
    run("add-adjustment", adjusted, "Levels", "--output-black", 255, "--output-white", 0, "--name", "Invert")
    assert near(sample(adjusted, 20, 20), (153, 153, 153, 255)), "inverted 40% gray"
    run("set-layer", adjusted, "Invert", "--visible", "false")
    assert near(sample(adjusted, 20, 20), (102, 102, 102, 255)), "the pixels underneath are untouched"
    assert "adjustments:" in refused("add-adjustment", adjusted, "Sepia")


@test
def offset_wraps_a_texture_and_the_tile_preview_repeats_it(folder):
    project = os.path.join(folder, "tile.comp")
    run("new", project, "--width", 40, "--height", 40)
    run("add-layer", project, os.path.join(folder, "split.png"), "--name", "Split")  # black left half, white right
    run("filter", project, "Split", "Offset", "--horizontal", 25, "--vertical", 0)
    assert near(sample(project, 5, 20), (255, 255, 255, 255)), "the white that left the right edge came back on the left"
    assert near(sample(project, 15, 20), (0, 0, 0, 255)) and near(sample(project, 35, 20), (255, 255, 255, 255))
    run("filter", project, "Split", "Offset", "--horizontal", -25, "--vertical", 0)
    assert near(sample(project, 5, 20), (0, 0, 0, 255)) and near(sample(project, 25, 20), (255, 255, 255, 255)), "sliding back restores it"
    sheet = run("tile-preview", project, "--out", os.path.join(folder, "sheet.png"), "--repeat", 3)
    assert (sheet["width"], sheet["height"], sheet["tile"]) == (120, 120, {"width": 40, "height": 40})
    small = run("tile-preview", project, "--out", os.path.join(folder, "small.png"), "--max-size", 90)
    assert (small["width"], small["tile"]["width"]) == (90, 30)


@test
def make_tileable_brings_opposite_edges_together(folder):
    import random
    random.seed(3)
    speckle = [[random.randint(-18, 18) for _ in range(64)] for _ in range(64)]
    # Much brighter on the right than the left, so untouched it cannot tile.
    png(os.path.join(folder, "lit.png"), 64, 64, lambda x, y: (*(max(0, min(255, 60 + x * 2 + speckle[y][x])),) * 3, 255))
    project = os.path.join(folder, "tileable.comp")
    run("new", project, "--width", 64, "--height", 64)
    run("add-layer", project, os.path.join(folder, "lit.png"), "--name", "Lit")

    def edge_gap():
        rows = range(4, 60, 8)
        return sum(abs(sample(project, 0, y)[0] - sample(project, 63, y)[0]) for y in rows) / len(rows)

    before = edge_gap()
    result = run("make-tileable", project, "Lit")
    after = edge_gap()
    assert result["lighting"] == 100
    assert before > 90 and after < 30, f"edges differed by {before:.0f} before and {after:.0f} after"
    assert sample(project, 32, 32)[3] == 255, "the texture stays opaque"
    assert "2–40" in refused("make-tileable", project, "Lit", "--band", 80)


def png16(path, width, height, value):
    """A 16-bit grayscale PNG; `value(x, y)` gives 0–65535."""
    rows = b"".join(b"\x00" + b"".join(struct.pack(">H", value(x, y)) for x in range(width)) for y in range(height))

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))

    with open(path, "wb") as file:
        file.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 16, 0, 0, 0, 0))
                   + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))


def pixel_of(image_path, folder, x, y):
    """A pixel of any image file, read by placing it in a throwaway project."""
    probe = os.path.join(folder, f"probe-{abs(hash((image_path, x, y)))}.comp")
    info = run("cutout", image_path, "--out", os.path.join(folder, "unused.png")) if False else None
    size = subprocess.run(["sips", "-g", "pixelWidth", "-g", "pixelHeight", image_path], capture_output=True, text=True).stdout.split()
    run("new", probe, "--width", size[-3], "--height", size[-1], "--overwrite")
    run("add-layer", probe, image_path)
    return sample(probe, x, y)


@test
def the_apps_texture_filters_run_from_the_command_line(folder):
    project = os.path.join(folder, "filters.comp")
    run("new", project, "--width", 40, "--height", 40)
    run("add-layer", project, os.path.join(folder, "split.png"), "--name", "Split")
    run("filter", project, "Split", "Gaussian Blur", "--radius", 4, "--keep-edges")
    assert sample(project, 0, 20)[3] == 255 and sample(project, 39, 0)[3] == 255, "edges stay solid"
    assert 60 < sample(project, 20, 20)[0] < 200, "and the inside is blurred"
    assert next(layer for layer in layers(project) if layer["name"] == "Split")["width"] == 40, "the layer did not grow"
    run("filter", project, "Split", "Height to Normal Map", "--strength", 4, "--no-wrap")
    flat, slope = sample(project, 3, 20), sample(project, 20, 20)
    assert near(flat, (128, 128, 255, 255), 3), flat
    assert slope[0] < 110 and abs(slope[1] - 128) <= 3, f"height rising to the right leans the normal left: {slope}"
    run("add-blank-layer", project, "--name", "Sky")
    assert "layer with pixels" in refused("filter", project, "Sky", "Clouds")
    for name in ["High Pass", "Unsharp Mask", "Even Lighting", "Clouds"]:
        run("filter", project, "Split", name)
    assert sample(project, 5, 5)[3] == 255


@test
def exports_cover_engine_formats_and_bleed_color_under_transparency(folder):
    project = os.path.join(folder, "bleed.comp")
    run("new", project, "--width", 32, "--height", 32)
    run("add-layer", project, os.path.join(folder, "red.png"), "--name", "Red", "--width", 8, "--height", 8, "--x", 12, "--y", 12)
    for name in ["out.tiff", "out.tga", "bled.png", "bled.tga"]:
        run("export", project, "--out", os.path.join(folder, name), *(["--bleed", 6] if name.startswith("bled") else []))
    assert os.path.getsize(os.path.join(folder, "out.tga")) == 18 + 32 * 32 * 4
    with open(os.path.join(folder, "out.tga"), "rb") as file:
        plain = file.read()
    with open(os.path.join(folder, "bled.tga"), "rb") as file:
        bled = file.read()
    beside = 18 + (16 * 32 + 9) * 4   # three pixels left of the square, stored blue, green, red, alpha
    assert plain[beside:beside + 4] == bytes([0, 0, 0, 0]) and bled[beside:beside + 4] == bytes([0, 0, 255, 0])
    assert "0–256" in refused("export", project, "--out", os.path.join(folder, "x.png"), "--bleed", 999)


@test
def map_sets_are_derived_packed_and_heightmaps_read_at_full_depth(folder):
    project = os.path.join(folder, "maps.comp")
    run("new", project, "--width", 32, "--height", 32)
    png(os.path.join(folder, "ramp.png"), 32, 32, lambda x, y: (x * 8, x * 8, x * 8, 255))
    run("add-layer", project, os.path.join(folder, "ramp.png"))
    maps = run("derive-maps", project, "--out-dir", os.path.join(folder, "set"), "--name", "wall")["maps"]
    assert sorted(maps) == ["albedo", "ao", "height", "normal", "roughness"] and all(os.path.exists(path) for path in maps.values())
    assert pixel_of(maps["normal"], folder, 16, 16)[0] < 120, "brighter to the right reads as rising to the right"

    png(os.path.join(folder, "ao.png"), 8, 8, lambda x, y: (200, 200, 200, 255))
    png(os.path.join(folder, "rough.png"), 8, 8, lambda x, y: (50, 50, 50, 255))
    packed = os.path.join(folder, "orm.png")
    result = run("pack-channels", "--layout", "orm", "--ao", os.path.join(folder, "ao.png"),
                 "--roughness", os.path.join(folder, "rough.png"), "--out", packed)
    assert result["channels"] == {"red": "ao.png", "green": "rough.png"}
    assert near(pixel_of(packed, folder, 4, 4), (200, 50, 0, 255), 3), "occlusion in red, roughness in green, no metal in blue"
    mask = os.path.join(folder, "mask.png")
    run("pack-channels", "--layout", "unity-mask", "--roughness", os.path.join(folder, "rough.png"), "--out", mask)
    assert "different sizes" in refused("pack-channels", "--red", os.path.join(folder, "ao.png"), "--green", os.path.join(folder, "ramp.png"), "--out", packed)

    # A slope so gentle that 8 bits would flatten it into steps: 16 bits keeps it a steady lean.
    png16(os.path.join(folder, "terrain.png"), 64, 8, lambda x, y: 20000 + x * 40)
    normal = os.path.join(folder, "terrain_normal.png")
    result = run("heightmap-normal", os.path.join(folder, "terrain.png"), "--out", normal, "--strength", 50, "--no-wrap")
    assert result["bitsRead"] == 16
    reds = {pixel_of(normal, folder, x, 4)[0] for x in (10, 25, 40, 55)}
    assert len(reds) == 1 and reds.pop() < 128, "every column leans the same way by the same amount"


@test
def text_layers_are_set_edited_and_stay_live(folder):
    project = os.path.join(folder, "text.comp")
    run("new", project, "--width", 400, "--height", 200)
    added = run("add-text", project, "Ruins\\nLevel 2", "--size", 48, "--color", "255,200,0", "--align", "center", "--name", "Title")
    assert added["size"] == 48
    title = next(layer for layer in layers(project) if layer["name"] == "Title")
    assert title["kind"] == "text" and title["text"] == "Ruins\nLevel 2" and title["fontSize"] == 48
    assert abs(title["x"] + title["width"] / 2 - 200) <= 1, "centered on the canvas"
    box = (int(title["x"]), int(title["y"]), int(title["width"]), int(title["height"]))
    colored = [sample(project, x, y) for x in range(box[0], box[0] + box[2], 3) for y in range(box[1], box[1] + box[3], 3)]
    assert any(near(color, (255, 200, 0, 255), 6) for color in colored), "the letters are the asked-for color"
    run("set-text", project, "Title", "--text", "A much longer title line", "--size", 30)
    longer = next(layer for layer in layers(project) if layer["name"] == "Title")
    assert longer["text"] == "A much longer title line" and (longer["x"], longer["y"]) == (title["x"], title["y"]), "it keeps its corner"
    run("set-layer", project, "Title", "--scale", 200)
    assert abs(next(layer for layer in layers(project) if layer["name"] == "Title")["fontSize"] - 60) < 1, "scaling sets the text again, larger"
    run("filter", project, "Title", "Gaussian Blur", "--radius", 2)
    assert next(layer for layer in layers(project) if layer["name"] == "Title")["kind"] == "pixels", "filtered, it is plain pixels"
    assert "not a text layer" in refused("set-text", project, "Title", "--size", 20)
    assert "some characters" in refused("add-text", project, "x", "--size", 9000)


@test
def actions_replay_saved_steps_on_any_project(folder):
    project = os.path.join(folder, "wall.comp")
    run("new", project, "--width", 40, "--height", 40)
    run("add-layer", project, os.path.join(folder, "split.png"), "--name", "Wall")
    action = os.path.join(folder, "prepare.json")
    with open(action, "w") as file:
        json.dump({"name": "Prepare", "steps": [
            ["filter", "{project}", "{layer}", "Offset", "--horizontal", "25", "--vertical", "0"],
            ["add-adjustment", "{project}", "Levels", "--output-black", "255", "--output-white", "0", "--name", "Invert"],
            ["export", "{project}", "--out", "{folder}/{name}_out.png"]]}, file)
    assert "needs {layer}" in refused("run-action", action, project)
    planned = run("run-action", action, project, "--set", "layer=Wall", "--dry-run")
    assert planned["steps"][2]["would run"][3] == os.path.join(folder, "wall_out.png")
    result = run("run-action", action, project, "--set", "layer=Wall")
    assert [step["command"] for step in result["steps"]] == ["filter", "add-adjustment", "export"] and result["action"] == "Prepare"
    assert os.path.exists(os.path.join(folder, "wall_out.png")) and "Invert" in names(project)
    with open(action, "w") as file:
        json.dump({"steps": [["set-layer", "{project}", "Wall", "--opacity", "50"], ["filter", "{project}", "Nope", "Offset"]]}, file)
    message = refused("run-action", action, project)
    assert "step 2" in message and "Steps 1–1 were applied" in message


@test
def a_photoshop_document_opens_as_layers(folder):
    def big(value, size): return value.to_bytes(size, "big", signed=value < 0)
    def raw(value, count): return big(0, 2) + bytes([value]) * count
    width, height = 12, 8
    planes = [(-1, raw(255, 96)), (0, raw(200, 96)), (1, raw(100, 96)), (2, raw(50, 96))]
    name = b"Paint"
    extra = big(0, 4) + big(0, 4) + bytes([len(name)]) + name + b"\0" * ((4 - (len(name) + 1) % 4) % 4)
    record = big(0, 4) + big(0, 4) + big(height, 4) + big(width, 4) + big(len(planes), 2)
    record += b"".join(big(channel, 2) + big(len(data), 4) for channel, data in planes)
    record += b"8BIMscrn" + bytes([128, 0, 0, 0]) + big(len(extra), 4) + extra
    info = big(1, 2) + record + b"".join(data for _, data in planes)
    info += b"\0" * (len(info) % 2)
    section = big(len(info), 4) + info + big(0, 4)
    document = b"8BPS" + big(1, 2) + b"\0" * 6 + big(4, 2) + big(height, 4) + big(width, 4) + big(8, 2) + big(3, 2)
    document += big(0, 4) + big(0, 4) + big(len(section), 4) + section + big(0, 2) + bytes([255]) * (width * height * 4)
    source = os.path.join(folder, "paint.psd")
    with open(source, "wb") as file:
        file.write(document)
    project = os.path.join(folder, "paint.comp")
    result = run("import-psd", source, "--out", project)
    assert (result["width"], result["height"], result["layers"]) == (12, 8, 1) and result["referenceLayerAdded"] is False
    layer = layers(project)[0]
    assert layer["name"] == "Paint" and layer["blendMode"] == "Screen" and abs(layer["opacity"] - 128 / 255) < 0.01
    assert "already exists" in refused("import-psd", source, "--out", project)
    assert "not a Photoshop document" in refused("import-psd", os.path.join(folder, "gray.png"), "--out", os.path.join(folder, "x.comp"))


@test
def effects_are_layers_beneath_their_source(folder):
    project = os.path.join(folder, "effects.comp")
    run("new", project, "--width", 200, "--height", 200)
    run("add-layer", project, os.path.join(folder, "red.png"), "--name", "Square")   # 40 px, centered: 80–120
    added = run("add-effect", project, "Square", "stroke", "--size", 6, "--color", "0,0,255")
    assert names(project)[:2] == ["Square", "Square stroke"] and added["effect"] == "Stroke"
    assert near(sample(project, 100, 100), (255, 0, 0, 255)) and near(sample(project, 77, 100), (0, 0, 255, 255)) and sample(project, 70, 100)[3] == 0
    run("add-effect", project, "Square", "shadow", "--distance", 30, "--angle", 180, "--size", 2, "--opacity", 100)
    assert sample(project, 140, 100)[3] > 200, "lit from the left, the shadow falls to the right"
    assert "shadow, glow or stroke" in refused("add-effect", project, "Square", "bevel")


@test
def the_forks_color_adjustments_work_as_filters_and_layers(folder):
    project = os.path.join(folder, "color.comp")
    run("new", project, "--width", 20, "--height", 20)
    png(os.path.join(folder, "orange.png"), 20, 20, lambda x, y: (255, 128, 0, 255))
    run("add-layer", project, os.path.join(folder, "orange.png"), "--name", "Orange")
    run("add-adjustment", project, "Black & White", "--reds", 100, "--greens", 0, "--blues", 0, "--name", "Mono")
    assert near(sample(project, 10, 10), (255, 255, 255, 255)), "all of red's brightness, none of green's"
    run("set-layer", project, "Mono", "--visible", "false")
    run("add-adjustment", project, "Posterize", "--levels", 2, "--name", "Poster")
    assert near(sample(project, 10, 10), (255, 255, 0, 255)), "half green rounds up to full"
    run("delete-layer", project, "Poster")
    run("filter", project, "Orange", "Threshold", "--level", 200)
    assert near(sample(project, 10, 10), (0, 0, 0, 255)), "orange is darker than level 200"


@test
def resizing_resamples_and_canvas_size_does_not(folder):
    project = os.path.join(folder, "size.comp")
    run("new", project, "--width", 40, "--height", 40)
    run("add-layer", project, os.path.join(folder, "red.png"))
    assert run("resize", project, "--width", 80) == {"width": 80, "height": 80}, "one side keeps the proportions"
    assert near(sample(project, 70, 70), (255, 0, 0, 255))
    assert run("resize", project, "--scale", 50) == {"width": 40, "height": 40}
    assert run("canvas-size", project, "--width", 60, "--anchor", "left") == {"width": 60, "height": 40}
    assert near(sample(project, 5, 5), (255, 0, 0, 255)) and sample(project, 55, 5)[3] == 0
    assert "--anchor" in refused("canvas-size", project, "--width", 10, "--anchor", "middle")


@test
def renders_and_exports_write_files_of_the_right_size(folder):
    project = os.path.join(folder, "out.comp")
    run("new", project, "--width", 100, "--height", 50)
    run("add-layer", project, os.path.join(folder, "gray.png"))
    view = run("render", project, "--out", os.path.join(folder, "view.png"), "--max-size", 40)
    assert (view["width"], view["height"]) == (40, 20)
    region = run("render", project, "--out", os.path.join(folder, "region.png"), "--region", "10,10,30,20")
    assert (region["width"], region["height"]) == (30, 20)
    for name in ["full.png", "full.jpg"]:
        run("export", project, "--out", os.path.join(folder, name), "--quality", 80)
        assert os.path.getsize(os.path.join(folder, name)) > 100
    assert ".tiff or .tga" in refused("export", project, "--out", os.path.join(folder, "full.gif"))
    assert "outside" in refused("sample", project, "--at", "500,500")


@test
def cropping_keeps_pixels_and_finds_the_content(folder):
    project = os.path.join(folder, "crop.comp")
    run("new", project, "--width", 100, "--height", 100)
    run("add-layer", project, os.path.join(folder, "red.png"), "--name", "Red", "--x", 50, "--y", 20)
    assert run("crop", project, "--to-content", "--padding", 5) == {"x": 45, "y": 15, "width": 50, "height": 50}
    assert near(sample(project, 5, 5), (255, 0, 0, 255)) and sample(project, 2, 2)[3] == 0
    assert run("crop", project, "--box", "5,5,20,10") == {"x": 5, "y": 5, "width": 20, "height": 10}
    assert near(sample(project, 0, 0), (255, 0, 0, 255))
    run("canvas-size", project, "--width", 60, "--height", 60, "--anchor", "top-left")
    assert near(sample(project, 35, 30), (255, 0, 0, 255)), "growing the canvas brings back what the crop hid"
    assert "--box" in refused("crop", project)
    blank = os.path.join(folder, "blank.comp")
    run("new", blank, "--width", 10, "--height", 10)
    assert "transparent" in refused("crop", blank, "--to-content")


@test
def a_cutout_is_one_step_from_photo_to_cropped_subject(folder):
    photo = "/Library/User Pictures/Animals/Eagle.heic"
    if not os.path.exists(photo):
        return
    output = os.path.join(folder, "eagle.png"), os.path.join(folder, "eagle.comp")
    result = run("cutout", photo, "--out", output[0], "--padding", 4, "--project", output[1])
    assert result["from"] == {"width": 512, "height": 512} and result["width"] <= 512 and result["height"] <= 512
    assert os.path.getsize(output[0]) > 1000
    assert [layer["mask"] for layer in layers(output[1]) if layer["name"] == "Photo"] == ["enabled"]
    assert sample(output[1], 0, 0)[3] == 0, "the corner is background, hidden behind the mask"
    assert ".png" in refused("cutout", photo, "--out", os.path.join(folder, "eagle.jpg"))
    assert "subject" in refused("cutout", os.path.join(folder, "gray.png"), "--out", os.path.join(folder, "flat.png")).lower()


@test
def a_layer_with_no_subject_says_so(folder):
    project = os.path.join(folder, "subject.comp")
    run("new", project, "--width", 64, "--height", 64)
    run("add-layer", project, os.path.join(folder, "gray.png"), "--name", "Flat")
    message = refused("remove-background", project, "Flat")
    assert "subject" in message.lower(), message


@test
def a_project_changed_by_someone_else_is_left_alone(folder):
    import time
    project = os.path.join(folder, "shared.comp")
    run("new", project, "--width", 40, "--height", 40)
    run("add-layer", project, os.path.join(folder, "red.png"), "--name", "Red")
    slow = subprocess.Popen([TOOL, "set-layer", project, "Red", "--opacity", "10"], text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            env={**os.environ, "COMPOSITOR_CLI_PAUSE_BEFORE_SAVE": "2"})
    time.sleep(1)
    run("set-layer", project, "Red", "--name", "Renamed elsewhere")  # stands in for a save from the app
    _, message = slow.communicate(timeout=30)
    assert slow.returncode != 0 and "agent copy" in message, message
    assert names(project) == ["Renamed elsewhere", "Layer 1"], "the other save survives"
    copy = os.path.join(folder, "shared (agent copy).comp")
    assert next(layer for layer in layers(copy) if layer["name"] == "Red")["opacity"] == 0.1, "the result is kept beside it"


def main():
    if "--no-build" not in sys.argv:
        build()
    failures = 0
    for function in tests:
        folder = tempfile.mkdtemp(prefix="compositor-cli-")
        try:
            png(os.path.join(folder, "gray.png"), 100, 100, lambda x, y: (102, 102, 102, 255))
            png(os.path.join(folder, "red.png"), 40, 40, lambda x, y: (255, 0, 0, 255))
            png(os.path.join(folder, "halves.png"), 40, 40, lambda x, y: (255,) * 4 if x >= 20 else (0, 0, 0, 255))
            png(os.path.join(folder, "split.png"), 40, 40, lambda x, y: (255,) * 4 if x >= 20 else (0, 0, 0, 255))
            function(folder)
            print(f"  pass  {function.__name__}")
        except AssertionError as error:
            failures += 1
            print(f"  FAIL  {function.__name__}: {error}")
        finally:
            shutil.rmtree(folder, ignore_errors=True)
    print(f"{len(tests) - failures} of {len(tests)} passed")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
