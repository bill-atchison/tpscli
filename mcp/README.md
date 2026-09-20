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

One entry in the client's MCP configuration. Claude Code, from any folder (`-s user` registers
it for every project; drop it to register for the current folder only):

```
claude mcp add -s user tpscli -- node "C:\Projects\GitHub\tpscli\mcp\dist\server.js" --root "C:\pos\data"
claude mcp list          # tpscli: ... - Connected
```

Open a new session afterwards (or `/mcp` in a running one); servers attach at startup. Remove
with `claude mcp remove -s user tpscli`. `--root` is optional: without it every tool needs an
absolute path and `tps_list_files` has nothing to list (`NO_ROOT`; see
`..\docs\tickets\2026-09-19-tps-list-files-without-root.md`).

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

## Call a tool from the command line

`tools\call.js` starts the server with the flags you give it, calls one tool with a JSON object read
from stdin, prints the result and exits 0 (answered), 1 (the tool answered with an error) or 2 (the
server could not start). Useful for support checks and for the test instrument. From PowerShell,
keep the JSON in single quotes:

```
'{"file":"KEYS.TPS"}' | node tools\call.js tps_describe --root C:\pos\data
'{"file":"KEYS.TPS","limit":5,"format":"table"}' | node tools\call.js tps_select --root C:\pos\data
node tools\call.js tps_version
```

## Server flags

| Flag | Default | Meaning |
| --- | --- | --- |
| `--exe <path>` | `TPSCLI_EXE`, else `tpscli.exe` beside `server.js`, else `..\..\cli\tpscli.exe` | Path to the exe. Missing exe fails at startup. |
| `--root <dir>` | none | Repeatable. Bare file names resolve inside these folders, in order; `tps_list_files` lists them. Must exist. |
| `--allow-writes` | off | Enables `INSERT`, `UPDATE` and `DELETE`, structured and raw. |
| `--owner <string>` | `TPSCLI_OWNER`, else none | Owner (encryption) string for every call that does not pass its own. Never printed. |
| `--timeout <seconds>` | 60 | Wall-clock limit per exe run; the process tree is killed past it. |

Startup problems (bad flag, missing exe, missing root) exit 2 with the reason on stderr. While
running, one line per call goes to stderr: tool, duration, exit code, and the failure kind if any.

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
and `outcome` is passed through for writes. The statement is passed to the exe on stdin, so a "
inside a value is fine and the only size limit is the exe's own expression limit; flags go on the
command line. Errors the server raises itself use the same shape:

| Code | When |
| --- | --- |
| `WRITES_DISABLED` | A write without `--allow-writes`. `outcome: "none"`. |
| `NO_ROOT` | `tps_list_files` on a server with no `--root`. |
| `FILE_NOT_FOUND` | A bare name not found inside the roots, or a path that escapes them. |
| `INVALID_ARGUMENT` | Empty `set`/`values`, blank `where`, bad column name, `null`, exponent or unsafe number, `offset` without `limit`, `]` in a path, table format on a write, a NUL byte in the owner string. |
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
tools/call.js    one tool call from the command line
tests/run-instrument.ps1, record-instrument.cjs, embed-run.py   the unit-test instrument's automation
```

## Documentation

- `..\docs\UserGuide\TpscliMcp-IT-Support-User-Guide.html`: the IT support user guide for this server
  (install, tools, results, troubleshooting); the CLI has its own guide beside it.
- `..\docs\tickets\`: open issues, one file each.
- `..\docs\Testing\TpscliMcp-Unit-Test-Cases.html`: the interactive unit-test instrument for this
  server (16 cases driven through `tools\call.js` against copies of the corpus under `work\`).
  It opens showing the last recorded run; `New Run` clears it. To record a run yourself, from
  this folder (the CLI built and its corpus generated first):

  ```
  powershell -NoProfile -ExecutionPolicy Bypass -File tests\run-instrument.ps1
  node --experimental-websocket tests\record-instrument.cjs
  python tests\embed-run.py
  ```

  The first runs every case and writes `..\docs\Testing\TpscliMcp-Unit-Test-Results.json`; the
  second loads that run into the page through its own engine in headless Chrome and prints
  `..\docs\Testing\TpscliMcp-Unit-Test-Report-<date>.pdf`; the third embeds the saved state in
  the instrument (`SEED_STATE`).
- `..\docs\mySuperpower\specs\2026-09-19-tpscli-mcp-design.html`, the plan beside it under `plans\`,
  and `..\docs\mySuperpower\implementation-notes\2026-09-19-tpscli-mcp.html`.
