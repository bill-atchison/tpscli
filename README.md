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

## Install from a release

Releases (`https://github.com/<owner>/tpscli/releases`) carry one zip per version,
`tpscli-<version>-win-x64.zip`, with its SHA-256 beside it. Unzip it anywhere; it holds
`dist\server.js` with `tpscli.exe` beside it, the production `node_modules`, `tools\call.js`
and the guides under `docs\`. With Node 20 or later installed, register the server:

```
claude mcp add -s user tpscli -- node "C:\tools\tpscli-0.2.0-win-x64\dist\server.js" --allow-writes
```

No build, no npm. `node tools\call.js tps_version` from the unzipped folder checks the install.

## Cutting a release (maintainers)

A push of a tag `v<version>` runs `.github\workflows\release.yml` on the self-hosted Windows
runner labelled `clarion`; it runs `tools\release.ps1` (the CLI gate `cli\verify.ps1`, `npm ci`,
`npm run build`, `npm test`, then the zip) and publishes the zip, its `.sha256` and `notes.md`
as a GitHub Release. `<version>` must equal `mcp\package.json`'s version. The gate is the
repository's own generated corpus and suites: tpscli reads every layout from the `.TPS` file and
depends on no dictionary, so no site files are involved. `verify.ps1`'s real-file checks
(`-Extra`, `-Expected`, `-TpsFixLog`) stay available for a site to run against its own files
before adopting a build; `release.ps1` forwards them when given. Without the runner, run
`tools\release.ps1 -Version v<version>` by hand and `gh release create v<version> release\*.zip
release\*.sha256 --notes-file release\notes.md`.

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
