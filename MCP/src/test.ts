// End-to-end test: starts the real server over stdio and drives it as an MCP client would.
import assert from "node:assert/strict";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { deflateSync, crc32 } from "node:zlib";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";

const here = path.dirname(fileURLToPath(import.meta.url));

/** A plain RGBA PNG filled by `pixel(x, y)`. */
function png(width: number, height: number, pixel: (x: number, y: number) => [number, number, number, number]): Buffer {
  const rows = Buffer.alloc((width * 4 + 1) * height);
  for (let y = 0; y < height; y++) {
    for (let x = 0; x < width; x++) rows.set(pixel(x, y), y * (width * 4 + 1) + 1 + x * 4);
  }
  const chunk = (kind: string, data: Buffer) => {
    const body = Buffer.concat([Buffer.from(kind), data]);
    const length = Buffer.alloc(4); length.writeUInt32BE(data.length);
    const sum = Buffer.alloc(4); sum.writeUInt32BE(crc32(body) >>> 0);
    return Buffer.concat([length, body, sum]);
  };
  const header = Buffer.alloc(13);
  header.writeUInt32BE(width, 0); header.writeUInt32BE(height, 4); header.set([8, 6, 0, 0, 0], 8);
  return Buffer.concat([Buffer.from("\x89PNG\r\n\x1a\n", "latin1"), chunk("IHDR", header), chunk("IDAT", deflateSync(rows)), chunk("IEND", Buffer.alloc(0))]);
}

const folder = await mkdtemp(path.join(tmpdir(), "compositor-mcp-"));
// A stand-in image model: a script that writes a flat picture, so the generation tools are tested without one.
const fake = path.join(folder, "fake-model.mjs");
await writeFile(fake, `import { writeFileSync } from "node:fs"; import { deflateSync, crc32 } from "node:zlib";
const [output, width, height, red] = [process.argv[2], +process.argv[3] || 64, +process.argv[4] || 64, +process.argv[5] || 0];
const rows = Buffer.alloc((width * 4 + 1) * height);
for (let y = 0; y < height; y++) for (let x = 0; x < width; x++) rows.set([red, 200, 0, 255], y * (width * 4 + 1) + 1 + x * 4);
const chunk = (kind, data) => { const body = Buffer.concat([Buffer.from(kind), data]); const length = Buffer.alloc(4); length.writeUInt32BE(data.length); const sum = Buffer.alloc(4); sum.writeUInt32BE(crc32(body) >>> 0); return Buffer.concat([length, body, sum]); };
const header = Buffer.alloc(13); header.writeUInt32BE(width, 0); header.writeUInt32BE(height, 4); header.set([8, 6, 0, 0, 0], 8);
writeFileSync(output, Buffer.concat([Buffer.from("\\x89PNG\\r\\n\\x1a\\n", "latin1"), chunk("IHDR", header), chunk("IDAT", deflateSync(rows)), chunk("IEND", Buffer.alloc(0))]));
`.replaceAll("\\\\", "\\"));
const config = path.join(folder, "config");
await mkdir(config, { recursive: true });
await writeFile(path.join(config, "providers.json"), JSON.stringify({ current: {}, providers: {
  fake: { kind: "command", capabilities: ["generate", "edit", "upscale"], note: "test stand-in", run: {
    generate: ["node", fake, "{output}", "{width}", "{height}", "255"], edit: ["node", fake, "{output}", "48", "48", "0"], upscale: ["node", fake, "{output}", "128", "128", "0"] } },
  missing: { kind: "mflux", command: "mflux-not-installed", capabilities: ["generate"] },
} }));
const client = new Client({ name: "compositor-mcp-test", version: "0" });
await client.connect(new StdioClientTransport({ command: "node", args: [path.join(here, "index.js")], env: { ...process.env, COMPOSITOR_CONFIG: config } as Record<string, string> }));

