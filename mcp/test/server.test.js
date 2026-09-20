import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { InMemoryTransport } from '@modelcontextprotocol/sdk/inMemory.js';
import { createServer, toResult } from '../dist/server.js';

// ---- fixtures: two roots, a bare name present in both, one only in b, a non-TPS file above them
const tmp = mkdtempSync(path.join(os.tmpdir(), 'tpscli-mcp-'));
const rootA = path.join(tmp, 'a');
const rootB = path.join(tmp, 'b');
mkdirSync(rootA);
mkdirSync(rootB);
writeFileSync(path.join(rootA, 'KEYS.TPS'), '');
writeFileSync(path.join(rootB, 'KEYS.TPS'), '');
writeFileSync(path.join(rootB, 'ONLYB.TPS'), '');
writeFileSync(path.join(tmp, 'notes.txt'), '');

const OK = { exitCode: 0, stdout: '', stderr: '', json: { ok: true, op: 'select', rows: [], complete: true }, durationMs: 1, timedOut: false };
const ERR2 = { exitCode: 2, stdout: '', stderr: '', json: { ok: false, op: 'describe', error: { code: 'FILE_NOT_FOUND', message: 'x' }, complete: true }, durationMs: 1, timedOut: false };
const TABLE = { exitCode: 0, stdout: 'ID\n--\n 1\n(1 rows)\n', stderr: '', json: null, durationMs: 1, timedOut: false };
const VERSION = { exitCode: 0, stdout: '', stderr: '', json: { ok: true, op: null, version: '9.9.9', complete: true }, durationMs: 1, timedOut: false };
const TIMEOUT = { exitCode: null, stdout: '', stderr: 'partial', json: null, durationMs: 60000, timedOut: true, failure: { kind: 'timeout', message: 'tpscli did not finish within 60000 ms' } };

// A stub Run that records what the server asked for and answers with a canned RunResult.
const stub = (result = OK) => {
  const calls = [];
  const run = async (file, args, opts) => { calls.push({ file, args, opts }); return result; };
  run.calls = calls;
  return run;
};

const base = { exe: 'C:\\fake\\tpscli.exe', roots: [rootA, rootB], allowWrites: false, timeoutMs: 1234, version: '0.0.0-test' };

async function connect(config, run) {
  const server = createServer(config, run);
  const [clientSide, serverSide] = InMemoryTransport.createLinkedPair();
  await server.connect(serverSide);
  const client = new Client({ name: 'test', version: '0' });
  await client.connect(clientSide);
  return client;
}
const call = (client, name, args = {}) => client.callTool({ name, arguments: args });

test('exactly the eight tools are registered', async () => {
  const client = await connect(base, stub());
  const names = (await client.listTools()).tools.map(t => t.name).sort();
  assert.deepEqual(names, ['tps_delete', 'tps_describe', 'tps_insert', 'tps_list_files', 'tps_query', 'tps_select', 'tps_update', 'tps_version']);
});

test('bare names resolve against the roots in order; absolute paths pass through', async () => {
  const run = stub();
  const client = await connect(base, run);
  await call(client, 'tps_describe', { file: 'KEYS.TPS' });
  assert.deepEqual(run.calls[0], { file: base.exe, args: [], opts: { timeoutMs: 1234, table: false, stdin: `DESCRIBE [${path.join(rootA, 'KEYS.TPS')}]` } });
  await call(client, 'tps_describe', { file: 'ONLYB.TPS' });
  assert.equal(run.calls[1].opts.stdin, `DESCRIBE [${path.join(rootB, 'ONLYB.TPS')}]`);
  await call(client, 'tps_describe', { file: 'C:\\somewhere\\else\\X.TPS' });
  assert.equal(run.calls[2].opts.stdin, 'DESCRIBE [C:\\somewhere\\else\\X.TPS]');
});

