# tpscli

SQL over TopSpeed files: a Clarion 12 console executable that runs DESCRIBE, SELECT, INSERT,
UPDATE and DELETE against any `.TPS` file, reading the table layout from the file itself, plus
an MCP server that exposes it to LLM clients.

| Folder | What | Read |
| --- | --- | --- |
| `cli/` | `tpscli.exe`: the executable, its Clarion sources, build script, test suites, corpus generator and release gate (`verify.ps1`). | `cli/README.md` |
| `mcp/` | The MCP server that wraps `tpscli.exe`: nine tools over stdio, read-only unless started with `--allow-writes`. | `mcp/README.md` |
| `docs/` | Shared documentation: design specs, plans and implementation notes under `docs/mySuperpower/`, the unit-test instruments and their recorded runs under `docs/Testing/`, the IT support user guides (one for the CLI, one for the MCP server) under `docs/UserGuide/`, open issues under `docs/tickets/`. | |

The two components meet at one seam: the exe's JSON response contract and exit codes, documented
in `cli/README.md` under *Response contract* and *Error codes and exit codes*. The MCP treats the
exe as a black box and never reaches into the Clarion sources.

Build and test the CLI from `cli/`, the MCP server from `mcp/`; see each folder's README.

## Install the MCP server

Node 20 or later and a built `cli\tpscli.exe`. From `mcp\`: `npm install`, `npm run build`, then
register the server with the client. Claude Code, for every project:

```
claude mcp add -s user tpscli -- node "C:\Projects\GitHub\tpscli\mcp\dist\server.js" --root "C:\pos\data"
```

`--root` (repeatable) is where bare file names resolve and what `tps_list_files` lists; it can
be changed while the server runs (`tps_set_roots`), and `tps_list_files` lists any folder given as
`directory`; add `--allow-writes` to enable INSERT/UPDATE/DELETE, `--owner` (or `TPSCLI_OWNER`) for encrypted
files. Claude Desktop takes the same command and arguments in `claude_desktop_config.json`; the
full flag table is in `mcp/README.md`.

| Tool | Does |
| --- | --- |
| `tps_version` | server and exe versions |
| `tps_list_files` | `.TPS` files under the roots, or in any `directory` |
| `tps_set_roots` | replace the roots for this session |
| `tps_describe` | fields, keys and record count of one file |
| `tps_select` | rows: columns, where, order, limit, offset, JSON or table |
| `tps_insert`, `tps_update`, `tps_delete` | one built statement each (needs `--allow-writes`) |
| `tps_query` | a raw statement in the exe's dialect |
