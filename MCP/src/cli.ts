import { execFile } from "node:child_process";
import { existsSync } from "node:fs";
import { homedir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { liveInfo } from "./live.js";

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

/** Commands that rewrite the project named by their first argument. */
const REWRITES = new Set(["add-layer", "add-blank-layer", "add-folder", "set-layer", "move-layer", "delete-layer", "set-mask",
  "remove-background", "filter", "add-adjustment", "resize", "canvas-size", "crop", "make-tileable"]);

/** Runs one command and returns its JSON. A failure carries the tool's own message, which says what to change. */
export async function run(command: string, args: string[]): Promise<Record<string, unknown>> {
  if (REWRITES.has(command) && args[0]) {
    const open = await liveInfo();
    if (open?.unsavedChanges === true && typeof open.project === "string" && path.resolve(open.project) === path.resolve(args[0])) {
      throw new Error(`${path.basename(args[0])} is open in the Compositor app with unsaved changes, so editing the file would ` +
        "lose one side's work. Ask the user to save it, or work on it live with the compositor_live_ tools.");
    }
  }
  return execute(command, args);
}

function execute(command: string, args: string[]): Promise<Record<string, unknown>> {
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
