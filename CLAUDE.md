# tpscli

Clarion 12 console exe that runs a SQL subset (DESCRIBE/SELECT/INSERT/UPDATE/DELETE) against any TopSpeed file, reading the layout from the file itself. Standalone; not part of dtpos.

- Spec: `docs/mySuperpower/specs/2026-09-15-tpscli-design.html`
- Plan: `docs/mySuperpower/plans/2026-09-15-tpscli.html` (task by task, TDD; Task 1 creates the cwproj/exp/clw files)
- Running decisions log: `docs/implementation-notes.html` (created in Task 1, append every task)

## Layout (from the plan)

- `tpscli.cwproj`, `tpscli.exp` (NAME 'tpscli' CUI), `tpscli.clw`, `tpsOut|tpsSchema|tpsSql|tpsExec.inc/.clw` at root
- `tools/build.ps1`, `verify.ps1`
- `tests/` parser.sql + expected + per-task .ps1 checks
- `testdata/gen/` corpus generator (mkcorpus), `testdata/expected/*.json` oracle dumps; generated `.TPS` files are gitignored

## Build

Clarion 12.0.14000 at `C:\Clarion12`, static Lib model, StringTheory and DynFile via CLARION120.RED (no project entries).

```
C:\Windows\Microsoft.NET\Framework\v4.0.30319\MSBuild.exe tpscli.cwproj /t:Rebuild /p:Configuration=Release /p:ClarionBinPath="C:\Clarion12\bin" /p:clarion_version="Clarion 12.0.14000" /v:minimal
```

Console subsystem comes from `tpscli.exp` beside the cwproj; confirm `obj\release\tpscli.cwproj.FileList.xml` lists TPSCLI.EXP, not CLAWSTD.EXP.
