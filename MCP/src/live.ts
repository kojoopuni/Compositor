import { existsSync } from "node:fs";
import { readFile } from "node:fs/promises";
import net from "node:net";
import { homedir } from "node:os";
import path from "node:path";

/** The running app leaves its port and token in its own container; the fork's build and upstream's have different ones. */
const BUNDLES = ["com.opuniverse.compositor-fork", "com.wonderassembly.compositor"];

interface Handoff { port: number; token: string; pid: number; app: string }

async function handoff(): Promise<Handoff | null> {
  for (const bundle of BUNDLES) {
    const file = path.join(homedir(), "Library/Containers", bundle, "Data/Library/Application Support/Compositor/control.json");
    if (!existsSync(file)) continue;
    try {
      const found = JSON.parse(await readFile(file, "utf8")) as Handoff;
      // A file left behind by an app that has quit.
      try { process.kill(found.pid, 0); } catch { continue; }
      return found;
    } catch { /* unreadable: try the next */ }
  }
  return null;
}

/** One request to the running app. Rejects with the app's own message, or with how to switch live control on. */
export async function live(command: string, args: Record<string, unknown> = {}): Promise<Record<string, unknown>> {
  const target = await handoff();
  if (!target) {
    throw new Error("the Compositor app is not accepting control. Ask the user to open Compositor Fork and switch on " +
      "Compositor > Allow Assistant Control. Until then, work on project files with the other compositor tools.");
  }
  return new Promise((resolve, reject) => {
    const socket = net.createConnection({ host: "127.0.0.1", port: target.port });
    let buffer = "";
    socket.setTimeout(10 * 60 * 1000, () => { socket.destroy(); reject(new Error("the app did not answer in time")); });
    socket.on("connect", () => socket.write(JSON.stringify({ token: target.token, command, arguments: args }) + "\n"));
    socket.on("data", (chunk) => {
      buffer += chunk.toString("utf8");
      const newline = buffer.indexOf("\n");
      if (newline < 0) return;
      socket.end();
      try {
        const reply = JSON.parse(buffer.slice(0, newline)) as { ok: boolean; result?: Record<string, unknown>; error?: string };
        if (reply.ok) resolve(reply.result ?? {}); else reject(new Error(reply.error ?? "the app refused the request"));
      } catch { reject(new Error("the app's reply could not be read")); }
    });
    socket.on("error", (error) => reject(new Error(`could not reach the app: ${error.message}`)));
  });
}

/** The front tab's state if the app is running with control on, else null. Never throws. */
export async function liveInfo(): Promise<Record<string, unknown> | null> {
  try { return await live("info"); } catch { return null; }
}
