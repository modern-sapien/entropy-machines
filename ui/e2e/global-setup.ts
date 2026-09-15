// global-setup.ts — builds the real environment the e2e suite runs against:
// a brand-new project, onboarded through the actual entry points a user
// runs (bin/init, bin/serve), not a mocked API or a hand-built sqlite file.
// bin/init now handles everything: writes config.json, copies PRD-001,
// registers it in manifest.json, and runs migrate-db. This setup just
// inits and serves.
import { execFileSync, spawn, type ChildProcess } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));

// ui/e2e -> ui -> repo root (bin/, lib/, ui/ all live here).
export const WORKTREE_ROOT = join(__dirname, "..", "..");
const PORT = process.env.PW_PORT!;

// The doc this suite seeds and asserts against everywhere — see
// onboarding.spec.ts, which is the priority test this whole fixture exists
// for.
export const DOC_SLUG = "PRD-001-orientation";
export const RESPONSE_KEY = "prd001-q1-suites";

function run(cmd: string, args: string[], cwd: string): string {
  try {
    return execFileSync(cmd, args, { cwd, encoding: "utf8", stdio: "pipe" });
  } catch (err) {
    const e = err as { stdout?: string; stderr?: string; message: string };
    throw new Error(
      `global-setup: command failed: ${cmd} ${args.join(" ")} (cwd=${cwd})\n` +
        `--- stdout ---\n${e.stdout ?? ""}\n--- stderr ---\n${e.stderr ?? e.message}`,
    );
  }
}

function waitForLine(
  proc: ChildProcess,
  needle: string,
  timeoutMs: number,
): Promise<string> {
  return new Promise((resolve, reject) => {
    let buf = "";
    const timer = setTimeout(() => {
      reject(
        new Error(
          `global-setup: bin/serve never printed ${JSON.stringify(needle)} within ${timeoutMs}ms.\n` +
            `--- output so far ---\n${buf}`,
        ),
      );
    }, timeoutMs);
    function onData(chunk: Buffer) {
      buf += chunk.toString();
      if (buf.includes(needle)) {
        clearTimeout(timer);
        proc.stdout?.off("data", onData);
        proc.stderr?.off("data", onData);
        resolve(buf);
      }
    }
    proc.stdout?.on("data", onData);
    proc.stderr?.on("data", onData);
    proc.once("exit", (code) => {
      if (!buf.includes(needle)) {
        clearTimeout(timer);
        reject(
          new Error(
            `global-setup: bin/serve exited early (code ${code}) before printing ${JSON.stringify(needle)}.\n` +
              `--- output ---\n${buf}`,
          ),
        );
      }
    });
  });
}

export default async function globalSetup() {
  // ---- a brand-new project, the way a real user starts one -----------------
  const project = mkdtempSync(join(tmpdir(), "entropy-e2e-"));
  run("git", ["init", "-q"], project);
  run("git", ["config", "user.email", "e2e@entropy.invalid"], project);
  run("git", ["config", "user.name", "entropy e2e"], project);
  run("git", ["config", "commit.gpgsign", "false"], project);

  // ---- the real onboarding entry point --------------------------------------
  // Run from the worktree's own bin/ against the temp project as an
  // "external path" install (see bin/init's own comment on that layout) —
  // no vendoring needed, this just proves bin/init works against a foreign
  // project root the way a real `entropy-machines init` does after npm
  // install.
  run(join(WORKTREE_ROOT, "bin", "init"), [], project);

  // ---- bin/serve, exactly as a user runs it, against the real ui/dist/ ------
  const logLines: string[] = [];
  const server = spawn(join(WORKTREE_ROOT, "bin", "serve"), ["--no-open", PORT], {
    cwd: project,
    stdio: ["ignore", "pipe", "pipe"],
  });
  server.stdout?.on("data", (c) => logLines.push(c.toString()));
  server.stderr?.on("data", (c) => logLines.push(c.toString()));

  try {
    await waitForLine(server, `http://localhost:${PORT}`, 15_000);
  } catch (err) {
    server.kill();
    throw err;
  }

  // Sanity-check: bin/serve prints which SPA root it found. If ui/dist/ was
  // never built, every non-API route below would silently 404 and the whole
  // suite would fail confusingly at the first page.goto(). Fail loudly here
  // instead, with the fix.
  const combined = logLines.join("");
  if (!combined.includes("spa:") || combined.includes("spa: not found")) {
    server.kill();
    throw new Error(
      "global-setup: bin/serve could not find ui/dist/ — run `npm run build` in ui/ first.\n" +
        `--- serve output ---\n${combined}`,
    );
  }

  // ---- teardown --------------------------------------------------------------
  return async () => {
    server.kill();
    await new Promise<void>((resolve) => {
      if (server.exitCode !== null || server.signalCode !== null) {
        resolve();
        return;
      }
      server.once("exit", () => resolve());
      // Don't hang teardown forever on a stuck process.
      setTimeout(resolve, 3_000);
    });
    try {
      rmSync(project, { recursive: true, force: true });
    } catch {
      // best-effort cleanup — a leftover temp dir is not worth failing the run over
    }
  };
}
