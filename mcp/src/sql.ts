// Pure: arguments in, statement text out. Every rule for what tpscli accepts as text lives here;
// whether the statement is valid for the file (column exists, value fits) is the exe's business.

export class InvalidArgument extends Error {
  readonly code = 'INVALID_ARGUMENT';
}

export const WRITE_OPS: ReadonlySet<string> = new Set(['INSERT', 'UPDATE', 'DELETE']);

// ID, ADDR.CITY, QTY[3], ADDR[2].CITY: identifiers with one optional subscript each, joined by dots.
const COLUMN = /^[A-Za-z_]\w*(\[\d+\])?(\.[A-Za-z_]\w*(\[\d+\])?)*$/;

export function bracket(file: string): string {
  if (file.includes(']')) throw new InvalidArgument(`file path contains "]", which the dialect cannot escape: ${file}`);
  return `[${file}]`;
}

export function column(name: string): string {
  if (!COLUMN.test(name)) {
    throw new InvalidArgument(`${JSON.stringify(name)} is not an identifier path such as ID, ADDR.CITY or QTY[3]`);
  }
  return name;
}

export function literal(value: unknown, col: string): string {
  if (typeof value === 'string') return `'${value.replace(/'/g, "''")}'`;
  if (typeof value === 'boolean') return value ? '1' : '0';
  if (typeof value === 'number') {
    const text = String(value);
    if (!Number.isFinite(value)) throw new InvalidArgument(`${col}: ${text} is not finite`);
    if (/e/i.test(text)) throw new InvalidArgument(`${col}: ${text} has no plain decimal form; the dialect has no exponent literal`);
    if (Number.isInteger(value) && !Number.isSafeInteger(value)) {
      throw new InvalidArgument(`${col}: ${text} is outside the safe range and would be rounded`);
    }
    return text;
  }
  if (value === null) throw new InvalidArgument(`${col}: null is not a value (TopSpeed has no NULL); omit the column instead`);
  const kind = Array.isArray(value) ? 'an array' : typeof value === 'object' ? 'an object' : typeof value;
  throw new InvalidArgument(`${col}: a value must be a string, number or boolean, not ${kind}`);
}

export function classify(sql: string): string | null {
  const m = /^\s*([A-Za-z]+)/.exec(sql);
  return m ? m[1].toUpperCase() : null;
}

export function buildDescribe(file: string): string {
  return `DESCRIBE ${bracket(file)}`;
}

export interface SelectArgs {
  file: string;
  columns?: string[];
  where?: string;
  order_by?: string;
  limit?: number;
  offset?: number;
}

export function buildSelect(a: SelectArgs): string {
  const cols = a.columns && a.columns.length > 0 ? a.columns.map(column).join(', ') : '*';
  let sql = `SELECT ${cols} FROM ${bracket(a.file)}`;
  const where = a.where?.trim();
  if (where) sql += ` WHERE ${where}`;
  const order = a.order_by?.trim();
  if (order) sql += ` ORDER BY ${order}`;
  if (a.limit === undefined) {
    if (a.offset !== undefined) throw new InvalidArgument('offset requires limit; pass limit: 0 for no cap');
  } else {
    sql += ` LIMIT ${a.limit}`;
    if (a.offset !== undefined) sql += ` OFFSET ${a.offset}`;
  }
  return sql;
}

function assignments(obj: Record<string, unknown>, what: string): [string, string][] {
  const entries = Object.entries(obj);
  if (entries.length === 0) throw new InvalidArgument(`${what} must name at least one column`);
  return entries.map(([name, value]) => [column(name), literal(value, name)]);
}

function requireWhere(where: string | undefined, op: string): string {
  const text = (where ?? '').trim();
  if (!text) throw new InvalidArgument(`${op} needs a where clause; use 1 = 1 to affect every row`);
  return text;
}

export function buildInsert(file: string, values: Record<string, unknown>): string {
  const pairs = assignments(values, 'values');
  return `INSERT INTO ${bracket(file)} (${pairs.map(p => p[0]).join(', ')}) VALUES (${pairs.map(p => p[1]).join(', ')})`;
}

export function buildUpdate(file: string, set: Record<string, unknown>, where: string | undefined): string {
  const text = requireWhere(where, 'UPDATE');
  const pairs = assignments(set, 'set');
  return `UPDATE ${bracket(file)} SET ${pairs.map(p => `${p[0]} = ${p[1]}`).join(', ')} WHERE ${text}`;
}

export function buildDelete(file: string, where: string | undefined): string {
  return `DELETE FROM ${bracket(file)} WHERE ${requireWhere(where, 'DELETE')}`;
}
