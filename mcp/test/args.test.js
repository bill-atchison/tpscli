import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseArgs, discoverExe } from '../dist/server.js';

const serverJs = fileURLToPath(new URL('../dist/server.js', import.meta.url));
const tmp = mkdtempSync(path.join(os.tmpdir(), 'tpscli-args-'));
const here = path.join(tmp, 'dist');            // pretend server.js lives here
mkdirSync(here);
const beside = path.join(here, 'tpscli.exe');
writeFileSync(beside, '');
const rootDir = path.join(tmp, 'data');
mkdirSync(rootDir);

test('defaults, flags and environment', () => {
  const c = parseArgs([], {}, here);
  assert.deepEqual(c, { exe: beside, roots: [], allowWrites: false, owner: undefined, timeoutMs: 60000, version: c.version });
  assert.match(c.version, /^\d+\.\d+\.\d+/);
  const full = parseArgs(['--root', rootDir, '--allow-writes', '--owner', 's3cret', '--timeout', '5', '--exe', beside], {}, here);
  assert.deepEqual(full, { exe: beside, roots: [rootDir], allowWrites: true, owner: 's3cret', timeoutMs: 5000, version: c.version });
  const env = parseArgs([], { TPSCLI_EXE: beside, TPSCLI_OWNER: 'envowner' }, 'C:\\nowhere');
  assert.equal(env.exe, beside);
  assert.equal(env.owner, 'envowner');
  assert.equal(parseArgs(['--owner', 'flag'], { TPSCLI_OWNER: 'env' }, here).owner, 'flag');
  assert.equal(parseArgs([], { TPSCLI_OWNER: '' }, here).owner, undefined);
});

test('bad flags fail with a message', () => {
  assert.throws(() => parseArgs(['--bogus'], {}, here), /unknown option --bogus/);
  assert.throws(() => parseArgs(['--root'], {}, here), /--root needs a value/);
  assert.throws(() => parseArgs(['--timeout', '0'], {}, here), /positive whole number/);
  assert.throws(() => parseArgs(['--timeout', 'x'], {}, here), /positive whole number/);
  assert.throws(() => parseArgs(['--timeout', '2147484'], {}, here), /at most 2147483/);
  assert.throws(() => parseArgs(['--exe', tmp], {}, here), /tried .*\. Pass --exe/);   // a folder is not an exe
  assert.throws(() => parseArgs(['--root', path.join(tmp, 'missing')], {}, here), /is not a folder/);
  assert.throws(() => parseArgs(['--exe', 'C:\\no\\tpscli.exe'], {}, here), /tried C:\\no\\tpscli\.exe\. Pass --exe/);
});

test('discovery order: beside server.js, then the repo layout', () => {
  assert.equal(discoverExe(undefined, here), beside);
  const repo = path.join(tmp, 'repo');
  mkdirSync(path.join(repo, 'mcp', 'dist'), { recursive: true });
  mkdirSync(path.join(repo, 'cli'));
  writeFileSync(path.join(repo, 'cli', 'tpscli.exe'), '');
  assert.equal(discoverExe(undefined, path.join(repo, 'mcp', 'dist')), path.join(repo, 'cli', 'tpscli.exe'));
  assert.throws(() => discoverExe(undefined, tmp), /tried .*tpscli\.exe, .*tpscli\.exe\./);
});

test('a startup failure exits 2 with the reason on stderr', () => {
  const r = spawnSync(process.execPath, [serverJs, '--exe', beside, '--root', path.join(tmp, 'missing')], { encoding: 'utf8', windowsHide: true });
  assert.equal(r.status, 2);
  assert.match(r.stderr, /tpscli-mcp: --root .* is not a folder/);
});
