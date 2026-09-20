#!/usr/bin/env node
// tpscli-mcp: every tpscli function as an MCP tool over stdio. Policy (writes, roots, owner),
// argv building and result shaping live here; SQL text rules are in sql.ts, process handling in
// runner.ts. The exe's JSON is passed through unchanged, so cli/README.md is the contract.
import { existsSync, readdirSync, readFileSync, statSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { z } from 'zod';
import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import { run as spawnRun, type Run, type RunResult } from './runner.js';
import {
  InvalidArgument, WRITE_OPS, buildDelete, buildDescribe, buildInsert, buildSelect, buildUpdate, classify,
} from './sql.js';

export interface Config {
  exe: string;
  roots: string[];
  allowWrites: boolean;
  owner?: string;
  timeoutMs: number;
  version: string;
}

export type Op = 'describe' | 'select' | 'insert' | 'update' | 'delete' | null;

export type ToolResult = {
  content: { type: 'text'; text: string }[];
  structuredContent?: Record<string, unknown>;
  isError?: boolean;
};

class ToolError extends Error {
  constructor(readonly code: string, message: string) {
    super(message);
  }
}

const body = (o: Record<string, unknown>, isError: boolean): ToolResult =>
  ({ content: [{ type: 'text', text: JSON.stringify(o, null, 2) }], structuredContent: o, isError });

// Every refusal the server makes itself wears the exe's error shape, so the model sees one format.
function refusal(code: string, message: string, op: Op, write: boolean): ToolResult {
  return body({ ok: false, complete: true, op, error: { code, message }, ...(write ? { outcome: 'none' } : {}) }, true);
}

// Spec section 5, in this order: a runner failure or an exit outside 0..3 is INCOMPLETE whatever
// stdout holds; then table mode, which never looks at json; then JSON mode, where no valid object
// is INCOMPLETE.
export function toResult(r: RunResult, op: Op, write: boolean, table: boolean): ToolResult {
  const badExit = r.exitCode === null || r.exitCode < 0 || r.exitCode > 3;
  if (r.failure || badExit || (!table && r.json === null)) {
    const why = r.failure ? r.failure.message
      : r.exitCode === null ? 'tpscli ended without an exit code'
      : badExit ? `tpscli exited with code ${r.exitCode}`
      : 'tpscli produced no valid response object';
    const unknown = write ? ' and the write outcome is unknown' : '';
    return body({
      ok: false, complete: false, op,
      error: { code: 'INCOMPLETE', message: `${why}. The response is incomplete${unknown}; do not retry without checking the file.` },
      exit_code: r.exitCode, timed_out: r.timedOut, stderr: r.stderr,
      ...(write ? { outcome: 'unknown' } : {}),
    }, true);
  }
  if (table) return { content: [{ type: 'text', text: r.stdout }], isError: r.exitCode !== 0 };
  return body(r.json!, r.exitCode !== 0);
}

const DIALECT = `Dialect: the file goes in square brackets, e.g. [C:\\pos\\data\\ITEMS.TPS]; string literals use single quotes with '' for an embedded quote; WHERE supports = <> != < > <= >=, AND OR NOT, parentheses, LIKE with % and _, IN (...), and has no IS NULL (compare to '' or 0); dates are 'YYYY-MM-DD', times 'HH:MM:SS.hh', DECIMAL values are plain numbers; LIMIT 0 means no cap. Look before you write: run tps_select with the same where first.`;

const FILE_ARG = z.string().min(1).describe('Path to the .TPS file: absolute, or a bare name resolved inside the server\'s --root folders.');
const OWNER_ARG = z.string().optional().describe('Owner (encryption) string for this call only. Prefer the server-wide --owner / TPSCLI_OWNER so the secret stays out of the conversation.');
const WHERE_ARG = z.string().describe('Filter in the tpscli dialect without the WHERE keyword, e.g. "PRICE > 5 AND DESC LIKE \'a%\'".');
const FORMAT_ARG = z.enum(['json', 'table']).optional().describe('"json" (default) returns the exe\'s response object; "table" returns the aligned text grid, easier to read for wide results.');
const INT_ARG = z.number().int().min(0).max(2147483647);
const STATEMENT_OPS = ['DESCRIBE', 'SELECT', 'INSERT', 'UPDATE', 'DELETE'];
const FULLY_QUALIFIED = /^(?:[A-Za-z]:[\\/]|\\\\)/;    // drive letter or UNC; \x and C:x are neither

export function createServer(config: Config, run: Run): McpServer {
  const server = new McpServer({ name: 'tpscli-mcp', version: config.version });

  const resolveFile = (file: string): string => {
    if (FULLY_QUALIFIED.test(file)) return file;
    if (config.roots.length === 0) {
      throw new ToolError('FILE_NOT_FOUND', `${file} is not an absolute path and the server was started without --root folders`);
    }
    const inside = (root: string, candidate: string) => {
      const rel = path.relative(root, candidate);
      return rel !== '' && rel !== '..' && !rel.startsWith(`..${path.sep}`) && !path.isAbsolute(rel);
    };
    for (const root of config.roots) {
      const candidate = path.resolve(root, file);
      if (!config.roots.some(r => inside(r, candidate))) continue;   // escaped every root
      if (existsSync(candidate)) return candidate;
    }
    throw new ToolError('FILE_NOT_FOUND', `${file} not found inside ${config.roots.join('; ')}`);
  };

  const invoke = async (
    tool: string, sql: string, op: Op, write: boolean,
    o: { owner?: string; limitDefault?: number; parseOnly?: boolean; table?: boolean },
  ): Promise<ToolResult> => {
    const args: string[] = [];
    const owner = o.owner ?? config.owner;
    // spawn cannot pass a NUL byte and its error message would echo the value; the owner is never echoed.
    if (owner !== undefined && owner.includes('\0')) throw new InvalidArgument('the owner string contains a NUL character and cannot be passed');
    if (owner !== undefined) args.push('--owner', owner);
    if (o.limitDefault !== undefined) args.push('--limit-default', String(o.limitDefault));
    if (o.parseOnly) args.push('--parse-only');
    if (o.table) args.push('--table');
    args.push(sql);
    const r = await run(config.exe, args, { timeoutMs: config.timeoutMs, table: o.table === true });
    // One line per call; never argv, which may hold the owner string.
    process.stderr.write(`tpscli-mcp ${tool} ${r.durationMs}ms exit ${r.exitCode}${r.failure ? ` ${r.failure.kind}` : ''}\n`);
    return toResult(r, op, write, o.table === true);
  };

  const writesDisabled = (op: Op) => refusal('WRITES_DISABLED',
    'This server was started without --allow-writes, so INSERT, UPDATE and DELETE are refused. Restart it with --allow-writes to enable them.', op, true);

  // Handler refusals (bad column, null value, empty set, blank where, unresolvable file) become
  // envelopes; anything else is a bug and propagates.
  const attempt = async (op: Op, write: boolean, fn: () => Promise<ToolResult>): Promise<ToolResult> => {
    try {
      return await fn();
    } catch (e) {
      if (e instanceof InvalidArgument || e instanceof ToolError) return refusal(e.code, e.message, op, write);
      throw e;
    }
  };

  server.registerTool('tps_version', {
    title: 'tpscli version',
    description: 'Version of this MCP server and of the tpscli.exe it runs.',
  }, async () => {
    const r = await run(config.exe, ['--version'], { timeoutMs: config.timeoutMs });
    process.stderr.write(`tpscli-mcp tps_version ${r.durationMs}ms exit ${r.exitCode}\n`);
    const res = toResult(r, null, false, false);
    return res.isError ? res : body({ server: config.version, exe: r.json! }, false);
  });

  server.registerTool('tps_list_files', {
    title: 'List TopSpeed files',
    description: 'Lists the .TPS files directly inside the server\'s --root folders (no recursion): name, path, size and modified time. Returns NO_ROOT when the server has no roots; then pass absolute paths to the other tools.',
    inputSchema: { pattern: z.string().optional().describe('Glob on the file name, case-insensitive, * and ? only. Default *.TPS.') },
  }, async ({ pattern }) => attempt(null, false, async () => {
    if (config.roots.length === 0) {
      throw new ToolError('NO_ROOT', 'The server was started without --root folders, so there is nothing to list; pass absolute paths to the other tools.');
    }
    const glob = pattern ?? '*.TPS';
    const re = new RegExp(`^${glob.replace(/[.+^${}()|[\]\\]/g, '\\$&').replace(/\*/g, '.*').replace(/\?/g, '.')}$`, 'i');
    const files: { name: string; path: string; size: number; modified: string }[] = [];
    for (const root of config.roots) {
      for (const entry of readdirSync(root, { withFileTypes: true })) {
        if (!entry.isFile() || !re.test(entry.name)) continue;
        const full = path.join(root, entry.name);
        const st = statSync(full);
        files.push({ name: entry.name, path: full, size: st.size, modified: st.mtime.toISOString() });
      }
    }
    files.sort((a, b) => a.path.localeCompare(b.path));
    return body({ files }, false);
  }));

  server.registerTool('tps_describe', {
    title: 'Describe a TopSpeed file',
    description: `Layout of a .TPS file: record count, whether it is encrypted, every column with its type (groups and arrays keep their members and dim) and every key. Run it before selecting from or changing a file you have not seen. ${DIALECT}`,
    inputSchema: { file: FILE_ARG, owner: OWNER_ARG },
  }, async ({ file, owner }) => attempt('describe', false, () =>
    invoke('tps_describe', buildDescribe(resolveFile(file)), 'describe', false, { owner })));

  server.registerTool('tps_select', {
    title: 'Select rows',
    description: `Reads rows from a .TPS file. Response: columns, rows (arrays in column order), row_count, truncated (true when the cap cut the result short). Without limit the exe caps at 1000 rows. ${DIALECT}`,
    inputSchema: {
      file: FILE_ARG,
      columns: z.array(z.string()).optional().describe('Column names; omit for all. A group or array name expands to its leaves.'),
      where: WHERE_ARG.optional(),
      order_by: z.string().optional().describe('e.g. "SKU DESC, ID".'),
      limit: INT_ARG.optional().describe('Row cap; 0 means no cap; omitted means the exe default of 1000.'),
      offset: INT_ARG.optional().describe('Rows to skip; requires limit.'),
      format: FORMAT_ARG,
      owner: OWNER_ARG,
    },
  }, async a => attempt('select', false, () =>
    invoke('tps_select', buildSelect({ ...a, file: resolveFile(a.file) }), 'select', false, { owner: a.owner, table: a.format === 'table' })));

  server.registerTool('tps_insert', {
    title: 'Insert a row',
    description: `Inserts one row. values maps column name to value: strings, numbers (DECIMAL columns too) and booleans (1/0); dates 'YYYY-MM-DD', times 'HH:MM:SS.hh', BLOB base64. Omit a column to leave it blank; there is no NULL. Refused with WRITES_DISABLED unless the server runs with --allow-writes. ${DIALECT}`,
    inputSchema: { file: FILE_ARG, values: z.record(z.unknown()).describe('column -> value, at least one'), owner: OWNER_ARG },
  }, async ({ file, values, owner }) => attempt('insert', true, async () => {
    if (!config.allowWrites) return writesDisabled('insert');
    return invoke('tps_insert', buildInsert(resolveFile(file), values), 'insert', true, { owner });
  }));

  server.registerTool('tps_update', {
    title: 'Update rows',
    description: `Updates every row matching where. Response: matched and affected. Refused with WRITES_DISABLED unless the server runs with --allow-writes. ${DIALECT}`,
    inputSchema: { file: FILE_ARG, set: z.record(z.unknown()).describe('column -> new value, at least one'), where: WHERE_ARG, owner: OWNER_ARG },
  }, async ({ file, set, where, owner }) => attempt('update', true, async () => {
    if (!config.allowWrites) return writesDisabled('update');
    return invoke('tps_update', buildUpdate(resolveFile(file), set, where), 'update', true, { owner });
  }));

  server.registerTool('tps_delete', {
    title: 'Delete rows',
    description: `Deletes every row matching where. Response: matched and affected. Refused with WRITES_DISABLED unless the server runs with --allow-writes. ${DIALECT}`,
    inputSchema: { file: FILE_ARG, where: WHERE_ARG, owner: OWNER_ARG },
  }, async ({ file, where, owner }) => attempt('delete', true, async () => {
    if (!config.allowWrites) return writesDisabled('delete');
    return invoke('tps_delete', buildDelete(resolveFile(file), where), 'delete', true, { owner });
  }));

  server.registerTool('tps_query', {
    title: 'Run a tpscli statement',
    description: `Runs one statement exactly as written: DESCRIBE, SELECT, INSERT, UPDATE or DELETE. Use it when the structured tools cannot express what you need. The file path in the statement is used verbatim (no --root resolution). Writes are refused unless the server runs with --allow-writes; parse_only is always allowed and never touches a record. ${DIALECT}`,
    inputSchema: {
      sql: z.string().min(1).describe('Exactly one statement.'),
      owner: OWNER_ARG,
      limit_default: INT_ARG.optional().describe('Cap for a SELECT without LIMIT (exe default 1000).'),
      parse_only: z.boolean().optional().describe('Validate syntax and columns against the file without touching a record.'),
      format: FORMAT_ARG,
    },
  }, async ({ sql, owner, limit_default, parse_only, format }) => {
    const kind = classify(sql);
    const write = kind !== null && WRITE_OPS.has(kind);
    const op = (kind !== null && STATEMENT_OPS.includes(kind) ? kind.toLowerCase() : null) as Op;
    return attempt(op, write, async () => {
      if (write && format === 'table') throw new InvalidArgument('format "table" is not available for a write: the grid drops the outcome field');
      if (write && !parse_only && !config.allowWrites) return writesDisabled(op);
      return invoke('tps_query', sql, op, write, { owner, limitDefault: limit_default, parseOnly: parse_only, table: format === 'table' });
    });
  });

  return server;
}

// ---- command line ------------------------------------------------------------------------------

const VERSION: string = JSON.parse(readFileSync(new URL('../package.json', import.meta.url), 'utf8')).version;

// --exe (or TPSCLI_EXE) is the only candidate when given: a wrong explicit path must fail, not fall
// through to some other exe. Otherwise: tpscli.exe beside server.js, then ..\..\cli\tpscli.exe (the repo).
export function discoverExe(explicit: string | undefined, here: string): string {
  const candidates = explicit !== undefined
    ? [explicit]
    : [path.join(here, 'tpscli.exe'), path.resolve(here, '..', '..', 'cli', 'tpscli.exe')];
  const hit = candidates.find(c => existsSync(c) && statSync(c).isFile());
  if (hit === undefined) {
    throw new Error(`tpscli.exe not found; tried ${candidates.join(', ')}. Pass --exe <path> or set TPSCLI_EXE.`);
  }
  return hit;
}

export function parseArgs(argv: string[], env: NodeJS.ProcessEnv, here: string): Config {
  let exe = env.TPSCLI_EXE || undefined;
  const roots: string[] = [];
  let allowWrites = false;
  let owner = env.TPSCLI_OWNER || undefined;
  let timeoutMs = 60_000;
  const value = (i: number): string => {
    const v = argv[i + 1];
    if (v === undefined) throw new Error(`${argv[i]} needs a value`);
    return v;
  };
  for (let i = 0; i < argv.length; i++) {
    switch (argv[i]) {
      case '--exe': exe = value(i++); break;
      case '--root': roots.push(path.resolve(value(i++))); break;
      case '--allow-writes': allowWrites = true; break;
      case '--owner': owner = value(i++); break;
      case '--timeout': {
        const s = value(i++);
        if (!/^\d+$/.test(s) || Number(s) === 0) throw new Error(`--timeout needs a positive whole number of seconds, not ${s}`);
        if (Number(s) > 2147483) throw new Error(`--timeout is at most 2147483 seconds (Node's timer limit), not ${s}`);
        timeoutMs = Number(s) * 1000;
        break;
      }
      default: throw new Error(`unknown option ${argv[i]}`);
    }
  }
  for (const r of roots) {
    if (!existsSync(r) || !statSync(r).isDirectory()) throw new Error(`--root ${r} is not a folder`);
  }
  return { exe: discoverExe(exe, here), roots, allowWrites, owner, timeoutMs, version: VERSION };
}

async function main(): Promise<void> {
  const here = path.dirname(fileURLToPath(import.meta.url));
  const config = parseArgs(process.argv.slice(2), process.env, here);
  await createServer(config, spawnRun).connect(new StdioServerTransport());
  process.stderr.write(`tpscli-mcp ${config.version} ready: exe ${config.exe}; roots ${config.roots.length ? config.roots.join('; ') : '(none)'}; `
    + `writes ${config.allowWrites ? 'enabled' : 'disabled'}; owner ${config.owner === undefined ? 'none' : 'set'}; timeout ${config.timeoutMs / 1000}s\n`);
}

// Start only when run as a program; the tests import this module.
if (process.argv[1] !== undefined && path.resolve(process.argv[1]).toLowerCase() === fileURLToPath(import.meta.url).toLowerCase()) {
  main().catch((e: Error) => {
    process.stderr.write(`tpscli-mcp: ${e.message}\n`);
    process.exit(2);
  });
}
