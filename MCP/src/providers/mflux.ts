import type { Adapter, ProviderConfig } from "./types.js";
import { findExecutable, runTool } from "./run.js";

/** mflux: MLX-native local models on Apple silicon. Install with `uv tool install --upgrade mflux`. */
function shared(config: ProviderConfig): string[] {
  return [
    ...(config.model ? ["--model", config.model] : []),
    ...(config.quantize ? ["--quantize", String(config.quantize)] : []),
    ...(config.steps ? ["--steps", String(config.steps)] : []),
    ...(config.guidance !== undefined ? ["--guidance", String(config.guidance)] : []),
    ...(config.extraArgs ?? []),
  ];
}

async function executable(config: ProviderConfig): Promise<string> {
  const found = await findExecutable(config.command ?? "mflux-generate");
  if (!found) throw new Error(`${config.command} is not installed; run: uv tool install --upgrade mflux`);
  return found;
}

export const mflux: Adapter = {
  async unavailable(config) {
    return (await findExecutable(config.command ?? "mflux-generate")) ? null : `${config.command} not found (install: uv tool install --upgrade mflux)`;
  },
  async generate(config, request) {
    await runTool(await executable(config), [...shared(config), "--prompt", request.prompt, "--width", String(request.width),
      "--height", String(request.height), ...(request.seed !== undefined ? ["--seed", String(request.seed)] : []),
      "--no-metadata", "--output", request.output]);
  },
  async edit(config, request) {
    await runTool(await executable(config), [...shared(config), "--image-paths", request.image, "--prompt", request.instruction,
      ...(request.seed !== undefined ? ["--seed", String(request.seed)] : []), "--no-metadata", "--output", request.output]);
  },
  async upscale(config, request) {
    // SeedVR2 takes steps and guidance from its own defaults.
    await runTool(await executable(config), [...(config.model ? ["--model", config.model] : []),
      ...(config.quantize ? ["--quantize", String(config.quantize)] : []), ...(config.extraArgs ?? []),
      "--image-path", request.image, "--resolution", `${request.scale}x`, "--output", request.output]);
  },
};