test('a name that is missing or escapes the roots is FILE_NOT_FOUND before the exe runs', async () => {
  const run = stub();
  const client = await connect(base, run);
  const missing = await call(client, 'tps_describe', { file: 'NOPE.TPS' });
  assert.equal(missing.isError, true);
  assert.equal(missing.structuredContent.error.code, 'FILE_NOT_FOUND');
  assert.equal(missing.structuredContent.op, 'describe');
  assert.equal(missing.structuredContent.complete, true);
  const escape = await call(client, 'tps_describe', { file: '..\\notes.txt' });
  assert.equal(escape.structuredContent.error.code, 'FILE_NOT_FOUND');
  assert.equal(run.calls.length, 0);
  await call(client, 'tps_describe', { file: '..\\b\\ONLYB.TPS' });      // lands inside another root: allowed
  assert.equal(run.calls[0].opts.stdin, `DESCRIBE [${path.join(rootB, 'ONLYB.TPS')}]`);
  const noRoots = await connect({ ...base, roots: [] }, run);
  const r = await call(noRoots, 'tps_describe', { file: 'KEYS.TPS' });
  assert.equal(r.structuredContent.error.code, 'FILE_NOT_FOUND');
  assert.match(r.structuredContent.error.message, /--root/);
  for (const notQualified of ['\\data\\KEYS.TPS', 'C:KEYS.TPS']) {
    assert.equal((await call(noRoots, 'tps_describe', { file: notQualified })).structuredContent.error.code, 'FILE_NOT_FOUND');
  }
  await call(noRoots, 'tps_describe', { file: '\\\\server\\share\\KEYS.TPS' });
  assert.equal(run.calls.at(-1).opts.stdin, 'DESCRIBE [\\\\server\\share\\KEYS.TPS]');
});

test('owner: server default, per-call override, or none, always its own argv element', async () => {
  const run = stub();
  const client = await connect({ ...base, owner: 'srv' }, run);
  await call(client, 'tps_describe', { file: 'KEYS.TPS' });
  assert.deepEqual(run.calls[0].args.slice(0, 2), ['--owner', 'srv']);
  await call(client, 'tps_describe', { file: 'KEYS.TPS', owner: 'mine' });
  assert.deepEqual(run.calls[1].args.slice(0, 2), ['--owner', 'mine']);
  const plain = await connect(base, run);
  await call(plain, 'tps_describe', { file: 'KEYS.TPS' });
  assert.equal(run.calls[2].args.length, 0);
  const nul = await call(client, 'tps_describe', { file: 'KEYS.TPS', owner: 'SENTINEL\u0000X' });
  assert.equal(nul.structuredContent.error.code, 'INVALID_ARGUMENT');
  assert.ok(!JSON.stringify(nul).includes('SENTINEL'), 'the owner value must not be echoed');
  assert.equal(run.calls.length, 3);
});

test('tps_select builds the statement; format table adds --table and returns the grid as text', async () => {
  const run = stub(TABLE);
  const client = await connect(base, run);
  const r = await call(client, 'tps_select', { file: 'KEYS.TPS', columns: ['ID'], where: 'ID > 1', order_by: 'ID DESC', limit: 5, offset: 1, format: 'table' });
  assert.deepEqual(run.calls[0].args, ['--table']);
  assert.equal(run.calls[0].opts.stdin, `SELECT ID FROM [${path.join(rootA, 'KEYS.TPS')}] WHERE ID > 1 ORDER BY ID DESC LIMIT 5 OFFSET 1`);
  assert.equal(run.calls[0].opts.table, true);
  assert.deepEqual(r.content, [{ type: 'text', text: TABLE.stdout }]);
  assert.equal(r.structuredContent, undefined);
  assert.equal(r.isError, false);
});

test('a JSON result carries the exe object as structuredContent and text; isError follows the exit code', async () => {
  const client = await connect(base, stub(ERR2));
  const r = await call(client, 'tps_describe', { file: 'KEYS.TPS' });
  assert.equal(r.isError, true);
  assert.deepEqual(r.structuredContent, ERR2.json);
  assert.deepEqual(JSON.parse(r.content[0].text), ERR2.json);
});

