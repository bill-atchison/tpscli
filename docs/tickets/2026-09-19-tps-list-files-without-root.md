# tps_list_files must work with or without `--root`

- Opened: 2026-09-19
- Component: `mcp/` (tpscli-mcp 0.1.0)
- Priority: high
- Status: closed 2026-09-20 (spec docs/mySuperpower/specs/2026-09-20-tpscli-mcp-roots-and-readonly-design.html; commits in feature/tpscli-mcp)

## Problem

`tps_list_files` only lists the folders given as `--root` at startup. A server registered without
`--root` (the plain `claude mcp add -s user tpscli -- node ...\dist\server.js --allow-writes`)
answers every call with `NO_ROOT`, so the model has no way to see which `.TPS` files exist in a
folder even though `tps_describe` / `tps_select` accept any absolute path in that same folder.

Seen: asked to list `C:\Projects\GitLab\POS\dtpos_404_data\CONFIG` on a root-less server; the
tool could not, a plain directory listing had to stand in.

## Expected

`tps_list_files` lists `.TPS` files whether or not roots are configured:

- `tps_list_files({})` with roots: as today, the roots one level deep.
- `tps_list_files({ directory: "C:\\...\\CONFIG" })`: that folder, one level deep. Allowed on a
  server with no roots (mirrors the absolute-path rule the other tools already follow), and on a
  server with roots when the folder is inside a root; outside a root it is refused with
  `FILE_NOT_FOUND`, the same code the file tools use for a path that escapes the roots.
- `tps_list_files({})` with no roots and no `directory`: `INVALID_ARGUMENT` telling the caller to
  pass `directory` (replaces `NO_ROOT`, which then disappears).
- `pattern` keeps working in both modes.
- Changed at implementation (spec section 2): a `directory` outside the roots is listed, not refused; the
  file tools accept any absolute path and the listing follows the same rule. `tps_set_roots` (same spec)
  replaces the roots at runtime.

## Touches

- `docs/mySuperpower/specs/2026-09-19-tpscli-mcp-design.html`: tools table and error-code table.
- `mcp/src/server.ts`: `tps_list_files` schema (`directory?`), handler, `NO_ROOT` removal.
- `mcp/test/server.test.js`: no-root + directory, roots + directory inside, roots + directory
  outside, no-root + no directory.
- `docs/Testing/TpscliMcp-Unit-Test-Cases.html` + `mcp/tests/run-instrument.ps1`: the NO_ROOT case
  becomes the `directory` cases; re-record the run.
- `mcp/README.md`, `docs/UserGuide/TpscliMcp-IT-Support-User-Guide.html`: tool table and flag table.

## Done when

The four server tests pass, the instrument run is green and re-embedded, and a root-less server
lists the CONFIG folder above through the MCP client.
