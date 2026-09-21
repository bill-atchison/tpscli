// One exe call, one result. Spawns tpscli.exe with no shell, collects its output under a byte
// ceiling and a wall-clock limit, and decides whether what came back is a response at all.
// The statement travels on stdin, not argv: Windows serialises argv into one command line that
// the exe re-splits, which mangles a `"` inside a literal and caps the line at 32 K; flags stay argv.
import { spawn, type ChildProcess } from 'node:child_process';

export interface RunFailure {
  kind: 'spawn' | 'timeout' | 'output_limit' | 'kill_failed';
  message: string;
  pid?: number;
}

export interface RunResult {
  exitCode: number | null;
  stdout: string;
  stderr: string;
  json: Record<string, unknown> | null;
  durationMs: number;
  timedOut: boolean;
  failure?: RunFailure;
}

export interface RunOptions {
  timeoutMs: number;
  table?: boolean;          // --table output is a grid, never parsed
  stdin?: string;           // the statement text; absent means stdin stays closed
}

export type Run = (file: string, args: string[], opts: RunOptions) => Promise<RunResult>;

export const OUTPUT_LIMIT = 64 * 1024 * 1024;
const KILL_DEADLINE_MS = 5000;

// A response is one JSON object, complete, whose ok agrees with the exit code. Anything else is
// not a response and the caller reports INCOMPLETE rather than guessing at a write's outcome.
export function parseResponse(stdout: string, exitCode: number | null): Record<string, unknown> | null {
  let value: unknown;
  try {
    value = JSON.parse(stdout.trim());
  } catch {
    return null;
  }
  if (typeof value !== 'object' || value === null || Array.isArray(value)) return null;
  const obj = value as Record<string, unknown>;
  if (obj.complete !== true || obj.ok !== (exitCode === 0)) return null;
  return obj;
}

export const run: Run = (file, args, opts) => new Promise(resolve => {
  const started = Date.now();
  const out: Buffer[] = [];
  const err: Buffer[] = [];
  let bytes = 0;
  let settled = false;
  let timedOut = false;
  let failure: RunFailure | undefined;
  let timer: NodeJS.Timeout | undefined;
  let killTimer: NodeJS.Timeout | undefined;
  let child: ChildProcess;

  const finish = (exitCode: number | null) => {
    if (settled) return;
    settled = true;
    if (timer) clearTimeout(timer);
    if (killTimer) clearTimeout(killTimer);
    const stdout = Buffer.concat(out).toString('utf8');
    const stderr = Buffer.concat(err).toString('utf8');
    const normal = failure === undefined && exitCode !== null && exitCode >= 0 && exitCode <= 3;
    resolve({
      exitCode, stdout, stderr, timedOut, failure,
      json: normal && !opts.table ? parseResponse(stdout, exitCode) : null,
      durationMs: Date.now() - started,
    });
  };

  // taskkill /T takes the whole tree: a crashed Clarion exe sits behind a modal dialog that
  // child.kill() would leave on screen with the file handle still open.
  const kill = (why: RunFailure) => {
    if (failure) return;
    failure = why;
    const pid = child.pid;
    if (pid === undefined) { finish(null); return; }
    const killFailed = (what: string) => {
      failure = { kind: 'kill_failed', pid, message: `${what}; tpscli (pid ${pid}) may still be running` };
      finish(null);
    };
    const tk = spawn('taskkill', ['/PID', String(pid), '/T', '/F'], { windowsHide: true, stdio: 'ignore' });
    killTimer = setTimeout(() => killFailed(`taskkill did not return within ${KILL_DEADLINE_MS} ms`), KILL_DEADLINE_MS);
    tk.on('error', e => killFailed(`taskkill failed: ${e.message}`));
    tk.on('exit', code => { if (code !== 0) killFailed(`taskkill exited ${code}`); });
    // On success the child's own close event finishes, with failure already set.
  };

  timer = setTimeout(() => {
    timedOut = true;
    kill({ kind: 'timeout', message: `tpscli did not finish within ${opts.timeoutMs} ms` });
  }, opts.timeoutMs);

  try {
    child = spawn(file, args, {
      windowsHide: true, shell: false,
      stdio: [opts.stdin === undefined ? 'ignore' : 'pipe', 'pipe', 'pipe'],
    });
  } catch (e) {
    // spawn throws synchronously for an argument it cannot pass at all, e.g. a NUL byte
    failure = { kind: 'spawn', message: (e as Error).message };
    finish(null);
    return;
  }

  if (opts.stdin !== undefined) {
    // an exe that exits before reading stdin gives EPIPE on the write; that must not crash the server
    child.stdin!.on('error', () => {});
    child.stdin!.end(opts.stdin);
  }

  const collect = (sink: Buffer[]) => (chunk: Buffer) => {
    bytes += chunk.length;
    if (bytes > OUTPUT_LIMIT) {
      kill({ kind: 'output_limit', message: `output exceeded ${OUTPUT_LIMIT} bytes; add a LIMIT` });
      return;
    }
    sink.push(chunk);
  };
  child.stdout!.on('data', collect(out));
  child.stderr!.on('data', collect(err));
  child.on('error', e => { failure ??= { kind: 'spawn', message: e.message }; finish(null); });
  child.on('close', code => finish(code));
});
