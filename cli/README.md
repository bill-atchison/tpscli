# tpscli

A self-contained Clarion 12 console executable that runs a SQL subset against any TopSpeed
file. It reads the table layout out of the `.TPS` file itself, so it needs no dictionary, no
ODBC driver, no layout argument and no rebuild when the data file changes. Writes go through
the real TopSpeed driver via SoftVelocity's `DynFile` runtime file class, so every key is
maintained exactly as the register maintains it; nothing here writes TPS pages by hand.

Row CRUD only. There is no `CREATE TABLE`, `ALTER`, `DROP`, pack, key rebuild, join,
aggregate, subquery, or transaction spanning statements, and no server mode.

This folder is the CLI. The MCP server that wraps it lives in `..\mcp`, and the shared
documentation in `..\docs`. Every relative path and command in this file is from this folder.

## Invocation

```
tpscli.exe [--owner <string>] [--table] [--limit-default N] [--parse-only] "<sql>"
tpscli.exe [options] < statement.sql
tpscli.exe --version
```

| Option | Meaning |
| --- | --- |
| `--owner <string>` | The TopSpeed owner (encryption) string. It is never echoed in output or errors. |
| `--table` | Renders results as an aligned text grid instead of JSON. Everything else is identical. |
| `--limit-default N` | Caps a `SELECT` that has no `LIMIT`. Default 1000. `LIMIT 0` means no cap. |
| `--parse-only` | Runs syntax and schema validation for one statement (it opens the file to read the definition) and never touches a record. Success returns `ok`, `op`, `parse_only: true` and `complete`. |
| `--version` | Prints the version object and exits 0. |

SQL comes from the first non-option argument, or from stdin when no argument is given. Exactly
one statement per invocation. Unknown options, an option without its value, a second positional
argument, empty SQL, or more than one statement are rejected with `SYNTAX` before anything is
opened. `LIMIT`, `OFFSET` and `--limit-default` must be non-negative integers up to
2,147,483,647.

Four further options exist for the test suite and are not part of the supported surface:
`--dump-def <path>` (hex dump of the raw definition record), `--dump-schema` (the oracle-format
schema dump `tests\describe.ps1` diffs against), `--walk-key <name>` (see Deviations) and
`--selftest` (prints three integer wrap-around checks).

### Table names are file paths

The identifier after `DESCRIBE`, `FROM`, `INTO` or `UPDATE` is a path to a `.TPS` file written
in square brackets: `[C:\pos\data\ITEMS.TPS]`. Brackets are always accepted and are required
when the path contains spaces, backslashes or a drive letter. A bare unbracketed name resolves
relative to the current directory. The shell's quotes around the whole statement are a separate
matter from this rule.

## SQL dialect

```
DESCRIBE <file>
SELECT <cols | *> FROM <file> [WHERE <expr>]
       [ORDER BY <col> [ASC|DESC], ...] [LIMIT n [OFFSET m]]
INSERT INTO <file> (<cols>) VALUES (<values>)
UPDATE <file> SET <col> = <value>, ... WHERE <expr>
DELETE FROM <file> WHERE <expr>
```

The `WHERE` grammar, and what each piece becomes as a Clarion filter expression:

| SQL | Becomes (Clarion filter) | Notes |
| --- | --- | --- |
| `=` `<>` `!=` `<` `>` `<=` `>=` | `=` `<>` `<>` `<` `>` `<=` `>=` | Direct. |
| `AND` `OR` `NOT` `(` `)` | Same | Standard precedence: `NOT`, `AND`, `OR`. |
| `'text'` | `'text'` | Doubled quote escapes. Case-sensitive, trailing spaces ignored (Clarion string compare). |
| `123`, `-4.5` | Same | |
| `col LIKE 'AB%'` | `MATCH(col,'AB*',1)` | `%` becomes `*`, `_` becomes `?`. The mode is the literal `1` (`Match:Wild`), since equates are not visible to runtime expressions. |
| `col IN ('a','b')` | `INLIST(col,'a','b')` | Also handles `NOT IN`. |
| `col IS NULL` | Rejected | TPS has no NULL. Compare to `''` or `0` instead. The error says so. |
| `'2026-09-15'` against a `DATE` column | `DATE(9,15,2026)` | Same for `TIME` with `'13:45:00'`. Conversion is driven by the column type, not the literal shape. |

