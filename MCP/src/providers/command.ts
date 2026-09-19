import type { Adapter, Capability, ProviderConfig } from "./types.js";
import { findExecutable, runTool } from "./run.js";

/**
 * Any scriptable tool: Draw Things' CLI, a ComfyUI workflow script, a model of your own. `run` gives the argument list
 * per capability, the executable first, with {prompt} {width} {height} {seed} {image} {output} {scale} filled in.
 */
async function go(config: ProviderConfig, capability: Capability, values: Record<string, string | number | undefined>): Promise<void> {
  const template = config.run?.[capability];
  if (!template?.length) throw new Error(`this provider has no '${capability}' command in providers.json`);
  const [name, ...args] = template.map((word) => word.replace(/\{(\w+)\}/g, (_, field: string) => String(values[field] ?? "")));
  const found = await findExecutable(name);
  if (!found) throw new Error(`${name} was not found`);
  await runTool(found, [...args, ...(config.extraArgs ?? [])]);
}

export const command: Adapter = {
  async unavailable(config) {
    const names = Object.values(config.run ?? {}).map((template) => template?.[0]).filter((name): name is string => Boolean(name));
    if (!names.length) return "no commands are configured";
    for (const name of names) if (!(await findExecutable(name))) return `${name} not found`;
    return null;
  },
  generate: (config, request) => go(config, "generate", { ...request, seed: request.seed ?? 0 }),
  edit: (config, request) => go(config, "edit", { ...request, prompt: request.instruction, seed: request.seed ?? 0 }),
  upscale: (config, request) => go(config, "upscale", { ...request }),
};