test('writes are refused with WRITES_DISABLED and outcome none unless allowWrites', async () => {
  const run = stub();
  const client = await connect(base, run);
  for (const [tool, args, op] of [
    ['tps_insert', { file: 'KEYS.TPS', values: { ID: 1 } }, 'insert'],
    ['tps_update', { file: 'KEYS.TPS', set: { ID: 1 }, where: 'ID = 1' }, 'update'],
    ['tps_delete', { file: 'KEYS.TPS', where: 'ID = 1' }, 'delete'],
  ]) {
    const r = await call(client, tool, args);
    assert.equal(r.isError, true);
    assert.equal(r.structuredContent.error.code, 'WRITES_DISABLED');
    assert.match(r.structuredContent.error.message, /--allow-writes/);
    assert.equal(r.structuredContent.op, op);
    assert.equal(r.structuredContent.outcome, 'none');
  }
  assert.equal(run.calls.length, 0);
  const rw = await connect({ ...base, allowWrites: true }, run);
  await call(rw, 'tps_update', { file: 'KEYS.TPS', set: { NAME: 'x' }, where: 'ID = 1' });
  assert.deepEqual(run.calls[0].args, []);
  assert.equal(run.calls[0].opts.stdin, `UPDATE [${path.join(rootA, 'KEYS.TPS')}] SET NAME = 'x' WHERE ID = 1`);
  await call(rw, 'tps_insert', { file: 'KEYS.TPS', values: { ID: 9, NAME: 'nine' } });
  assert.deepEqual(run.calls[1].args, []);
  assert.equal(run.calls[1].opts.stdin, `INSERT INTO [${path.join(rootA, 'KEYS.TPS')}] (ID, NAME) VALUES (9, 'nine')`);
  await call(rw, 'tps_delete', { file: 'KEYS.TPS', where: 'ID = 9' });
  assert.deepEqual(run.calls[2].args, []);
  assert.equal(run.calls[2].opts.stdin, `DELETE FROM [${path.join(rootA, 'KEYS.TPS')}] WHERE ID = 9`);
});

test('handler refusals wear the envelope; schema failures are the SDK\'s', async () => {
  const run = stub();
  const client = await connect({ ...base, allowWrites: true }, run);
  const empty = await call(client, 'tps_update', { file: 'KEYS.TPS', set: {}, where: 'ID = 1' });
  assert.equal(empty.structuredContent.error.code, 'INVALID_ARGUMENT');
  assert.equal(empty.structuredContent.outcome, 'none');
  const nul = await call(client, 'tps_insert', { file: 'KEYS.TPS', values: { ID: null } });
  assert.match(nul.structuredContent.error.message, /omit the column/);
  const blank = await call(client, 'tps_delete', { file: 'KEYS.TPS', where: '  ' });
  assert.match(blank.structuredContent.error.message, /where clause/);
  // The SDK answers a schema failure itself: an isError text result, no envelope, handler never ran.
  const noWhere = await call(client, 'tps_update', { file: 'KEYS.TPS', set: { A: 1 } });
  assert.equal(noWhere.isError, true);
  assert.match(noWhere.content[0].text, /^MCP error -32602: Input validation error: Invalid arguments for tool tps_update: Required at where/);
  assert.equal(noWhere.structuredContent, undefined);
  const negative = await call(client, 'tps_select', { file: 'KEYS.TPS', limit: -1 });
  assert.match(negative.content[0].text, /Invalid arguments for tool tps_select/);
  assert.equal(run.calls.length, 0);
});

test('tps_query: verbatim SQL, flags, the write gate, parse_only, and no table for writes', async () => {
  const run = stub();
  const client = await connect(base, run);
  await call(client, 'tps_query', { sql: 'SELECT ID FROM [C:\\d\\K.TPS]', limit_default: 5 });
  assert.deepEqual(run.calls[0].args, ['--limit-default', '5']);
  assert.equal(run.calls[0].opts.stdin, 'SELECT ID FROM [C:\\d\\K.TPS]');
  const refused = await call(client, 'tps_query', { sql: '  delete FROM [C:\\d\\K.TPS] WHERE ID = 1' });
  assert.equal(refused.structuredContent.error.code, 'WRITES_DISABLED');
  assert.equal(refused.structuredContent.op, 'delete');
  assert.equal(refused.structuredContent.outcome, 'none');
  await call(client, 'tps_query', { sql: 'DELETE FROM [C:\\d\\K.TPS] WHERE ID = 1', parse_only: true });
  assert.deepEqual(run.calls[1].args, ['--parse-only']);
  assert.equal(run.calls[1].opts.stdin, 'DELETE FROM [C:\\d\\K.TPS] WHERE ID = 1');
  const rw = await connect({ ...base, allowWrites: true }, run);
  const tbl = await call(rw, 'tps_query', { sql: 'UPDATE [C:\\d\\K.TPS] SET A = 1 WHERE ID = 1', format: 'table' });
  assert.equal(tbl.structuredContent.error.code, 'INVALID_ARGUMENT');
  assert.match(tbl.structuredContent.error.message, /outcome/);
  await call(rw, 'tps_query', { sql: 'DESCRIBE [C:\\d\\K.TPS]', format: 'table' });
  assert.deepEqual(run.calls[2].args, ['--table']);
  assert.equal(run.calls[2].opts.stdin, 'DESCRIBE [C:\\d\\K.TPS]');
  await call(client, 'tps_query', { sql: '[K.TPS]' });      // no keyword: not a write, so the exe decides
  assert.deepEqual(run.calls[3].args, []);
  assert.equal(run.calls[3].opts.stdin, '[K.TPS]');
  assert.equal(run.calls.length, 4);
});