Column names are resolved against the file's schema before anything runs. An unknown column is
a parse-time error naming the column and listing the valid ones. Group members are addressed
with dots, array elements with brackets, and each dimension is indexed at the component that
owns it: `ADDR.CITY`, `QTY[3]`, `ADDR[2].CITY`. Subscripts are 1-based, and one subscript per
component: a `DIM(a,b)` field takes a single flat index, not `GRID[2][3]` (see Deviations). In a
`SELECT` list, naming a group or a whole array expands to its scalar leaves in declaration
order, and `*` uses the same expansion. Assignments in `INSERT` and `SET` must address
individual leaves. Missing, extra or out-of-range subscripts are rejected before anything is
opened for write.

Anything outside that grammar is refused with a parse error quoting the offending token and
position: `JOIN`, `GROUP BY`, `HAVING`, `DISTINCT`, aggregate functions, subqueries, `UNION`,
arithmetic in expressions, `UPDATE` or `DELETE` without `WHERE`, `INSERT` with no column list,
an `INSERT` whose column and value counts differ, and a column named twice in one `INSERT` list
or `SET` clause.

## Response contract

Output is JSON on stdout, including error responses, so a caller reading one stream gets
everything. Diagnostic noise, if any, goes to stderr. `complete` is the last top-level member
before the closing brace. In `--table` mode the last line is a summary (`(n rows)` or
`ERROR CODE: message`) and the exit codes are unchanged.

- Every response has boolean `ok` and `complete`, and `op` (one of `describe` `select` `insert`
  `update` `delete`, or `null` when the statement could not be recognised).
- `DESCRIBE` success: `file`, `encrypted`, `records`, `columns`, `keys`. Columns keep their
  nested `members` and `dim` metadata. The key attributes `nocase` and `optional` are omitted
  when false.
- `SELECT` success: `columns`, `rows`, `row_count`, `truncated`. Every row array has the same
  length and order as `columns`. `truncated` is true only when, after the cap was reached, one
  more matching row was found; an exhausted filter returns `truncated: false`, and no matches
  returns `rows: []` with `row_count: 0` and `ok: true`. Rows are buffered until the scan
  finishes, so a read error mid-scan produces an error response and never a partial success.
- `INSERT` success: `affected`. `UPDATE` and `DELETE` success: `matched` and `affected`.
- With `--parse-only` the success object is only `ok`, `op`, `parse_only: true` and `complete`.
- Failure: `error.code` and `error.message`, plus whichever of these apply: `error.position`
  and `error.token` (syntax), `error.column`, `error.key`, `error.row` (primary key value or
  position string), `error.errorcode`, `error.fileerrorcode`, `error.fileerror` (driver).
- Write failures also carry `outcome`: `"none"` (no data changed: validation failed before any
  write, or a single-row `INSERT` was rejected by the driver), `"rolled_back"` (a transaction
  was open and `ROLLBACK` returned no error), or `"unknown"` (`ROLLBACK` or `COMMIT` reported
  an error, so the state on disk is not known). `WHERE_REQUIRED` and other exit-1 errors carry
  `"none"`.
- Non-fatal truncation of a string value adds a `warnings` array of
  `{ "code": "STRING_TRUNCATED", "column": ..., "message": ... }`.
- The exe accepts SQL only. There is no JSON request format.

A missing or unparseable final object means the response is incomplete and the write outcome is
unknown. It proves neither commit nor rollback, and the caller must not assume `affected: 0` or
retry on its own.

Value formatting: `DATE` as `YYYY-MM-DD`, `TIME` as `HH:MM:SS.hh`, `DECIMAL` as an exact
string, `BLOB` as base64. The file is opened with `SHARE()`; records are taken with
`HOLD(file, 1)` and there are no retries.

### Examples

```
tpscli.exe "DESCRIBE [testdata\KEYS.TPS]"
tpscli.exe "SELECT ID, NAME FROM [testdata\KEYS.TPS] WHERE NAME LIKE 'b%' ORDER BY ID LIMIT 2"
tpscli.exe "INSERT INTO [testdata\KEYS.TPS] (ID, NAME, CODE) VALUES (9, 'nine', 'N')"
tpscli.exe "UPDATE [testdata\KEYS.TPS] SET NAME = 'niner' WHERE ID = 9"
tpscli.exe "DELETE FROM [testdata\KEYS.TPS] WHERE ID = 9"
```

