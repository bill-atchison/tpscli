# tpscli

SQL over TopSpeed files: a Clarion 12 console executable that runs DESCRIBE, SELECT, INSERT,
UPDATE and DELETE against any `.TPS` file, reading the table layout from the file itself, plus
an MCP server that exposes it to LLM clients.

| Folder | What | Read |
| --- | --- | --- |
| `cli/` | `tpscli.exe`: the executable, its Clarion sources, build script, test suites, corpus generator and release gate (`verify.ps1`). | `cli/README.md` |
| `mcp/` | The MCP server that wraps `tpscli.exe` (not started yet). | `mcp/README.md` when it exists |
| `docs/` | Shared documentation: design spec, plan and implementation notes under `docs/mySuperpower/`, the unit-test instrument and its recorded runs under `docs/Testing/`, the IT support user guide under `docs/UserGuide/`. | |

The two components meet at one seam: the exe's JSON response contract and exit codes, documented
in `cli/README.md` under *Response contract* and *Error codes and exit codes*. The MCP treats the
exe as a black box and never reaches into the Clarion sources.

Build and test the CLI from `cli/`; see `cli/README.md` for the MSBuild line and `verify.ps1`.