test('tps_list_files lists the roots, one level, by pattern, or NO_ROOT', async () => {
  const client = await connect(base, stub());
  const all = await call(client, 'tps_list_files');
  assert.deepEqual(all.structuredContent.files.map(f => f.path), [path.join(rootA, 'KEYS.TPS'), path.join(rootB, 'KEYS.TPS'), path.join(rootB, 'ONLYB.TPS')]);
  const f = all.structuredContent.files[0];
  assert.equal(f.name, 'KEYS.TPS');
  assert.equal(f.size, 0);
  assert.match(f.modified, /^\d{4}-\d{2}-\d{2}T/);
  const one = await call(client, 'tps_list_files', { pattern: 'only*' });
  assert.deepEqual(one.structuredContent.files.map(x => x.name), ['ONLYB.TPS']);
  const none = await call(client, 'tps_list_files', { pattern: 'k?ys.tps' });
  assert.equal(none.structuredContent.files.length, 2);
  const noRoots = await connect({ ...base, roots: [] }, stub());
  const r = await call(noRoots, 'tps_list_files');
  assert.equal(r.isError, true);
  assert.equal(r.structuredContent.error.code, 'NO_ROOT');
});

test('tps_version pairs the server version with the exe object', async () => {
  const run = stub(VERSION);
  const client = await connect(base, run);
  const r = await call(client, 'tps_version');
  assert.deepEqual(run.calls[0].args, ['--version']);
  assert.deepEqual(r.structuredContent, { server: '0.0.0-test', exe: VERSION.json });
  assert.equal(r.isError, false);
  const broken = await connect(base, stub(TIMEOUT));
  assert.equal((await call(broken, 'tps_version')).structuredContent.error.code, 'INCOMPLETE');
});

test('toResult: precedence and the INCOMPLETE envelope', () => {
  const t = toResult(TIMEOUT, 'update', true, false);
  assert.equal(t.isError, true);
  assert.deepEqual(t.structuredContent, {
    ok: false, complete: false, op: 'update',
    error: { code: 'INCOMPLETE', message: t.structuredContent.error.message },
    exit_code: null, timed_out: true, stderr: 'partial', outcome: 'unknown',
  });
  assert.match(t.structuredContent.error.message, /within 60000 ms.*write outcome is unknown.*do not retry/);
  const nine = toResult({ ...OK, exitCode: 9, json: null }, 'select', false, false);
  assert.match(nine.structuredContent.error.message, /exited with code 9/);
  assert.equal(nine.structuredContent.outcome, undefined);
  const noObj = toResult({ ...OK, json: null }, 'select', false, false);
  assert.match(noObj.structuredContent.error.message, /no valid response object/);
  const tableErr = toResult({ ...TABLE, exitCode: 1, stdout: 'UNKNOWN_COLUMN: Unknown column ZZ\n' }, 'select', false, true);
  assert.deepEqual(tableErr, { content: [{ type: 'text', text: 'UNKNOWN_COLUMN: Unknown column ZZ\n' }], isError: true });
  const tableNine = toResult({ ...TABLE, exitCode: 9 }, 'select', false, true);
  assert.equal(tableNine.structuredContent.error.code, 'INCOMPLETE');
  const raced = toResult({ ...OK, failure: { kind: 'timeout', message: 'late' }, timedOut: true }, 'select', false, false);
  assert.equal(raced.structuredContent.error.code, 'INCOMPLETE');
});