```json
{ "ok": true, "op": "select",
  "columns": [{"name":"ID","type":"LONG"},{"name":"NAME","type":"STRING"}],
  "rows": [[2,"baker"]], "row_count": 1, "truncated": false, "complete": true }
```

## Error codes and exit codes

| Exit | Meaning |
| --- | --- |
| 0 | Statement ran. `ok` is true. |
| 1 | Syntax or validation error. No data was modified. Schema validation may have opened and read the file. |
| 2 | File error: not found, unsupported definition, wrong owner string, access denied. |
| 3 | Runtime error during execution: lock conflict, duplicate key, driver error. Writes were rolled back when the rollback itself succeeded; see `outcome`. |

| Code | Exit | When |
| --- | --- | --- |
| `SYNTAX` | 1 | Tokenizer or grammar failure. Includes `position` and `token`. |
| `UNKNOWN_COLUMN` | 1 | Column not in the schema. Lists valid names. |
| `WHERE_REQUIRED` | 1 | `UPDATE` or `DELETE` without `WHERE`. |
| `UNSUPPORTED` | 1 | Valid SQL outside the subset (JOIN, aggregates, `IS NULL`, `LIMIT` on a write). |
| `FILE_NOT_FOUND` | 2 | |
| `OWNER_REQUIRED`, `OWNER_WRONG` | 2 | Encrypted file; the owner string is never echoed. |
| `UNSUPPORTED_FIELD_TYPE` | 2 | The definition record has a type code that is not in the table. |
| `DEFINITION_UNREADABLE` | 2 | Header or definition record fails to parse, or `DynFile` cannot build the structure. Suggests TPSFix. |
| `DEFINITION_MISMATCH` | 2 | Driver error 47 at OPEN: the built structure does not match the file's stored definition. |
| `DUPLICATE_KEY` | 3 | Names the key. |
| `RECORD_HELD` | 3 | Names the row by its primary key value when one exists, else by position. |
| `VALUE_OUT_OF_RANGE` | 3 | Any literal that cannot be converted for its column: integer overflow or fraction, decimal overflow after rounding, invalid date or time, invalid base64. Names the column. |
| `DRIVER` | 3 | Anything else from the driver: `ERRORCODE()`, `FILEERRORCODE()` and both messages. |

## Deviations

Everything below was found while building the exe against real TopSpeed files. Each item is
behaviour a caller can see, not an internal note.

- **No VIEW, so `ORDER BY` without a matching key sorts in memory.** A key is used when one
  starts with the same columns in the same directions (or exactly reversed). Otherwise the
  matching rows are buffered and sorted, capped at four `ORDER BY` columns; a fifth is
  `UNSUPPORTED`. Optional keys are never chosen for `ORDER BY`, because an OPT key silently
  omits rows whose components are all blank or zero. `NOCASE` keys are eligible and change
  case-sensitive ordering expectations.
- **Real field labels are bound for the filter expression.** `WHERE` is evaluated by the Clarion
  runtime against the record's real `PREFIX:LABEL` names taken from `WHO()`, not `_Fn`
  placeholders.
- **`PRIMARY` and key metadata.** Key flag `0x10` is `PRIMARY`; an `INDEX` reports `dup=1`; key
  component ordinals are 0-based in the stored definition; a `DECIMAL` definition stores packed
  bytes, so digits are `2*bytes-1`; memo flag `0x02` is `BINARY` and `0x04` is `BLOB`.
- **`DESCRIBE` does not distinguish a `KEY` from an `INDEX`.** Both appear in `keys` with the
  same shape. Only the hidden `--dump-schema` output carries the `"K"`/`"I"` distinction.
- **An `INDEX` walks zero rows until it is BUILT.** The TopSpeed driver populates an `INDEX`
  only on `BUILD`, which tpscli never issues, so a file whose index was never built has an
  empty index. The corpus's `IDX` is in that state and `verify.ps1` records it as a note. For
  the same reason `ORDER BY` never selects an `INDEX`: ordering by an unbuilt one would return
  no rows with `ok: true`, so only real keys are eligible and everything else falls back to the
  in-memory sort.
- **MEMO and BLOB access.** MEMO content is read and written through `F{PROP:Value,-n}` and BLOB
  content through `F{PROP:Blob,-n}`, with base64 in and out for BLOB. There is no addressable
  memo reference, so memos are handled by value.
