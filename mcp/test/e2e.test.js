import { test } from 'node:test';
import assert from 'node:assert/strict';
import { copyFileSync, existsSync, mkdtempSync, readFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';

// Real server process, real exe, real fixtures, copied so nothing under cli\testdata is written.
const here = path.dirname(fileURLToPath(import.meta.url));
const serverJs = path.resolve(here, '..', 'dist', 'server.js');
const exe = path.resolve(here, '..', '..', 'cli', 'tpscli.exe');
const fixtures = path.resolve(here, '..', '..', 'cli', 'testdata');
const NAMES = ['ALLTYPES', 'GROUPS', 'KEYS', 'MEMOS', 'NOKEY', 'SECRET'];
const serverVersion = JSON.parse(readFileSync(path.resolve(here, '..', 'package.json'), 'utf8')).version;

const absent = !existsSync(exe) ? exe : NAMES.map(n => path.join(fixtures, `${n}.TPS`)).find(p => !existsSync(p));
const skip = absent ? `e2e skipped: ${absent} is missing (build the CLI and run cli\\verify.ps1 to generate the corpus)` : false;

function corpus() {
  const work = mkdtempSync(path.join(os.tmpdir(), 'tpscli-e2e-'));
  for (const n of NAMES) copyFileSync(path.join(fixtures, `${n}.TPS`), path.join(work, `${n}.TPS`));
  return work;
}

async function start(work, extraArgs = [], env = {}) {
  const transport = new StdioClientTransport({
    command: process.execPath,
    args: [serverJs, '--exe', exe, '--root', work, ...extraArgs],
    env: { ...process.env, TPSCLI_OWNER: '', ...env },   // an inherited owner would defeat the no-owner checks
    stderr: 'pipe',
  });
  const client = new Client({ name: 'e2e', version: '0' });
  await client.connect(transport);
  return client;
}
const call = (client, name, args = {}) => client.callTool({ name, arguments: args });
const ok = r => { assert.equal(r.isError, false, r.content[0].text); return r.structuredContent; };
const err = (r, code) => { assert.equal(r.isError, true); assert.equal(r.structuredContent.error.code, code, r.content[0].text); return r.structuredContent; };

test('e2e: read-only server, every read tool, every gate', { skip }, async t => {
  const work = corpus();
  const keys = path.join(work, 'KEYS.TPS');
  const client = await start(work);
  t.after(() => client.close());

  const v = ok(await call(client, 'tps_version'));
  assert.equal(v.server, serverVersion);
  assert.equal(typeof v.exe.version, 'string');

  assert.equal(ok(await call(client, 'tps_list_files')).files.length, 6);

  const d = ok(await call(client, 'tps_describe', { file: 'KEYS.TPS' }));
  assert.equal(d.op, 'describe');
  assert.equal(d.records, 5);

  const s = ok(await call(client, 'tps_select', { file: 'KEYS.TPS', columns: ['ID', 'NAME'], where: "NAME LIKE 'b%'", order_by: 'ID', limit: 2 }));
  assert.deepEqual(s.rows, [[2, 'baker']]);
  assert.equal(s.truncated, false);

  const tbl = await call(client, 'tps_select', { file: 'KEYS.TPS', limit: 2, format: 'table' });
  assert.equal(tbl.isError, false);
  assert.match(tbl.content[0].text, /^ID\s+NAME/);
  assert.equal(tbl.structuredContent, undefined);

  assert.equal(ok(await call(client, 'tps_query', { sql: `SELECT ID FROM [${keys}] WHERE ID = 1` })).row_count, 1);

  const refused = err(await call(client, 'tps_delete', { file: 'KEYS.TPS', where: 'ID = 1' }), 'WRITES_DISABLED');
  assert.equal(refused.outcome, 'none');
  assert.equal(ok(await call(client, 'tps_query', { sql: `DELETE FROM [${keys}] WHERE ID = 1`, parse_only: true })).parse_only, true);
  assert.equal(ok(await call(client, 'tps_select', { file: 'KEYS.TPS', where: 'ID = 1' })).row_count, 1);   // nothing changed

  err(await call(client, 'tps_describe', { file: 'SECRET.TPS' }), 'OWNER_REQUIRED');
  assert.equal(ok(await call(client, 'tps_describe', { file: 'SECRET.TPS', owner: 's3cret' })).records, 2);

  const tbErr = await call(client, 'tps_select', { file: 'KEYS.TPS', where: 'ZZ = 1', format: 'table' });
  assert.equal(tbErr.isError, true);
  assert.match(tbErr.content[0].text, /^UNKNOWN_COLUMN: /);
});

test('e2e: writes enabled, owner from the environment, one row round trip', { skip }, async t => {
  const work = corpus();
  const keys = path.join(work, 'KEYS.TPS');
  const client = await start(work, ['--allow-writes'], { TPSCLI_OWNER: 's3cret' });
  t.after(() => client.close());

  assert.equal(ok(await call(client, 'tps_describe', { file: 'SECRET.TPS' })).records, 2);
  assert.equal(ok(await call(client, 'tps_insert', { file: 'KEYS.TPS', values: { ID: 9, NAME: "O'Nine", CODE: 'N' } })).affected, 1);
  const u = ok(await call(client, 'tps_update', { file: 'KEYS.TPS', set: { NAME: 'niner' }, where: 'ID = 9' }));
  assert.deepEqual([u.matched, u.affected], [1, 1]);
  assert.deepEqual(ok(await call(client, 'tps_select', { file: 'KEYS.TPS', columns: ['NAME'], where: 'ID = 9' })).rows, [['niner']]);
  err(await call(client, 'tps_query', { sql: `UPDATE [${keys}] SET NAME = 'x'` }), 'WHERE_REQUIRED');
  assert.equal(ok(await call(client, 'tps_delete', { file: 'KEYS.TPS', where: 'ID = 9' })).affected, 1);
  assert.equal(ok(await call(client, 'tps_select', { file: 'KEYS.TPS', where: 'ID = 9' })).row_count, 0);
  const noWhere = await call(client, 'tps_update', { file: 'KEYS.TPS', set: { NAME: 'x' } });
  assert.equal(noWhere.isError, true);
  assert.match(noWhere.content[0].text, /Invalid arguments for tool tps_update/);
});
