# tpscli-mcp

MCP server that exposes `tpscli.exe` (SQL over TopSpeed files) to an LLM client over stdio.
It runs on the machine that holds the `.TPS` files, treats the exe as a black box, and passes
its JSON through unchanged, so `..\cli\README.md` (*Response contract*, *Error codes and exit
codes*) is the contract here too. Design: `..\docs\mySuperpower\specs\2026-09-19-tpscli-mcp-design.html`.

## Install

Node 20 or later. From this folder:

```
npm install
npm run build        # writes dist\server.js
npm test             # unit tests with a fake exe; e2e when ..\cli\tpscli.exe and the corpus exist
```

## Configure a client

One entry in the client's MCP configuration. Claude Code, from any folder:

```
claude mcp add tpscli -- node "C:\Projects\GitHub\tpscli\mcp\dist\server.js" --root "C:\pos\data"
```

Claude Desktop (`claude_desktop_config.json`):

```json
{
  "mcpServers": {
    "tpscli": {
      "command": "node",
      "args": ["C:\\Projects\\GitHub\\tpscli\\mcp\\dist\\server.js", "--root", "C:\\pos\\data"],
      "env": { "TPSCLI_OWNER": "the owner string, if the files are encrypted" }
    }
  }
}
```

Append `"--allow-writes"` to `args` when the model may change rows. Without it the server is
read-only.

## Server flags

| Flag | Default | Meaning |
| --- | --- | --- |
| `--exe <path>` | `TPSCLI_EXE`, else `tpscli.exe` beside `server.js`, else `..\..\cli\tpscli.exe` | Path to the exe. Missing exe fails at startup. |
| `--root <dir>` | none | Repeatable. Bare file names resolve inside these folders, in order; `tps_list_files` lists them. Must exist. |
| `--allow-writes` | off | Enables `INSERT`, `UPDATE` and `DELETE`, structured and raw. |
| `--owner <string>` | `TPSCLI_OWNER`, else none | Owner (encryption) string for every call that does not pass its own. Never printed. |
| `--timeout <seconds>` | 60 | Wall-clock limit per exe run; the process tree is killed past it. |

Startup problems (bad flag, missing exe, missing root) exit 2 with the reason on stderr. While
running, one line per call goes to stderr: tool, duration, exit code.

## Tools

| Tool | Arguments | Runs |
| --- | --- | --- |
| `tps_version` | | `--version`; returns `{ server, exe }` |
| `tps_list_files` | `pattern?` (`*.TPS`) | no exe; `{ files: [{ name, path, size, modified }] }` from the roots, one level deep |
| `tps_describe` | `file`, `owner?` | `DESCRIBE [file]` |
| `tps_select` | `file`, `columns?`, `where?`, `order_by?`, `limit?`, `offset?`, `format?`, `owner?` | built `SELECT`; `limit` omitted = exe default 1000, `0` = no cap, `offset` needs `limit` |
| `tps_insert` | `file`, `values`, `owner?` | built `INSERT` |
| `tps_update` | `file`, `set`, `where`, `owner?` | built `UPDATE` |
| `tps_delete` | `file`, `where`, `owner?` | built `DELETE` |
| `tps_query` | `sql`, `owner?`, `limit_default?`, `parse_only?`, `format?` | the statement verbatim, no root resolution |

`file` is an absolute path, or a bare name resolved inside the roots. `where` and `order_by` are
fragments in the exe's dialect. Values: strings, numbers (DECIMAL columns take numbers, never
quoted), booleans (`1`/`0`); dates `'YYYY-MM-DD'`, times `'HH:MM:SS.hh'`, BLOB base64; `null`
is refused (TopSpeed has no NULL; omit the column). `format: "table"` returns the `--table` grid
as text and is not available for writes.

## Results

A tool result is the exe's response object, as `structuredContent` and as pretty-printed text.
`isError` is true for any non-zero exit; the object's `error.code` and `error.message` explain,
and `outcome` is passed through for writes. Errors the server raises itself use the same shape:

| Code | When |
| --- | --- |
| `WRITES_DISABLED` | A write without `--allow-writes`. `outcome: "none"`. |
| `NO_ROOT` | `tps_list_files` on a server with no `--root`. |
| `FILE_NOT_FOUND` | A bare name not found inside the roots, or a path that escapes them. |
| `INVALID_ARGUMENT` | Empty `set`/`values`, blank `where`, bad column name, `null`, exponent or unsafe number, `offset` without `limit`, `]` in a path, table format on a write. |
| `INCOMPLETE` | Timeout, spawn failure, output over 64 MiB, exit outside 0-3, or no valid response object. `complete: false`; for a write `outcome: "unknown"`. The write may or may not have happened: check the file, do not retry blindly. |

A malformed argument (wrong type, missing required field) is rejected by the SDK before the
handler runs: the result is `isError: true` with the text `MCP error -32602: Input validation
error: Invalid arguments for tool ...` and no `structuredContent`.

## Layout

```
src/server.ts    tools, policy, argv, stdio transport
src/sql.ts       statement builder and literal rules
src/runner.ts    spawn, timeout, output ceiling, response validation
test/*.test.js   node --test; fake-tpscli.js stands in for the exe
```
