/** What a provider can be asked to do. */
export type Capability = "generate" | "edit" | "upscale";

/** One entry in providers.json. Every entry is equal: none is built in as the default. */
export interface ProviderConfig {
  /** Which adapter runs it: mflux (local, MLX), gemini (cloud), or command (anything scriptable). */
  kind: "mflux" | "gemini" | "command";
  capabilities: Capability[];
  /** A line for whoever is choosing: what it is good at, how fast, what license its output carries. */
  note?: string;
  /** mflux: the executable, e.g. mflux-generate-flux2. gemini: unused. command: unused (see `run`). */
  command?: string;
  /** mflux and gemini: the model name. */
  model?: string;
  /** mflux: weight quantization, 3–8 bits; omit for full precision. */
  quantize?: number;
  steps?: number;
  guidance?: number;
  /** gemini: the environment variable holding the API key. */
  apiKeyEnv?: string;
  /** command: argument lists per capability, with {prompt} {width} {height} {seed} {image} {output} {scale} filled in. */
  run?: Partial<Record<Capability, string[]>>;
  /** Extra arguments appended as they are. */
  extraArgs?: string[];
}

export interface ProvidersFile {
  /** The provider used when a request names none, per capability. Empty until the user chooses. */
  current: Partial<Record<Capability, string>>;
  providers: Record<string, ProviderConfig>;
}

export interface GenerateRequest { prompt: string; width: number; height: number; seed?: number; output: string }
export interface EditRequest { image: string; instruction: string; seed?: number; output: string }
export interface UpscaleRequest { image: string; scale: number; output: string }

export interface ProviderResult { output: string; provider: string; model?: string; seconds: number; seed?: number }

export interface Adapter {
  /** Why this provider cannot run right now (missing executable, missing key), or null when it can. */
  unavailable(config: ProviderConfig): Promise<string | null>;
  generate?(config: ProviderConfig, request: GenerateRequest): Promise<void>;
  edit?(config: ProviderConfig, request: EditRequest): Promise<void>;
  upscale?(config: ProviderConfig, request: UpscaleRequest): Promise<void>;
}
