import { execFile } from "node:child_process";
import { access, constants } from "node:fs/promises";
import { homedir } from "node:os";
import path from "node:path";

/** Where uv, pipx and Homebrew put executables, since an MCP server is not started from a login shell. */
const EXTRA_PATHS = [path.join(homedir(), ".local/bin"), "/opt/homebrew/bin", "/usr/local/bin"];

export async function findExecutable(name: string): Promise<string | null> {
  const candidates = name.includes("/") ? [name] : [...(process.env.PATH ?? "").split(":"), ...EXTRA_PATHS].map((folder) => path.join(folder, name));
  for (const candidate of candidates) {
    try { await access(candidate, constants.X_OK); return candidate; } catch { /* keep looking */ }
  }
  return null;
}

/** Runs a generation command to completion. Local models can take minutes, and the first run downloads weights. */
export function runTool(executable: string, args: string[], timeoutMinutes = 60): Promise<void> {
  return new Promise((resolve, reject) => {
    execFile(executable, args, {
      maxBuffer: 64 * 1024 * 1024, timeout: timeoutMinutes * 60 * 1000,
      env: { ...process.env, PATH: [process.env.PATH, ...EXTRA_PATHS].filter(Boolean).join(":") },
    }, (error, _stdout, stderr) => {
      if (!error) { resolve(); return; }
      const tail = stderr.trim().split("\n").slice(-6).join("\n");
      reject(new Error(`${path.basename(executable)} failed: ${tail || error.message}`));
    });
  });
}