type Content = { type: string; text?: string; data?: string; mimeType?: string };
async function call(name: string, args: Record<string, unknown>) {
  const result = await client.callTool({ name, arguments: args });
  return { failed: result.isError === true, content: result.content as Content[], data: result.structuredContent as Record<string, any> | undefined };
}

let passed = 0;
async function test(name: string, body: () => Promise<void>) {
  try { await body(); passed++; console.log(`  pass  ${name}`); }
  catch (error) { process.exitCode = 1; console.log(`  FAIL  ${name}: ${(error as Error).message}`); }
}

try {
  const project = path.join(folder, "scene.comp");
  await writeFile(path.join(folder, "gray.png"), png(64, 64, () => [102, 102, 102, 255]));
  await writeFile(path.join(folder, "red.png"), png(32, 32, () => [255, 0, 0, 255]));
  await writeFile(path.join(folder, "halves.png"), png(32, 32, (x) => (x >= 16 ? [255, 255, 255, 255] : [0, 0, 0, 255])));

  await test("every tool is listed with a description and annotations", async () => {
    const { tools } = await client.listTools();
    assert.equal(tools.length, 41);
    for (const tool of tools) {
      assert.ok(tool.name.startsWith("compositor_"), tool.name);
      assert.ok((tool.description ?? "").length > 40, `${tool.name} needs a real description`);
      assert.ok(tool.annotations, `${tool.name} needs annotations`);
    }
  });

  await test("a project is built, arranged and read back", async () => {
    const created = await call("compositor_new_project", { project, width: 64, height: 64 });
    assert.equal(created.data?.width, 64);
    await call("compositor_add_image_layer", { project, image: path.join(folder, "gray.png"), name: "Base" });
    const added = await call("compositor_add_image_layer", { project, image: path.join(folder, "red.png"), name: "Red", x: 0, y: 0, blend: "Multiply" });
    assert.match(added.data?.added, /^[0-9A-F-]{36}$/);
    const info = await call("compositor_get_info", { project });
    assert.deepEqual(info.data?.layers.map((entry: any) => entry.name), ["Red", "Base", "Layer 1"]);
    const color = await call("compositor_sample_color", { project, x: 8, y: 8 });
    assert.ok(Math.abs(color.data?.red - 102) <= 2 && color.data?.green <= 2, JSON.stringify(color.data));
  });

  await test("the canvas comes back as an image", async () => {
    const view = await call("compositor_render_view", { project, max_size: 32 });
    const image = view.content.find((part) => part.type === "image");
    assert.equal(image?.mimeType, "image/png");
    assert.equal(Buffer.from(image?.data ?? "", "base64").subarray(1, 4).toString(), "PNG");
    assert.match(view.content.find((part) => part.type === "text")?.text ?? "", /32 × 32/);
    const region = await call("compositor_render_view", { project, region: { x: 0, y: 0, width: 20, height: 10 } });
    assert.match(region.content.find((part) => part.type === "text")?.text ?? "", /20 × 10/);
  });

  await test("masks, adjustments, folders and order all go through", async () => {
    await call("compositor_set_mask", { project, layer: "Red", image: path.join(folder, "halves.png") });
    const hidden = await call("compositor_sample_color", { project, x: 4, y: 8 });
    assert.ok(Math.abs(hidden.data?.red - 102) <= 2 && Math.abs(hidden.data?.green - 102) <= 2, "the masked half shows the gray beneath");
    await call("compositor_set_mask", { project, layer: "Red", remove: true });
    await call("compositor_add_adjustment", { project, kind: "Levels", name: "Invert", output_black: 255, output_white: 0 });
    const inverted = await call("compositor_sample_color", { project, x: 40, y: 40 });
    assert.ok(Math.abs(inverted.data?.red - 153) <= 2, JSON.stringify(inverted.data));
    const group = await call("compositor_add_empty_layer", { project, kind: "folder", name: "Group" });
    await call("compositor_move_layer", { project, layer: "Red", to: "into", target: "Group" });
    const info = await call("compositor_get_info", { project });
    assert.equal(info.data?.layers.find((entry: any) => entry.name === "Red").parent, group.data?.added);
    await call("compositor_apply_filter", { project, layer: "Base", filter: "Add Noise", amount: 20, monochromatic: true });
    const resized = await call("compositor_resize", { project, mode: "image", scale: 50 });
    assert.deepEqual([resized.data?.width, resized.data?.height], [32, 32]);
    const exported = await call("compositor_export", { project, output: path.join(folder, "out.jpg"), quality: 80 });
    assert.equal(exported.data?.width, 32);
  });

  await test("crop and the one-step cutout work", async () => {
    const scene = path.join(folder, "crop.comp");
    await call("compositor_new_project", { project: scene, width: 100, height: 100 });
    await call("compositor_add_image_layer", { project: scene, image: path.join(folder, "red.png"), name: "Red", x: 40, y: 10 });
    const cropped = await call("compositor_crop", { project: scene, to_content: true, padding: 2 });
    assert.deepEqual(cropped.data, { x: 38, y: 8, width: 36, height: 36 });
    const needs = await call("compositor_crop", { project: scene });
    assert.ok(needs.failed && /box or to_content/.test(needs.content[0].text ?? ""));
    await call("compositor_apply_filter", { project: scene, layer: "Red", filter: "Offset", horizontal: 50, vertical: 50 });
    const tiles = await call("compositor_tile_preview", { project: scene, repeat: 2 });
    assert.equal(tiles.content.find((part) => part.type === "image")?.mimeType, "image/png");
    assert.match(tiles.content.find((part) => part.type === "text")?.text ?? "", /2 × 2 tiles/);
    const eagle = "/Library/User Pictures/Animals/Eagle.heic";
    const cut = await call("compositor_cutout", { image: eagle, output: path.join(folder, "eagle.png"), project: path.join(folder, "eagle.comp") });
    assert.ok(!cut.failed && cut.data?.width <= 512 && cut.data?.project, JSON.stringify(cut.data ?? cut.content));
  });

  await test("a texture goes from layer to packed engine maps", async () => {
    const texture = path.join(folder, "texture.comp");
    await writeFile(path.join(folder, "lit.png"), png(64, 64, (x, y) => { const v = 60 + x * 2 + ((x * 7 + y * 13) % 23); return [v, v, v, 255]; }));
    await call("compositor_new_project", { project: texture, width: 64, height: 64 });
    await call("compositor_add_image_layer", { project: texture, image: path.join(folder, "lit.png"), name: "Stone" });
    const tiled = await call("compositor_make_tileable", { project: texture, layer: "Stone", method: "patch", band: 14, lighting: 100 });
    assert.ok(!tiled.failed, JSON.stringify(tiled.content));
    const left = await call("compositor_sample_color", { project: texture, x: 0, y: 30 }), right = await call("compositor_sample_color", { project: texture, x: 63, y: 30 });
    assert.ok(Math.abs(left.data?.red - right.data?.red) < 40, `edges ${left.data?.red} and ${right.data?.red}`);
    await call("compositor_apply_filter", { project: texture, layer: "Stone", filter: "Gaussian Blur", radius: 2, keep_edges: true });
    assert.equal((await call("compositor_sample_color", { project: texture, x: 0, y: 0 })).data?.alpha, 255);
    const maps = await call("compositor_derive_maps", { project: texture, out_dir: path.join(folder, "set"), name: "stone" });
    assert.deepEqual(Object.keys(maps.data?.maps).sort(), ["albedo", "ao", "height", "normal", "roughness"]);
    const packed = await call("compositor_pack_channels", { output: path.join(folder, "set", "stone_orm.png"), layout: "orm", ao: maps.data?.maps.ao, roughness: maps.data?.maps.roughness });
    assert.deepEqual(packed.data?.channels, { red: "stone_ao.png", green: "stone_roughness.png" });
    const normal = await call("compositor_heightmap_normal", { heightmap: maps.data?.maps.height, output: path.join(folder, "set", "stone_n.png"), no_wrap: true });
    assert.equal(normal.data?.width, 64);
    const tga = await call("compositor_export", { project: texture, output: path.join(folder, "set", "stone.tga"), bleed: 8 });
    assert.ok(!tga.failed);
  });

  await test("image providers are pluggable, and none is a built-in default", async () => {
    const listed = await call("compositor_list_providers", {});
    const byName = Object.fromEntries(listed.data?.providers.map((entry: any) => [entry.name, entry]));
    assert.equal(byName.fake.available, true);
    assert.ok(byName.missing.available === false && /not found/.test(byName.missing.problem));
    assert.deepEqual(listed.data?.current, {});
    const scene = path.join(folder, "generated.comp");
    const unnamed = await call("compositor_generate_image", { prompt: "mossy stone wall", project: scene, width: 256, height: 256 });
    assert.ok(unnamed.failed && /Nothing is built in as a default/.test(unnamed.content[0].text ?? ""), unnamed.content[0].text);
    const made = await call("compositor_generate_image", { prompt: "mossy stone wall", project: scene, width: 256, height: 256, provider: "fake", seed: 7 });
    assert.ok(!made.failed && made.data?.seed === 7 && made.data?.provider === "fake", JSON.stringify(made.content));
    assert.equal((await call("compositor_sample_color", { project: scene, x: 30, y: 30 })).data?.red, 255);
    await call("compositor_set_current_provider", { capability: "edit", provider: "fake" });
    const filled = await call("compositor_generative_fill", { project: scene, region: { x: 64, y: 64, width: 128, height: 128 }, instruction: "plain grass", context: 32, feather: 16 });
    assert.ok(!filled.failed, JSON.stringify(filled.content));
    assert.deepEqual(filled.data?.area, { x: 32, y: 32, width: 192, height: 192 });
    assert.equal((await call("compositor_sample_color", { project: scene, x: 128, y: 128 })).data?.red, 0, "the middle of the area is the new layer");
    assert.equal((await call("compositor_sample_color", { project: scene, x: 40, y: 40 })).data?.red, 255, "the context around it is masked away");
    const surface = path.join(folder, "surface.comp");
    await call("compositor_generate_image", { prompt: "cobblestones", project: surface, width: 256, height: 256, provider: "fake", layer_name: "Cobble" });
    const healed = await call("compositor_make_tileable", { project: surface, layer: "Cobble", method: "model" });
    assert.ok(!healed.failed && healed.data?.method === "model", JSON.stringify(healed.content));
    const after = await call("compositor_get_info", { project: surface });
    assert.deepEqual(after.data?.layers.map((entry: any) => [entry.name, entry.visible]).slice(0, 2), [["Cobble (tileable)", true], ["Cobble", false]]);
    // The stand-in model paints green-black (red 0); only the cross over the seams, slid back to the edges, takes it.
    assert.equal((await call("compositor_sample_color", { project: surface, x: 1, y: 100 })).data?.red, 0, "the repaired band ends up at the tile's edges");
    assert.equal((await call("compositor_sample_color", { project: surface, x: 128, y: 128 })).data?.red, 255, "the middle of the tile is untouched");
    const edited = await call("compositor_edit_image", { project: scene, instruction: "make it autumn" });
    assert.ok(!edited.failed && edited.data?.layer);
    const bigger = await call("compositor_upscale_image", { image: path.join(folder, "red.png"), output: path.join(folder, "big.png"), provider: "fake" });
    assert.ok(!bigger.failed);
    const log = (await readFile(path.join(config, "generations.jsonl"), "utf8")).trim().split("\n").map((line) => JSON.parse(line));
    assert.deepEqual(log.map((entry) => entry.capability), ["generate", "edit", "generate", "edit", "edit", "upscale"]);
    assert.ok(log[0].prompt === "mossy stone wall" && log[0].seed === 7);
  });

  await test("text, the newer blend modes and the newer adjustments go through", async () => {
    const card = path.join(folder, "card.comp");
    await call("compositor_new_project", { project: card, width: 300, height: 120 });
    await call("compositor_add_image_layer", { project: card, image: path.join(folder, "gray.png"), name: "Base", width: 300, height: 120, x: 0, y: 0 });
    const added = await call("compositor_add_text", { project: card, text: "Ruins", size: 40, color: { red: 255, green: 0, blue: 0 }, align: "center", blend: "Linear Dodge (Add)" });
    assert.ok(!added.failed, JSON.stringify(added.content));
    await call("compositor_set_text", { project: card, layer: "Ruins", text: "The Ruins", size: 30 });
    const info = await call("compositor_get_info", { project: card });
    const title = info.data?.layers[0];
    assert.ok(title.kind === "text" && title.text === "The Ruins" && title.fontSize === 30 && title.blendMode === "Linear Dodge (Add)", JSON.stringify(title));
    const glow = await call("compositor_add_layer_effect", { project: card, layer: "The Ruins", effect: "glow", size: 10, color: { red: 255, green: 255, blue: 0 } });
    assert.ok(!glow.failed && glow.data?.effect === "Outer Glow", JSON.stringify(glow.content));
    const mono = await call("compositor_add_adjustment", { project: card, kind: "Black & White", reds: 100, greens: 0, blues: 0 });
    assert.ok(!mono.failed, JSON.stringify(mono.content));
    const toned = await call("compositor_add_adjustment", { project: card, kind: "Color Balance", midtones: { red: 60, green: 0, blue: -40 } });
    assert.ok(!toned.failed, JSON.stringify(toned.content));
  });

  await test("saved actions replay, and non-Photoshop files are refused", async () => {
    const wall = path.join(folder, "wall.comp"), action = path.join(folder, "soften.json");
    await call("compositor_new_project", { project: wall, width: 64, height: 64 });
    await call("compositor_add_image_layer", { project: wall, image: path.join(folder, "gray.png"), name: "Wall" });
    await writeFile(action, JSON.stringify({ name: "Soften", steps: [["filter", "{project}", "{layer}", "Gaussian Blur", "--radius", "2", "--keep-edges"], ["export", "{project}", "--out", "{folder}/{name}_soft.png"]] }));
    const planned = await call("compositor_run_action", { action, project: wall, values: { layer: "Wall" }, dry_run: true });
    assert.equal(planned.data?.steps.length, 2);
    const ran = await call("compositor_run_action", { action, project: wall, values: { layer: "Wall" } });
    assert.ok(!ran.failed && ran.data?.action === "Soften", JSON.stringify(ran.content));
    const notPSD = await call("compositor_import_psd", { psd: path.join(folder, "gray.png"), project: path.join(folder, "x.comp") });
    assert.ok(notPSD.failed && /not a Photoshop document/.test(notPSD.content[0].text ?? ""));
  });

  await test("live tools say how to switch control on when the app is not listening", async () => {
    const status = await call("compositor_live_status", {});
    // With the app closed this must fail helpfully; with it open and control on, it answers.
    assert.ok(status.failed ? /Allow Assistant Control/.test(status.content[0].text ?? "") : status.data?.open !== undefined);
  });

  await test("mistakes come back as errors that say what to do", async () => {
    const missing = await call("compositor_set_layer", { project, layer: "Nope", opacity: 50 });
    assert.ok(missing.failed && /no layer/.test(missing.content[0].text ?? ""));
    const target = await call("compositor_move_layer", { project, layer: "Red", to: "above" });
    assert.ok(target.failed && /needs a target/.test(target.content[0].text ?? ""));
    const exists = await call("compositor_new_project", { project, width: 8, height: 8 });
    assert.ok(exists.failed && /overwrite/.test(exists.content[0].text ?? ""));
    const subject = await call("compositor_remove_background", { project, layer: "Base" });
    assert.ok(subject.failed && /subject/i.test(subject.content[0].text ?? ""));
  });

  console.log(`${passed} of 11 passed`);
} finally {
  await client.close();
  await rm(folder, { recursive: true, force: true });
}
