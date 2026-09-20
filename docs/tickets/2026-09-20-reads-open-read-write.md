# DESCRIBE and SELECT open the file read/write, so a read moves its modified time

- Opened: 2026-09-20
- Component: `cli/` (tpscli.exe 0.1.0), surfaces through the MCP server too
- Priority: normal
- Status: open

## Problem

`tpsSchema.Open` opens every file with `SHARE(SELF.F)` (ReadWrite + DenyNone), whatever the
statement. The TopSpeed driver then touches the file on close, so a `DESCRIBE` or a `SELECT`
moves the file's `LastWriteTime` even though not one byte changes (verified on the dtpos CONFIG
folder: SHA-256 identical before and after a describe plus a full select; mtime advanced to now).

Consequences: a folder of production copies looks "changed" after a read-only pass (backup tools,
`robocopy /XO`, anyone comparing timestamps); the read-only MCP server (no `--allow-writes`)
still needs write permission on the folder or the open fails; and a read on a file that is
open elsewhere with DenyWrite is refused.

Seen while building `docs/Testing/TpscliMcpConfig-Unit-Test-Cases.html` (TC-09 records the
hash check; the mtime move is noted as a watch-point).

## Expected

`DESCRIBE`, `SELECT` and `--parse-only` open the file ReadOnly + DenyNone (`OPEN(F, 40h)`);
`INSERT`, `UPDATE` and `DELETE` keep `SHARE`. A read then leaves the modified time alone and
works on a folder the account can only read. The `RECORD_HELD` behaviour of writes is unchanged.

## Touches

- `cli/tpsSchema.clw` `tpsSchema.Open` (needs to know whether the statement writes; the caller in
  `cli/tpscli.clw` knows the op) and `cli/tpsSchema.inc`.
- `cli/tests/select.ps1` or `describe.ps1`: one case comparing LastWriteTime before and after a
  SELECT on a corpus copy; one case reading a file from a read-only folder.
- `cli/README.md` (Deviations / behaviour), `docs/UserGuide/Tpscli-IT-Support-User-Guide.html`
  (the "opens the data file in shared mode" tip), the MCP guide's watch-point and
  `docs/Testing/TpscliMcpConfig-Unit-Test-Cases.html` TC-09 wording.

## Done when

A SELECT on a copy leaves its LastWriteTime unchanged, a SELECT on a file in a folder with
read-only permissions succeeds, and the two new CLI cases plus `verify.ps1` are green.
