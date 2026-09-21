import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  InvalidArgument, WRITE_OPS, bracket, column, literal, classify,
  buildDescribe, buildSelect, buildInsert, buildUpdate, buildDelete,
} from '../dist/sql.js';

// Every refusal is an InvalidArgument whose message says what to do instead.
const rejects = (fn, re) => assert.throws(fn, e => e instanceof InvalidArgument && e.code === 'INVALID_ARGUMENT' && re.test(e.message));

test('bracket wraps the path and refuses ]', () => {
  assert.equal(bracket('C:\\pos\\data\\ITEMS.TPS'), '[C:\\pos\\data\\ITEMS.TPS]');
  rejects(() => bracket('C:\\odd]name.TPS'), /"\]"/);
});

test('column accepts identifier paths and refuses everything else', () => {
  for (const ok of ['ID', 'ADDR.CITY', 'QTY[3]', 'ADDR[2].CITY', '_x1']) assert.equal(column(ok), ok);
  for (const bad of ['', '1ID', 'A B', 'A;', 'A.', 'A[]', 'A[1', 'A[1][2]', 'A:B', 'ID, NAME']) {
    rejects(() => column(bad), /identifier path/);
  }
});

test('literal renders strings, numbers and booleans', () => {
  assert.equal(literal("O'Brien", 'NAME'), "'O''Brien'");
  assert.equal(literal('', 'NAME'), "''");
  assert.equal(literal(12.5, 'AMOUNT'), '12.5');
  assert.equal(literal(-4, 'ID'), '-4');
  assert.equal(literal(0, 'ID'), '0');
  assert.equal(literal(true, 'FLAG'), '1');
  assert.equal(literal(false, 'FLAG'), '0');
});

test('literal refuses what the dialect cannot spell', () => {
  rejects(() => literal(1e-7, 'AMOUNT'), /exponent/);
  rejects(() => literal(1e21, 'AMOUNT'), /exponent/);
  rejects(() => literal(2 ** 53, 'ID'), /safe range/);
  rejects(() => literal(Number.NaN, 'ID'), /not finite/);
  rejects(() => literal(Number.POSITIVE_INFINITY, 'ID'), /not finite/);
  rejects(() => literal(null, 'ID'), /null/);
  rejects(() => literal([1], 'ID'), /array/);
  rejects(() => literal({ a: 1 }, 'ID'), /object/);
  rejects(() => literal(undefined, 'ID'), /undefined/);
});

test('buildDescribe', () => {
  assert.equal(buildDescribe('C:\\d\\KEYS.TPS'), 'DESCRIBE [C:\\d\\KEYS.TPS]');
});

test('buildSelect: the spec example, byte for byte', () => {
  assert.equal(
    buildSelect({ file: 'C:\\pos\\data\\ITEMS.TPS', columns: ['SKU', 'DESC'], where: "PRICE > 5 AND DESC LIKE 'a%'", order_by: 'SKU DESC', limit: 20 }),
    "SELECT SKU, DESC FROM [C:\\pos\\data\\ITEMS.TPS] WHERE PRICE > 5 AND DESC LIKE 'a%' ORDER BY SKU DESC LIMIT 20");
});

test('buildSelect: defaults and optional clauses', () => {
  assert.equal(buildSelect({ file: 'K.TPS' }), 'SELECT * FROM [K.TPS]');
  assert.equal(buildSelect({ file: 'K.TPS', columns: [] }), 'SELECT * FROM [K.TPS]');
  assert.equal(buildSelect({ file: 'K.TPS', where: '  ', order_by: '' }), 'SELECT * FROM [K.TPS]');
  assert.equal(buildSelect({ file: 'K.TPS', limit: 0 }), 'SELECT * FROM [K.TPS] LIMIT 0');
  assert.equal(buildSelect({ file: 'K.TPS', limit: 10, offset: 5 }), 'SELECT * FROM [K.TPS] LIMIT 10 OFFSET 5');
  rejects(() => buildSelect({ file: 'K.TPS', offset: 5 }), /offset requires limit.*limit: 0/);
  rejects(() => buildSelect({ file: 'K.TPS', columns: ['ID; DROP'] }), /identifier path/);
});

test('buildInsert: the spec example', () => {
  assert.equal(
    buildInsert('C:\\pos\\data\\KEYS.TPS', { ID: 9, NAME: "O'Brien", CODE: 'N' }),
    "INSERT INTO [C:\\pos\\data\\KEYS.TPS] (ID, NAME, CODE) VALUES (9, 'O''Brien', 'N')");
  rejects(() => buildInsert('K.TPS', {}), /at least one column/);
  rejects(() => buildInsert('K.TPS', { ID: null }), /null/);
});

test('buildUpdate and buildDelete', () => {
  assert.equal(
    buildUpdate('C:\\pos\\data\\KEYS.TPS', { NAME: 'niner' }, 'ID = 9'),
    "UPDATE [C:\\pos\\data\\KEYS.TPS] SET NAME = 'niner' WHERE ID = 9");
  assert.equal(buildUpdate('K.TPS', { A: 1, B: 'x' }, ' ID = 1 '), "UPDATE [K.TPS] SET A = 1, B = 'x' WHERE ID = 1");
  rejects(() => buildUpdate('K.TPS', {}, 'ID = 1'), /at least one column/);
  rejects(() => buildUpdate('K.TPS', { A: 1 }, ''), /where clause.*1 = 1/);
  rejects(() => buildUpdate('K.TPS', { A: 1 }, undefined), /where clause/);
  assert.equal(buildDelete('K.TPS', 'ID = 9'), 'DELETE FROM [K.TPS] WHERE ID = 9');
  rejects(() => buildDelete('K.TPS', '   '), /where clause/);
});

test('classify', () => {
  assert.equal(classify('SELECT * FROM [K.TPS]'), 'SELECT');
  assert.equal(classify('  \n\tdelete from [K.TPS] where ID = 1'), 'DELETE');
  assert.equal(classify(''), null);
  assert.equal(classify('   '), null);
  assert.equal(classify('[K.TPS]'), null);
  assert.deepEqual([...WRITE_OPS].sort(), ['DELETE', 'INSERT', 'UPDATE']);
});
