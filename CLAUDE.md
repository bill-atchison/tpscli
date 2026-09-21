# tpscli

Clarion 12 console exe that runs a SQL subset (DESCRIBE/SELECT/INSERT/UPDATE/DELETE) against any TopSpeed file, reading the layout from the file itself, plus an MCP server that wraps it. Standalone; not part of dtpos.

Hand-coded project. No `.app`, no templates, no generator, no IDE required. Build from a shell, edit with normal file tools.

- Spec: `docs/mySuperpower/specs/2026-09-15-tpscli-design.html`
- Plan: `docs/mySuperpower/plans/2026-09-15-tpscli.html` (task by task, TDD; Task 1 creates the cwproj/exp/clw files). The plan says `C:\Projects\tpscli` with everything at the root; this repo is `C:\Projects\GitHub\tpscli` and the CLI lives under `cli/`.
- Running decisions log: `docs/mySuperpower/implementation-notes/2026-09-16-tpscli.html` (controller-owned; implementers put findings in their reports)

## Layout

- `cli/`: the executable. `tpscli.cwproj`, `tpscli.exp` (NAME 'tpscli' CUI), `tpscli.clw`, `tpsOut|tpsSchema|tpsSql|tpsExec.inc/.clw`; `tools/build.ps1`, `verify.ps1`; `tests/` (parser.sql + expected, per-task .ps1 suites, `run-instrument.ps1` + `record-instrument.js` for the instrument); `testdata/gen/` corpus generator (mkcorpus), `testdata/expected/*.json` oracle dumps; generated `.TPS` files are gitignored. Every `cli` script anchors on its own location, so run them from `cli/`.
- `mcp/`: the MCP server (its own toolchain, tests and README; treats `tpscli.exe` as a black box, never imports the Clarion sources).
- `docs/`: shared. `docs/Testing/` (unit-test instrument, results JSON, PDF report), `docs/UserGuide/`, `docs/mySuperpower/`. The feature-docs skills anchor these at the repo root; the CLI scripts reach them with one `..`.

## Build (from `cli/`)

Clarion 12.0.14000 at `C:\Clarion12`, static Lib model, StringTheory and DynFile via `CLARION120.RED` (no project entries).

```
C:\Windows\Microsoft.NET\Framework\v4.0.30319\MSBuild.exe tpscli.cwproj /t:Rebuild /p:Configuration=Release /p:ClarionBinPath="C:\Clarion12\bin" /p:clarion_version="Clarion 12.0.14000" /v:minimal
```

Success is the exe's timestamp advancing and zero `error` lines in MSBuild output, not the exit code alone. Console subsystem comes from `tpscli.exp` beside the cwproj; confirm `obj\release\tpscli.cwproj.FileList.xml` lists TPSCLI.EXP, not CLAWSTD.EXP.

Reference sources, read them rather than guessing an API: `C:\Clarion12\libsrc\win\DynFile.inc` / `.clw`, `C:\Clarion12\accessory\libsrc\win\StringTheory.inc`.

## Clarion conventions

- `.inc` holds the CLASS declaration; `.clw` holds the `MEMBER` / `MAP` / method bodies. Keep them in sync: every method declared in the .inc has a body in the .clw and vice versa.
- Clarion has no console I/O statements. Stdout is `GetStdHandle(-11)` + `WriteFile`.
- Lib-linked exes cannot use `PROP:Driver`; declare a static driver placeholder FILE.
- `DynFile.FixFormat` shows a modal MESSAGE on error; the derived class shadows it.

## Line endings

Every source file is CRLF. Edit `.clw`, `.inc`, `.exp`, `.cwproj` in binary mode or write with `newline='\r\n'`; a text-mode Python read plus a bare write converts the whole file to LF and lands a whole-file diff. After any scripted edit, lone-LF must be 0:

```
python -c "b=open(F,'rb').read(); c=b.count(b'\r\n'); print('CRLF',c,'lone-LF',b.count(b'\n')-c)"
```

A `git diff --stat` showing a whole-file rewrite for a one-line edit is line-ending damage, not the edit.
