import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { run, parseResponse, OUTPUT_LIMIT } from '../dist/runner.js';

const fake = fileURLToPath(new URL('./fake-tpscli.js', import.meta.url));
// The fake is a script, so "the exe" is node and the script is the first argument.
const go = (mode, opts = {}) => run(process.execPath, [fake, mode, 'SELECT 1'], { timeoutMs: 10000, ...opts });

test('parseResponse accepts only a complete object that agrees with the exit code', () => {
  assert.deepEqual(parseResponse(' {"ok":true,"complete":true}\r\n', 0), { ok: true, complete: true });
  assert.deepEqual(parseResponse('{"ok":false,"complete":true}', 2), { ok: false, complete: true });
  assert.equal(parseResponse('{"ok":true,"complete":true}', 1), null);
  assert.equal(parseResponse('{"ok":true,"complete":false}', 0), null);
  assert.equal(parseResponse('{}', 0), null);
  assert.equal(parseResponse('[]', 0), null);
  assert.equal(parseResponse('', 0), null);
  assert.equal(parseResponse('{"ok":true', 0), null);
});

test('exit 0 with a response', async () => {
  const r = await go('ok');
  assert.equal(r.exitCode, 0);
  assert.equal(r.json.ok, true);
  assert.equal(r.json.op, 'select');
  assert.equal(r.failure, undefined);
  assert.equal(r.timedOut, false);
  assert.ok(r.durationMs >= 0);
});

test('exit 3 with an error response', async () => {
  const r = await go('err3');
  assert.equal(r.exitCode, 3);
  assert.equal(r.json.error.code, 'RECORD_HELD');
  assert.equal(r.json.outcome, 'rolled_back');
});

test('an object that disagrees with the exit code, or is not complete, is not a response', async () => {
  assert.equal((await go('ok-exit1')).json, null);
  assert.equal((await go('notcomplete')).json, null);
  assert.equal((await go('incomplete')).json, null);
});

test('table mode keeps stdout and never parses', async () => {
  const r = await go('table', { table: true });
  assert.equal(r.exitCode, 0);
  assert.equal(r.json, null);
  assert.match(r.stdout, /^ID {2}NAME/);
});

test('the statement travels on stdin byte for byte', async () => {
  const stdin = `INSERT INTO [K.TPS] (NAME) VALUES ('12" pizza\\')`;
  const r = await go('stdin', { stdin });
  assert.equal(r.json.echo, stdin);
});

test('garbage, empty and out-of-range exits give no json and keep stderr', async () => {
  const g = await go('garbage');
  assert.equal(g.json, null);
  assert.equal(g.exitCode, 3);
  assert.match(g.stderr, /boom/);
  const e = await go('empty');
  assert.equal(e.json, null);
  assert.equal(e.exitCode, 0);
  const x = await go('exit9');
  assert.equal(x.json, null);
  assert.equal(x.exitCode, 9);
});

test('a file that cannot be spawned is a spawn failure', async () => {
  const r = await run('C:\\no\\such\\tpscli.exe', ['--version'], { timeoutMs: 1000 });
  assert.equal(r.failure.kind, 'spawn');
  assert.match(r.failure.message, /ENOENT/);
  assert.equal(r.exitCode, null);
  assert.equal(r.json, null);
});

test('an argument spawn cannot pass is a spawn failure too, not a crash', async () => {
  const r = await run(process.execPath, [fake, 'ok', 'bad\u0000arg'], { timeoutMs: 1000 });
  assert.equal(r.failure.kind, 'spawn');
  assert.equal(r.exitCode, null);
});

test('output past the ceiling kills the process', async () => {
  const r = await go('flood', { timeoutMs: 60000 });
  assert.equal(r.failure.kind, 'output_limit');
  assert.match(r.failure.message, /LIMIT/);
  assert.ok(Buffer.byteLength(r.stdout) <= OUTPUT_LIMIT);
});

test('a hang trips the timeout and leaves no process behind', async () => {
  const r = await go('hang', { timeoutMs: 500 });
  assert.equal(r.failure.kind, 'timeout');
  assert.equal(r.timedOut, true);
  assert.equal(r.json, null);
  const pid = Number(r.stdout.trim());
  assert.ok(pid > 0, 'the fake printed its pid');
  const list = execFileSync('tasklist', ['/FI', `PID eq ${pid}`, '/NH'], { encoding: 'utf8' });
  assert.ok(!/node\.exe/i.test(list), `pid ${pid} is still running:\n${list}`);
});