- **A leaf inside a DIM'd GROUP is read-only.** For example `PHONES[2].KIND`: `SELECT` reads it
  by slicing the group occurrence's raw bytes, but `WHERE` and `ORDER BY` on it are
  `UNSUPPORTED`, and `INSERT`/`UPDATE` assignment to it is `UNSUPPORTED` ("Assign leaves inside
  a dimmed group"). Plain array subscripts (`ARR[2]`) and plain nested GROUP members
  (`ADDR.GEO.LAT`) work everywhere.
- **A `STRING` declared with a picture does not round-trip a literal, and a literal the
  picture cannot read is refused.** `ALLTYPES.PIC` is `STRING(@N9.2)`. Its reported type is
  plain `STRING`, but the Clarion runtime deformats and reformats the value on assignment, so
  `'7'` and `'00007.00'` both store `00007.00`. A literal carrying no digit at all, such as
  `'rrr'`, cannot be stored: it would land as the picture's zero, `00000.00`. That is a
  conversion failure, so `INSERT` and `UPDATE` refuse it with `VALUE_OUT_OF_RANGE` and the
  message `<column> does not match picture @<picture>` rather than writing it silently. The
  empty literal is accepted and stores the picture's zero, which is what an unassigned column
  holds anyway. Because no literal survives a picture column unchanged, `verify.ps1` leaves
  such a column out of its generic round trip, records it as a note, and separately asserts
  that writing `'rrr'` to it is refused.
- **`DECIMAL` output trims trailing fraction zeros.** `10.00` in a `DECIMAL(7,2)` prints `"10"`,
  and zero prints `"0"`.
- **An even-digit `DECIMAL` is reported one digit too wide, and cannot be otherwise.** The stored
  definition records the packed storage-byte count, not the declared digit count, so the digit
  count is recovered as `2*bytes-1`. That is exact for an odd width and one too many for an even
  one: a `DECIMAL(6,2)` occupies the same four bytes as a `DECIMAL(7,2)` and the two are
  indistinguishable in the file. `DESCRIBE` therefore reports `"size": 7` for a `DECIMAL(6,2)`,
  which will show as a difference against a dictionary export, and literal validation accepts one
  digit more than the owning application can read back. There is no fix available from the file
  alone. The corpus has only odd-width DECIMAL fields, so the
  `verify.ps1 -Extra -Expected` run against real dtpos files is where this first becomes visible.
- **`DIM(a,b)` is flattened to a single extent.** A two-dimensional array is reported and
  addressed as one dimension of `a*b`: `GROUPS.GRID`, declared `DIM(2,3)`, expands to `GRID[1]`
  through `GRID[6]` and `DESCRIBE` reports `"dim": 6` where a dictionary export says 2,3. A
  second subscript is rejected with `UNKNOWN_COLUMN` (`GRID does not have a second dimension`);
  use the flat index instead. The parser never sets a second extent, so the two-subscript form
  the WHERE and SELECT grammar can express is unreachable on every file.
- **`INSERT`/`UPDATE` literal validation happens at parse time**, so a `VALUE_OUT_OF_RANGE` for a
  bad literal carries the parser's error shape (`position` and `token`) and `outcome: "none"`.
- **Inside an open transaction every failure exits 3**, including a runtime rejection of the
  filter expression during the write pass. Exit 1 promises that no data was modified, and that
  promise cannot be made once a transaction is open.
- **`UPDATE`'s `DUPLICATE_KEY` carries `row`, not `key`.** `INSERT`'s carries `key`. The driver's
  error-40 text names no key, so `INSERT` falls back to the primary key, or the first unique key
  when there is no primary.
- **`--table` mode prints only `CODE: message` on failure**, without `matched` or `affected`.
- **`PDECIMAL` cannot exist in a TopSpeed file.** The driver rejects `CREATE` with error 47, so
  it was removed from the corpus. A file that somehow declares one reports
  `UNSUPPORTED_FIELD_TYPE`.
- **Clarion's `MATCH` regular mode has no `{m,n}` quantifier**, so validation patterns use `+`
  with explicit length checks.
- **TPSFix is replaced by a key-walk integrity check.** TPSFix has no verified command-line
  interface, so `verify.ps1` instead walks every key with the hidden `--walk-key <name>` option,
  which prints
  `{ "ok": true, "op": "walk-key", "key": "<label>", "count": N, "ordered": true, "complete": true }`,
  and requires the count to match the record count (less the blank rows for an OPT key) with
  `ordered` true. When `-Extra` is given, `verify.ps1` additionally requires `-TpsFixLog <file>`,
  a log saved from a manual TPSFix run over those same files on the same day, and fails unless
  it is clean.
- **The hidden `--dump-schema` output does not follow the response contract.** It is an oracle
  dump with `file`, `fields`, `memos` and `keys` and no `ok`/`complete`.
- **Every exe invocation in the test scripts runs under a timeout**, because a crashed Clarion
  exe blocks behind a modal runtime dialog instead of exiting.

## Build

Clarion 12.0.14000 at `C:\Clarion12`, static Lib link model, StringTheory and DynFile resolved
through `CLARION120.RED` (no project entries). The console subsystem comes from `tpscli.exp`
beside the `.cwproj`; stdout is `GetStdHandle(-11)` plus `WriteFile`, because Clarion has no
console I/O statements.

```
C:\Windows\Microsoft.NET\Framework\v4.0.30319\MSBuild.exe tpscli.cwproj /t:Rebuild /p:Configuration=Release /p:ClarionBinPath="C:\Clarion12\bin" /p:clarion_version="Clarion 12.0.14000" /v:minimal
```

`tools\build.ps1 -Proj <cwproj>` wraps that command and additionally checks that the produced
image really is a console-subsystem executable. Build success is the exe's timestamp advancing
with zero `error` lines in the MSBuild output, not the exit code alone.

## Verification

```
powershell -NoProfile -ExecutionPolicy Bypass -File verify.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File verify.ps1 -Extra <dir> -Expected <dir> -TpsFixLog <file>
```

`verify.ps1` is the release gate. It rebuilds all three projects, regenerates the corpus, runs
the five test scripts under `tests\`, round-trips every corpus file (DESCRIBE, INSERT one row
covering every writable leaf, SELECT and compare field for field, UPDATE every writable leaf,
SELECT and compare, DELETE, DESCRIBE again), walks every key, checks shared access against a
second process holding a record, and times a keyed SELECT. It exits non-zero on any failure,
and every verdict comes from its own comparisons rather than from the exe's exit code.

`-Extra <dir>` points at a folder of real-world `.TPS` files, which are never committed; it
requires `-TpsFixLog`. `-Expected <dir>` adds dictionary parity for those files against
oracle-format JSON exports.

Without those three options the dictionary-parity and TPSFix steps do not run. They print
`SKIP`, not `PASS`, and the closing line says how many were skipped:
`all steps PASS (2 skipped - not a release qualification)`. A run that qualifies a release is
the one with all three options given against real files, where nothing is skipped.

`tests\helpers.ps1` is a regression check for the shared `Invoke-Tpscli_Bounded` helper in
`tests\TestHelpers.ps1` (300 timed runs of `--version` plus one empty-argument run); it is not
part of `verify.ps1`.

### Unit-test instrument

`..\docs\Testing\Tpscli-Unit-Test-Cases.html` is a self-contained, offline test document: 32 cases
in six sections, ticked and recorded in the browser, with a dashboard, resumable state and a
printable completion report. It opens showing the most recent recorded run. Two scripts automate it:

```
powershell -NoProfile -ExecutionPolicy Bypass -File tests\run-instrument.ps1
node --experimental-websocket tests\record-instrument.js
```

`run-instrument.ps1` reads the case list out of the instrument itself, runs every case's steps
under the same timeout helper as the other suites, asserts the values each case's expected text
names, and writes `..\docs\Testing\Tpscli-Unit-Test-Results.json`. `record-instrument.js` drives a
headless Chrome or Edge over the DevTools protocol, records that JSON into the page through the
page's own engine functions, checks the dashboard tally, and prints the report to
`..\docs\Testing\Tpscli-Unit-Test-Report-<date>.pdf`. TC-28 (release qualification against real
dtpos files) is always `BLOCKED` in this repository because its inputs are not committed.

## Documentation

- `..\docs\UserGuide\Tpscli-IT-Support-User-Guide.html`: install, operate and troubleshoot the exe,
  for support staff and script authors.
- `..\docs\Testing\`: the unit-test instrument, the latest results JSON and the PDF report.
- `..\docs\mySuperpower\specs\2026-09-15-tpscli-design.html`: the design spec;
  `..\docs\mySuperpower\plans\2026-09-15-tpscli.html`: the task-by-task plan;
  `..\docs\mySuperpower\implementation-notes\2026-09-16-tpscli.html`: decisions and findings from
  the build.
