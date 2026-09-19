import { execFile } from "node:child_process";
import { existsSync } from "node:fs";
import { homedir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));

/** The compositor-cli binary: COMPOSITOR_CLI if set, else the Release or Debug build beside this server. */
export function toolPath(): string {
  const candidates = [
    process.env.COMPOSITOR_CLI,
    path.resolve(here, "../../CLI/build/Release/compositor-cli"),
    path.resolve(here, "../../CLI/build/Debug/compositor-cli"),
  ].filter((candidate): candidate is string => Boolean(candidate));
  const found = candidates.find((candidate) => existsSync(candidate));
  if (!found) {
    throw new Error(
      "compositor-cli was not found. Build it with `python3 CLI/Tests/run.py` in the Compositor repository, " +
        "or set COMPOSITOR_CLI to its full path.",
    );
  }
  return found;
}

/** `~` expanded and the path made absolute, since the server's working directory is not the user's. */
export function resolvePath(input: string): string {
  const expanded = input === "~" || input.startsWith("~/") ? path.join(homedir(), input.slice(1)) : input;
  return path.resolve(expanded);
}

export type Option = string | number | boolean | undefined;

/**
 * Turns named values into `--name value` arguments. `true` becomes a bare flag only for names listed in `flags`;
 * other booleans are passed as the words true and false, which is what the tool's on/off options read.
 */
export function options(values: Record<string, Option>, flags: string[] = []): string[] {
  const result: string[] = [];
  for (const [name, value] of Object.entries(values)) {
    if (value === undefined) continue;
    if (flags.includes(name)) {
      if (value === true) result.push(`--${name}`);
    } else {
      result.push(`--${name}`, String(value));
    }
  }
  return result;
}

/** Runs one command and returns its JSON. A failure carries the tool's own message, which says what to change. */
export function run(command: string, args: string[]): Promise<Record<string, unknown>> {
  return new Promise((resolve, reject) => {
    execFile(toolPath(), [command, ...args], { maxBuffer: 64 * 1024 * 1024, timeout: 10 * 60 * 1000 }, (error, stdout, stderr) => {
      if (error) {
        const message = stderr.trim().replace(/^error:\s*/, "") || error.message;
        reject(new Error(message));
        return;
      }
      try {
        resolve(JSON.parse(stdout) as Record<string, unknown>);
      } catch {
        reject(new Error(`compositor-cli ${command} returned something that is not JSON: ${stdout.slice(0, 200)}`));
      }
    });
  });
}
