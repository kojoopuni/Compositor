import { existsSync } from "node:fs";
import { appendFile, mkdir, readFile, stat, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { command } from "./command.js";
import { gemini } from "./gemini.js";
import { mflux } from "./mflux.js";
import type { Adapter, Capability, EditRequest, GenerateRequest, ProviderResult, ProvidersFile, UpscaleRequest } from "./types.js";

const adapters: Record<string, Adapter> = { mflux, gemini, command };
const here = path.dirname(fileURLToPath(import.meta.url));

/** The user's own file, outside the repository: their choices and nothing secret (keys stay in the environment). */
export const configFolder = process.env.COMPOSITOR_CONFIG ?? path.join(homedir(), ".config", "compositor");
export const configPath = path.join(configFolder, "providers.json");

export async function loadProviders(): Promise<ProvidersFile> {
  if (!existsSync(configPath)) {
    await mkdir(configFolder, { recursive: true });
    await writeFile(configPath, await readFile(path.resolve(here, "../../providers.example.json")));
  }
  const file = JSON.parse(await readFile(configPath, "utf8")) as ProvidersFile;
  return { current: file.current ?? {}, providers: file.providers ?? {} };
}

export async function setCurrent(capability: Capability, name: string | null): Promise<ProvidersFile> {
  const file = await loadProviders();
  if (name === null) delete file.current[capability];
  else {
    const config = file.providers[name];
    if (!config) throw new Error(`there is no provider named '${name}'; see compositor_list_providers`);
    if (!config.capabilities.includes(capability)) throw new Error(`'${name}' cannot ${capability}`);
    file.current[capability] = name;
  }
  await writeFile(configPath, JSON.stringify(file, null, 2) + "\n");
  return file;
}

export async function describeProviders() {
  const file = await loadProviders();
  const providers = await Promise.all(Object.entries(file.providers).map(async ([name, config]) => {
    const problem = await (adapters[config.kind]?.unavailable(config) ?? Promise.resolve(`unknown kind '${config.kind}'`));
    return { name, kind: config.kind, model: config.model, capabilities: config.capabilities, note: config.note, available: problem === null, ...(problem ? { problem } : {}) };
  }));
  return { config: configPath, current: file.current, providers };
}

async function pick(capability: Capability, requested?: string) {
  const file = await loadProviders();
  const name = requested ?? file.current[capability];
  if (!name) {
    const able = Object.entries(file.providers).filter(([, config]) => config.capabilities.includes(capability)).map(([key]) => key);
    throw new Error(`no provider was named and none is set as current for '${capability}'. Pass provider (one of: ${able.join(", ") || "none configured"}), ` +
      `or choose one with compositor_set_current_provider. Nothing is built in as a default, by design.`);
  }
  const config = file.providers[name];
  if (!config) throw new Error(`there is no provider named '${name}'; see compositor_list_providers`);
  if (!config.capabilities.includes(capability)) throw new Error(`'${name}' cannot ${capability}`);
  const adapter = adapters[config.kind];
  if (!adapter) throw new Error(`'${name}' has an unknown kind '${config.kind}'`);
  const problem = await adapter.unavailable(config);
  if (problem) throw new Error(`'${name}' cannot run: ${problem}`);
  return { name, config, adapter };
}

async function finish(name: string, model: string | undefined, output: string, started: number, record: Record<string, unknown>): Promise<ProviderResult> {
  const written = await stat(output).catch(() => null);
  if (!written?.size) throw new Error(`'${name}' finished without writing ${output}`);
  const seconds = Math.round((Date.now() - started) / 100) / 10;
  // A record of how every result was made, so it can be made again.
  await appendFile(path.join(configFolder, "generations.jsonl"), JSON.stringify({ at: new Date().toISOString(), provider: name, model, seconds, output, ...record }) + "\n").catch(() => {});
  return { output, provider: name, model, seconds, seed: record.seed as number | undefined };
}

export async function generate(request: GenerateRequest, provider?: string): Promise<ProviderResult> {
  const { name, config, adapter } = await pick("generate", provider);
  if (!adapter.generate) throw new Error(`'${name}' cannot generate`);
  const started = Date.now();
  await adapter.generate(config, request);
  return finish(name, config.model, request.output, started, { capability: "generate", prompt: request.prompt, width: request.width, height: request.height, seed: request.seed });
}

export async function edit(request: EditRequest, provider?: string): Promise<ProviderResult> {
  const { name, config, adapter } = await pick("edit", provider);
  if (!adapter.edit) throw new Error(`'${name}' cannot edit`);
  const started = Date.now();
  await adapter.edit(config, request);
  return finish(name, config.model, request.output, started, { capability: "edit", instruction: request.instruction, image: request.image, seed: request.seed });
}

export async function upscale(request: UpscaleRequest, provider?: string): Promise<ProviderResult> {
  const { name, config, adapter } = await pick("upscale", provider);
  if (!adapter.upscale) throw new Error(`'${name}' cannot upscale`);
  const started = Date.now();
  await adapter.upscale(config, request);
  return finish(name, config.model, request.output, started, { capability: "upscale", image: request.image, scale: request.scale });
}
