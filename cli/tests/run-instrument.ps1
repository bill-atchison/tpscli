# Automates ..\docs\Testing\Tpscli-Unit-Test-Cases.html (docs live at the repository root): runs every "Run" step of every case, checks
# the concrete values each case's expected text names, and writes a results JSON whose shape
# mirrors the instrument's per-case state (steps ticks, verdict, notes, evidence) so the run can
# be loaded into the page through its own engine functions.
#
# Usage (from cli\):  powershell -NoProfile -ExecutionPolicy Bypass -File tests\run-instrument.ps1
# Exit 0 when no case is FAIL (BLOCKED for the dev-input case TC-28 is expected), 1 otherwise.
param(
    [string]$OutFile = 'docs\Testing\Tpscli-Unit-Test-Results.json',   # relative to the repository root
    [string[]]$Only = @()      # e.g. -Only TC-17,TC-18 (setup cases are not implied)
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot          # cli\
$repo = Split-Path -Parent $root                  # repository root, where docs\ lives
$exe = Join-Path $root 'tpscli.exe'
$instrument = Join-Path $repo 'docs\Testing\Tpscli-Unit-Test-Cases.html'
. (Join-Path $PSScriptRoot 'TestHelpers.ps1')
$powershell = Join-Path $PSHOME 'powershell.exe'
if (-not (Test-Path $powershell)) { $powershell = 'powershell.exe' }

# ---- the case list comes from the instrument itself, so ids and step counts never drift ----
$parser = [IO.Path]::GetTempFileName() + '.js'
@'
const fs = require('fs'), vm = require('vm');
const html = fs.readFileSync(process.argv[2], 'utf8');
const s = html.indexOf('/* ============================ CUSTOMIZE START');
const e = html.indexOf('/* ============================= CUSTOMIZE END');
if (s < 0 || e < 0) { console.error('CUSTOMIZE block not found'); process.exit(2); }
const ctx = {}; vm.runInNewContext(html.slice(s, e), ctx);
process.stdout.write(JSON.stringify({ storageKey: ctx.STORAGE_KEY, cases: ctx.CASES }));
'@ | Set-Content -Path $parser -Encoding ASCII
try { $suite = (& node $parser $instrument) | ConvertFrom-Json } finally { Remove-Item $parser -ErrorAction SilentlyContinue }
if ($LASTEXITCODE -ne 0) { throw 'could not parse CASES from the instrument' }

# ---- per-case context and assertion helpers ----
$script:ctx = $null
function Start-Case($c) {
    $script:ctx = @{
        Id = $c.id; Steps = @($false) * $c.steps.Count
        Evidence = New-Object System.Collections.Generic.List[string]
        Fails    = New-Object System.Collections.Generic.List[string]
    }
}
function Tick([int]$n) { $script:ctx.Steps[$n - 1] = $true }
function Note([string]$text) { $script:ctx.Evidence.Add($text) }
function Fail([string]$why) { $script:ctx.Fails.Add($why); Note "  ** $why" }

# Runs one bounded process, logs the command and its output as evidence, throws on timeout.
function Invoke-Logged([string]$Label, [string]$FilePath, [string[]]$Argv, [int]$TimeoutMs = 20000) {
    $r = Invoke-Tpscli_Bounded -FilePath $FilePath -ArgumentList $Argv -WorkingDirectory $root -TimeoutMs $TimeoutMs
    Note "> $Label"
    if ($r.TimedOut) { Note "  (killed after $TimeoutMs ms)"; throw "$Label timed out after $TimeoutMs ms" }
    $out = ($r.StdOut + '') -replace "`r`n", "`n"
    $err = ($r.StdErr + '') -replace "`r`n", "`n"
    foreach ($l in $out.TrimEnd("`n") -split "`n") { if ($l -ne '') { Note "  $l" } }
    foreach ($l in $err.TrimEnd("`n") -split "`n") { if ($l -ne '') { Note "  stderr: $l" } }
    Note "  exit $($r.ExitCode)"
    [pscustomobject]@{ Out = $out.TrimEnd("`n"); Err = $err.TrimEnd("`n"); Exit = $r.ExitCode }
}
function Sql([string[]]$Argv) { Invoke-Logged ('tpscli.exe ' + ($Argv -join ' ')) $exe $Argv }
function Invoke-Ps1([string]$File, [string[]]$Extra = @(), [int]$TimeoutMs = 300000) {
    Invoke-Logged ("powershell -File $File " + ($Extra -join ' ')) $powershell (@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $File) + $Extra) $TimeoutMs
}
function Fresh([string]$Name) {
    New-Item -ItemType Directory -Force (Join-Path $root 'testdata\work') | Out-Null
    Copy-Item (Join-Path $root "testdata\$Name.TPS") (Join-Path $root "testdata\work\$Name.TPS") -Force
    Note "> (CP-3) Copy-Item testdata\$Name.TPS testdata\work\$Name.TPS -Force"
}
function Expect-Contains($r, [string]$Needle) {
    if (-not $r.Out.Contains($Needle)) { Fail "expected output to contain $Needle" }
}
function Expect-NotContains($r, [string]$Needle) {
    if (($r.Out + $r.Err).Contains($Needle)) { Fail "output must not contain $Needle" }
}
function Expect-Exit($r, [int]$Code) {
    if ($r.Exit -ne $Code) { Fail "expected exit $Code, got $($r.Exit)" }
}
function Expect-Json($r, [string]$Property, $Value) {
    $j = $null
    try { $j = $r.Out | ConvertFrom-Json } catch { Fail "output is not JSON: $($_.Exception.Message)"; return }
    $actual = $j.$Property
    if ("$actual" -ne "$Value") { Fail "expected $Property = $Value, got $actual" }
}
function Expect-True([bool]$Cond, [string]$What) { if (-not $Cond) { Fail $What } }
function Expect-Error($r, [string]$Code, [int]$Exit, [string]$Outcome = 'none') {
    Expect-Contains $r '"ok": false'
    Expect-Contains $r ('"code": "' + $Code + '"')
    if ($Outcome) { Expect-Contains $r ('"outcome": "' + $Outcome + '"') }
    Expect-Contains $r '"complete": true'
    Expect-Exit $r $Exit
}
function Expect-Ok($r, [string]$Op) {
    Expect-Contains $r '"ok": true'
    Expect-Contains $r ('"op": "' + $Op + '"')
    Expect-Contains $r '"complete": true'
    Expect-Exit $r 0
}

# ---- one executor per case; each Tick n marks step n of the instrument as performed ----
$run = @{
'TC-01' = {
    $r = Invoke-Ps1 'tools\build.ps1'; Tick 1
    $errs = @($r.Out -split "`n" | Where-Object { $_ -match '\berror\b' })
    Expect-True ($errs.Count -eq 0) "build output has error lines: $($errs -join ' | ')"
    Expect-True ($r.Out.TrimEnd() -match 'subsystem=3 \(console\)$') 'build output does not end with subsystem=3 (console)'
    Expect-Exit $r 0; Tick 2
    $age = (Get-Date) - (Get-Item $exe).LastWriteTime
    Note "> (Get-Item tpscli.exe).LastWriteTime = $((Get-Item $exe).LastWriteTime) ($([int]$age.TotalSeconds) s ago)"
    Expect-True ($age.TotalMinutes -lt 1) 'tpscli.exe timestamp is not within the last minute'; Tick 3
}
'TC-02' = {
    $r = Invoke-Ps1 'tools\build.ps1' @('-Proj', 'testdata\gen\mkcorpus.cwproj'); Expect-Exit $r 0; Tick 1
    $m = Invoke-Logged 'testdata\gen\mkcorpus.exe' (Join-Path $root 'testdata\gen\mkcorpus.exe') @()
    Expect-True ($m.Err -eq '') "mkcorpus wrote to stderr: $($m.Err)"
    Expect-True (-not ($m.Out -match 'CREATE ')) "mkcorpus reported a CREATE failure: $($m.Out)"
    Expect-Exit $m 0; Tick 2
    $missing = @()
    foreach ($n in 'ALLTYPES', 'GROUPS', 'KEYS', 'MEMOS', 'NOKEY', 'SECRET') {
        if (-not (Test-Path (Join-Path $root "testdata\$n.TPS"))) { $missing += "testdata\$n.TPS" }
        if (-not (Test-Path (Join-Path $root "testdata\expected\$n.json"))) { $missing += "testdata\expected\$n.json" }
    }
    Note ('> Get-ChildItem testdata\*.TPS, testdata\expected\*.json -> ' + ((Get-ChildItem (Join-Path $root 'testdata\*.TPS'), (Join-Path $root 'testdata\expected\*.json') | ForEach-Object Name) -join ', '))
    Expect-True ($missing.Count -eq 0) "missing: $($missing -join ', ')"; Tick 3
}
'TC-03' = {
    $r = Sql '--version'
    Expect-Contains $r '"ok": true'; Expect-Contains $r '"op": null'; Expect-Contains $r '"version": "0.1.0"'; Expect-Contains $r '"complete": true'
    Expect-True (($r.Out -split "`n").Count -eq 1) 'more than one output line'; Tick 1
    Expect-Exit $r 0; Tick 2
}
'TC-04' = {
    $r = Sql @()
    Expect-Contains $r '"ok": false'; Expect-Contains $r '"code": "SYNTAX"'; Expect-Contains $r 'No SQL statement'; Expect-Contains $r '"complete": true'; Tick 1
    Expect-Exit $r 1; Tick 2
}
'TC-05' = {
    $r = Sql 'SELECT * FROM [testdata\NOPE.TPS]'
    Expect-Contains $r '"ok": false'; Expect-Contains $r '"code": "FILE_NOT_FOUND"'; Expect-Contains $r '"complete": true'
    Expect-True ($r.Err -eq '') "stderr not empty: $($r.Err)"; Tick 1
    Expect-Exit $r 2; Tick 2
}
'TC-06' = {
    $r = Sql '--parse-only', 'INSERT INTO [testdata\ALLTYPES.TPS] (ID, B) VALUES (12, 300)'
    Expect-Error $r 'VALUE_OUT_OF_RANGE' 3; Expect-Contains $r '"column": "B"'; Expect-Contains $r '"position":'; Expect-Contains $r '"token":'; Tick 1
    $d = Sql 'DESCRIBE [testdata\ALLTYPES.TPS]'; Expect-Ok $d 'describe'; Expect-Json $d 'records' 3; Tick 2
}
'TC-07' = {
    $r = Sql 'DESCRIBE [testdata\KEYS.TPS]'; Expect-Ok $r 'describe'
    foreach ($c in '{"name":"ID","type":"LONG"}', '{"name":"NAME","type":"STRING"', '{"name":"CODE","type":"STRING"', '{"name":"AMOUNT","type":"DECIMAL"') { Expect-Contains $r $c }
    Tick 1
    Expect-Json $r 'records' 5; Tick 2
    $j = $r.Out | ConvertFrom-Json
    Expect-True ($j.keys.Count -eq 5) "expected 5 keys, got $($j.keys.Count)"
    Expect-True (@($j.keys | Where-Object { $_.name -eq 'PKEY' -and $_.primary }).Count -eq 1) 'PKEY is not marked primary'; Tick 3
}
'TC-08' = {
    $r1 = Sql 'DESCRIBE [testdata\SECRET.TPS]'
    Expect-True ($r1.Out.Contains('"code": "OWNER_REQUIRED"') -or $r1.Out.Contains('"code": "OWNER_WRONG"')) 'expected OWNER_REQUIRED or OWNER_WRONG'; Tick 1
    Expect-Exit $r1 2; Tick 2
    $r3 = Sql '--owner', 's3cret', 'DESCRIBE [testdata\SECRET.TPS]'; Expect-Ok $r3 'describe'; Expect-Json $r3 'records' 2; Tick 3
    Expect-NotContains $r1 's3cret'; Expect-NotContains $r3 's3cret'; Note '> both outputs searched for s3cret'; Tick 4
}
'TC-09' = {
    $r = Invoke-Ps1 'tests\describe.ps1'; Expect-True (-not $r.Out.Contains('MISMATCH')) 'describe.ps1 printed MISMATCH'; Tick 1
    Expect-Exit $r 0; Tick 2
}
'TC-10' = {
    $r = Sql 'SELECT ID, STR, D, DT, TM, ARR[2] FROM [testdata\ALLTYPES.TPS] WHERE ID = 1'; Expect-Ok $r 'select'
    Expect-Contains $r '"columns": [{"name":"ID","type":"LONG"},{"name":"STR","type":"STRING"},{"name":"D","type":"DECIMAL"},{"name":"DT","type":"DATE"},{"name":"TM","type":"TIME"},{"name":"ARR[2]","type":"SHORT"}]'
    Expect-Contains $r '"rows": [[1,"alpha","12345.67","2026-09-15","13:45:30.00",20]]'
    Expect-Contains $r '"row_count": 1'; Expect-Contains $r '"truncated": false'; Tick 1
}
'TC-11' = {
    $r1 = Sql "SELECT ADDR.CITY FROM [testdata\GROUPS.TPS] WHERE ID = 1"; Expect-Ok $r1 'select'; Expect-Contains $r1 '"rows": [["Springfield"]]'; Tick 1
    $r2 = Sql "SELECT PHONES[2].EXT[2] FROM [testdata\GROUPS.TPS] WHERE ID = 1"; Expect-Ok $r2 'select'; Expect-Contains $r2 '"rows": [["b2"]]'; Tick 2
    $r3 = Sql "SELECT * FROM [testdata\GROUPS.TPS] ORDER BY ID LIMIT 1"; Expect-Ok $r3 'select'
    $j = $r3.Out | ConvertFrom-Json
    Expect-True ($j.columns.Count -eq 21) "expected 21 columns, got $($j.columns.Count)"
    foreach ($n in 'PHONES[1].KIND', 'PHONES[2].EXT[2]', 'GRID[1]', 'GRID[6]') { Expect-True (($j.columns.name -contains $n)) "column $n missing" }
    Expect-Json $r3 'row_count' 1; Expect-Contains $r3 '"truncated": true'; Tick 3
}
'TC-12' = {
    $r1 = Sql "SELECT ID FROM [testdata\GROUPS.TPS] WHERE PHONES[2].KIND = 'M' ORDER BY ID"; Expect-Error $r1 'UNSUPPORTED' 1; Expect-Contains $r1 '"token": "PHONES[2].KIND"'; Tick 1
    $r2 = Sql "SELECT ID FROM [testdata\GROUPS.TPS] ORDER BY PHONES[2].KIND"; Expect-Error $r2 'UNSUPPORTED' 1; Expect-Contains $r2 '"token": "PHONES[2].KIND"'; Tick 2
    Expect-Exit $r2 1; Tick 3
}
'TC-13' = {
    $r1 = Sql "SELECT ID FROM [testdata\KEYS.TPS] ORDER BY ID LIMIT 2 OFFSET 1"; Expect-Ok $r1 'select'; Expect-Contains $r1 '"rows": [[2],[3]]'; Expect-Contains $r1 '"truncated": true'; Tick 1
    $r2 = Sql "SELECT ID FROM [testdata\KEYS.TPS] LIMIT 5"; Expect-Ok $r2 'select'; Expect-Json $r2 'row_count' 5; Expect-Contains $r2 '"truncated": false'; Tick 2
    $r3 = Sql "SELECT ID FROM [testdata\KEYS.TPS] WHERE ID > 999"; Expect-Ok $r3 'select'; Expect-Contains $r3 '"rows": []'; Expect-Contains $r3 '"row_count": 0'; Tick 3
}
'TC-14' = {
    # KEYS names: Able, baker, Charlie, delta, Echo -> lowercase a in baker(AMOUNT 4), Charlie(3), delta(2)
    $r1 = Sql "SELECT ID FROM [testdata\KEYS.TPS] WHERE NAME LIKE '%a%' ORDER BY AMOUNT DESC, ID"; Expect-Ok $r1 'select'; Expect-Contains $r1 '"rows": [[2],[3],[4]]'; Tick 1
    $r2 = Sql "SELECT ID, NAME FROM [testdata\KEYS.TPS] WHERE CODE IN ('A','E') ORDER BY NAME"; Expect-Ok $r2 'select'; Expect-Contains $r2 '"rows": [[1,"Able"],[5,"Echo"]]'; Tick 2
    $r3 = Sql "SELECT ID, CODE FROM [testdata\KEYS.TPS] ORDER BY CODE"; Expect-Ok $r3 'select'; Expect-Contains $r3 '"rows": [[2,""],[4,""],[1,"A"],[3,"C"],[5,"E"]]'; Tick 3
}
'TC-15' = {
    $r = Sql "SELECT ID, NOTES, BIN, PIC FROM [testdata\MEMOS.TPS] WHERE ID = 1"; Expect-Ok $r 'select'
    Expect-Contains $r '\u0000'; Expect-Contains $r '\u00ff'; Expect-Contains $r '"UE5HPw=="'; Tick 1
    try { $j = $r.Out | ConvertFrom-Json; Note "> ConvertFrom-Json OK: NOTES=$($j.rows[0][1] -replace "`r`n", '\r\n') BIN length $($j.rows[0][2].Length) PIC=$($j.rows[0][3])" }
    catch { Fail "ConvertFrom-Json threw: $($_.Exception.Message)" }
    Expect-True ([int][char]$j.rows[0][2][1] -eq 0 -and [int][char]$j.rows[0][2][3] -eq 255) 'BIN did not decode to CHR(0) and CHR(255)'; Tick 2
}
'TC-16' = {
    $r1 = Sql "SELECT ID, NAME, CODE, AMOUNT FROM [testdata\KEYS.TPS] ORDER BY ID", '--table'; Expect-Exit $r1 0
    $lines = @($r1.Out -split "`n")
    Expect-True ($lines.Count -eq 8) "expected 8 lines (header, rule, 5 rows, summary), got $($lines.Count)"
    Expect-True ($lines[0] -match '^ID\s+NAME\s+CODE\s+AMOUNT$') 'header row wrong'
    Expect-True ($lines[1] -match '^-+(\s+-+)+$') 'dashed rule missing'
    Expect-True ($lines[2] -match '^ 1  Able\s+A\s+5$') 'numeric columns are not right-aligned / text not left-aligned'
    Expect-True ($lines[7] -eq '(5 rows)') 'summary line is not (5 rows)'; Tick 1
    $r2 = Sql "SELECT ID FROM [testdata\NOPE.TPS]", '--table'; Expect-True ($r2.Out -match '^FILE_NOT_FOUND: ') 'expected one FILE_NOT_FOUND: line'; Expect-Exit $r2 2; Tick 2
}
'TC-17' = {
    Fresh 'ALLTYPES'
    $r1 = Sql "INSERT INTO [testdata\work\ALLTYPES.TPS] (ID, STR, D, DT, TM, ARR[3]) VALUES (9, 'nine', 9.995, '2026-01-31', '23:59:59', 7)"
    Expect-True ($r1.Out -eq '{ "ok": true, "op": "insert", "affected": 1, "complete": true }') "unexpected insert response: $($r1.Out)"; Expect-Exit $r1 0; Tick 1
    $r2 = Sql "SELECT ID, STR, D, DT, TM, ARR[3] FROM [testdata\work\ALLTYPES.TPS] WHERE ID = 9"; Expect-Ok $r2 'select'; Expect-Contains $r2 '"rows": [[9,"nine","10","2026-01-31","23:59:59.00",7]]'; Tick 2
    $r3 = Sql "DESCRIBE [testdata\work\ALLTYPES.TPS]"; Expect-Json $r3 'records' 4; Tick 3
}
'TC-18' = {
    $r1 = Sql "INSERT INTO [testdata\work\ALLTYPES.TPS] (ID) VALUES (9)"; Expect-Error $r1 'DUPLICATE_KEY' 3; Expect-Contains $r1 '"key": "IDKEY"'; Tick 1
    Expect-Exit $r1 3; Tick 2
    $r3 = Sql "DESCRIBE [testdata\work\ALLTYPES.TPS]"; Expect-Json $r3 'records' 4; Tick 3
}
'TC-19' = {
    $r1 = Sql "INSERT INTO [testdata\work\ALLTYPES.TPS] (ID, STR) VALUES (10, 'this string is far longer than twenty characters')"
    Expect-Ok $r1 'insert'; Expect-Contains $r1 '"affected": 1'; Expect-Contains $r1 '"warnings": [{ "code": "STRING_TRUNCATED", "column": "STR"'; Tick 1
    $i = 2
    foreach ($case in @(@("INSERT INTO [testdata\work\ALLTYPES.TPS] (ID, DT) VALUES (11, '2026-02-30')", 'DT'),
                        @("INSERT INTO [testdata\work\ALLTYPES.TPS] (ID, B) VALUES (12, 300)", 'B'),
                        @("INSERT INTO [testdata\work\ALLTYPES.TPS] (ID, S) VALUES (13, 1.5)", 'S'),
                        @("INSERT INTO [testdata\work\ALLTYPES.TPS] (ID, D) VALUES (14, 123456.78)", 'D'))) {
        $r = Sql $case[0]; Expect-Error $r 'VALUE_OUT_OF_RANGE' 3; Expect-Contains $r ('"column": "' + $case[1] + '"'); Tick $i; $i++
    }
    $r6 = Sql "DESCRIBE [testdata\work\ALLTYPES.TPS]"; Expect-Json $r6 'records' 5; Tick 6
}
'TC-20' = {
    Fresh 'ALLTYPES'
    $r1 = Sql "INSERT INTO [testdata\work\ALLTYPES.TPS] (ID, PIC) VALUES (20, 'rrr')"; Expect-Error $r1 'VALUE_OUT_OF_RANGE' 3; Expect-Contains $r1 'PIC does not match picture @N9.2'; Tick 1
    $r2 = Sql "INSERT INTO [testdata\work\ALLTYPES.TPS] (ID, PIC) VALUES (21, '7')"; Expect-Ok $r2 'insert'; Expect-Contains $r2 '"affected": 1'; Tick 2
    $r3 = Sql "SELECT ID, PIC FROM [testdata\work\ALLTYPES.TPS] WHERE ID > 19"; Expect-Ok $r3 'select'; Expect-Contains $r3 '"rows": [[21,"00007.00"]]'; Expect-Json $r3 'row_count' 1; Tick 3
}
'TC-21' = {
    Fresh 'MEMOS'
    $r1 = Sql "INSERT INTO [testdata\work\MEMOS.TPS] (ID, TITLE, PIC) VALUES (3, 'blobtest', 'UE5HPw==')"; Expect-Ok $r1 'insert'; Tick 1
    $r2 = Sql "SELECT ID, TITLE, PIC FROM [testdata\work\MEMOS.TPS] WHERE ID = 3"; Expect-Ok $r2 'select'; Expect-Contains $r2 '"rows": [[3,"blobtest","UE5HPw=="]]'; Tick 2
    $b = [Convert]::ToBase64String([byte[]](1..3150 | ForEach-Object { $_ % 256 })); Note "> `$b = base64 of 3150 bytes ($($b.Length) chars)"; Tick 3
    $r4 = Sql "INSERT INTO [testdata\work\MEMOS.TPS] (ID, TITLE, PIC) VALUES (4, 'bigblob', '$b')"; Expect-Ok $r4 'insert'; Expect-Contains $r4 '"affected": 1'; Tick 4
    $r5 = Sql "SELECT PIC FROM [testdata\work\MEMOS.TPS] WHERE ID = 4"; Expect-Ok $r5 'select'
    $same = $false
    try { $same = (($r5.Out | ConvertFrom-Json).rows[0][0] -eq $b) } catch { Fail "ConvertFrom-Json threw: $($_.Exception.Message)" }
    Note "> (`$out | ConvertFrom-Json).rows[0][0] -eq `$b -> $same"
    Expect-True $same 'the 4200-character base64 value did not round-trip'; Tick 5
}
'TC-22' = {
    Fresh 'KEYS'
    $r1 = Sql "UPDATE [testdata\work\KEYS.TPS] SET CODE = 'Z' WHERE CODE = ''"; Expect-Error $r1 'DUPLICATE_KEY' 3 'rolled_back'
    Expect-Contains $r1 '"row": "4"'; Expect-Contains $r1 '"matched": 2'; Expect-Contains $r1 '"affected": 0'; Tick 1
    Expect-Exit $r1 3; Tick 2
    $r3 = Sql "SELECT ID, CODE FROM [testdata\work\KEYS.TPS] WHERE ID IN (2,4) ORDER BY ID"; Expect-Ok $r3 'select'; Expect-Contains $r3 '"rows": [[2,""],[4,""]]'; Tick 3
}
'TC-23' = {
    $r1 = Sql "UPDATE [testdata\work\KEYS.TPS] SET NAME = 'zulu' WHERE CODE = ''"; Expect-Ok $r1 'update'; Expect-Contains $r1 '"matched": 2, "affected": 2'; Tick 1
    $r2 = Sql "SELECT ID FROM [testdata\work\KEYS.TPS] WHERE NAME = 'zulu' ORDER BY ID"; Expect-Ok $r2 'select'; Expect-Contains $r2 '"rows": [[2],[4]]'; Tick 2
    $r3 = Sql "UPDATE [testdata\work\KEYS.TPS] SET AMOUNT = 100 WHERE ID = 1"; Expect-Ok $r3 'update'; Expect-Contains $r3 '"matched": 1, "affected": 1'; Tick 3
    $r4 = Sql "UPDATE [testdata\work\KEYS.TPS] SET ID = 2 WHERE ID = 3"; Expect-Error $r4 'DUPLICATE_KEY' 3 'rolled_back'; Expect-Contains $r4 '"matched": 1, "affected": 0'; Tick 4
    $r5 = Sql "DELETE FROM [testdata\work\KEYS.TPS] WHERE AMOUNT < 3"; Expect-Ok $r5 'delete'; Expect-Contains $r5 '"matched": 2, "affected": 2'; Tick 5
    $r6 = Sql "DESCRIBE [testdata\work\KEYS.TPS]"; Expect-Json $r6 'records' 3; Tick 6
    $r7 = Sql "DELETE FROM [testdata\work\KEYS.TPS] WHERE 1 = 1"; Expect-Ok $r7 'delete'; Expect-Contains $r7 '"matched": 3, "affected": 3'; Tick 7
    $r8 = Sql "DESCRIBE [testdata\work\KEYS.TPS]"; Expect-Json $r8 'records' 0; Tick 8
}
'TC-24' = {
    Fresh 'KEYS'
    $r1 = Sql "DELETE FROM [testdata\work\KEYS.TPS]"; Expect-Error $r1 'WHERE_REQUIRED' 1; Tick 1
    $r2 = Sql "UPDATE [testdata\work\KEYS.TPS] SET NAME = 'x' WHERE ID > 0 LIMIT 1"; Expect-Error $r2 'UNSUPPORTED' 1; Expect-Contains $r2 '"token": "LIMIT"'; Tick 2
    $r3 = Sql "UPDATE [testdata\work\KEYS.TPS] SET NAME = NAME WHERE ID = 1"; Expect-Error $r3 'SYNTAX' 1; Expect-Contains $r3 'Expected a literal value'; Tick 3
    $r4 = Sql "DESCRIBE [testdata\work\KEYS.TPS]"; Expect-Json $r4 'records' 5; Tick 4
}
'TC-25' = {
    # Same orchestration as tests\update.ps1: start the holder, wait for held.flag (10 s bound),
    # DELETE while held, then wait for the holder to exit before the DESCRIBE.
    $holdExe = Join-Path $PSScriptRoot 'hold.exe'
    $flag = Join-Path $root 'testdata\work\held.flag'
    if (-not (Test-Path $holdExe)) { $b = Invoke-Ps1 'tools\build.ps1' @('-Proj', 'tests\hold.cwproj'); Expect-Exit $b 0 }
    Fresh 'KEYS'
    Remove-Item $flag -ErrorAction SilentlyContinue
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        $holder = Start-Process -FilePath $holdExe -WorkingDirectory $root -PassThru -NoNewWindow
        $null = $holder.Handle
        Note "> (CP-4) Start-Process tests\hold.exe (attempt $attempt, pid $($holder.Id))"; Tick 1
        $deadline = (Get-Date).AddSeconds(10); $held = $false
        while ((Get-Date) -lt $deadline) {
            if (Test-Path $flag) { $held = $true; break }
            if ($holder.HasExited) { break }
            Start-Sleep -Milliseconds 100
        }
        Note "> waited for testdata\work\held.flag -> $held"
        if (-not $held) { if (-not $holder.HasExited) { try { $holder.Kill() } catch {} }; continue }
        Tick 2
        $r3 = Sql "DELETE FROM [testdata\work\KEYS.TPS] WHERE ID > 0"; Tick 3
        if (-not $holder.WaitForExit(30000)) { try { $holder.Kill() } catch {}; Fail 'tests\hold.exe did not exit within 30 s' }
        elseif ($holder.ExitCode -ne 0) { Fail "tests\hold.exe exited $($holder.ExitCode) (2=SHARE, 3=GET/HOLD, 4=flag write failed)" }
        if ($r3.Out.Contains('"affected": 5') -and $attempt -eq 1) { Note '  holder was not in place in time; retrying once from step 1'; Fresh 'KEYS'; continue }
        break
    }
    if (-not $held) { Fail 'tests\hold.exe never reported holding the record (held.flag did not appear within 10 s)'; return }
    Expect-Error $r3 'RECORD_HELD' 3 'rolled_back'; Expect-Contains $r3 '"row": "2"'
    Expect-Contains $r3 'Record held by another process (2). Statement rolled back.'; Expect-Contains $r3 '"matched": 5, "affected": 0'
    Expect-Exit $r3 3; Tick 4
    Expect-True (-not (Test-Path $flag)) 'held.flag still exists after the holder exited'
    $r5 = Sql "DESCRIBE [testdata\work\KEYS.TPS]"; Expect-Json $r5 'records' 5; Tick 5
}
'TC-26' = {
    $i = 1
    foreach ($s in @(@('tests\describe.ps1', $null), @('tests\parser.ps1', 'parser.ps1: OK ('), @('tests\select.ps1', 'select.ps1: OK (17 cases)'),
                     @('tests\insert.ps1', 'insert.ps1: OK'), @('tests\update.ps1', 'update.ps1: OK'))) {
        $r = Invoke-Ps1 $s[0]
        Expect-True (-not $r.Out.Contains('MISMATCH')) "$($s[0]) printed MISMATCH"
        if ($s[1]) { Expect-Contains $r $s[1] }
        Expect-Exit $r 0; Tick $i; $i++
    }
}
'TC-27' = {
    $r = Invoke-Ps1 'verify.ps1' -TimeoutMs 600000; Tick 1
    # The case allows one re-run when only the step 7 performance median failed under machine load.
    $failLines = @($r.Out -split "`n" | Where-Object { $_ -match '^FAIL  ' })
    if ($failLines.Count -eq 1 -and $failLines[0] -match '^FAIL  step 7 performance - (median [\d,]+ ms)') {
        $load = [int](Get-Counter '\Processor(_Total)\% Processor Time' -SampleInterval 1 -MaxSamples 2).CounterSamples[1].CookedValue
        Note "> step 7 $($Matches[1]) on the first run with total CPU at $load%; re-running verify.ps1 once as the case allows"
        $r = Invoke-Ps1 'verify.ps1' -TimeoutMs 600000
    }
    Expect-Exit $r 0; Tick 2
    $lines = @($r.Out -split "`n")
    $pass = @($lines | Where-Object { $_ -match '^PASS  ' }).Count
    $skip = @($lines | Where-Object { $_ -match '^SKIP  ' })
    $fail = @($lines | Where-Object { $_ -match '^FAIL  ' })
    Note "> counted PASS=$pass SKIP=$($skip.Count) FAIL=$($fail.Count)"
    Expect-True ($fail.Count -eq 0) "FAIL lines: $($fail -join ' | ')"
    Expect-True ($skip.Count -eq 2) "expected exactly 2 SKIP lines, got $($skip.Count)"
    Expect-True (($skip -join ' ') -match 'dictionary' -and ($skip -join ' ') -match 'TPSFix') 'the two SKIP lines are not dictionary parity and TPSFix log'
    Expect-Contains $r 'verify.ps1: all steps PASS (2 skipped - not a release qualification)'; Tick 3
}
'TC-28' = {
    Note '> BLOCKED: -Extra, -Expected and -TpsFixLog inputs (copied dtpos files, oracle JSON, TPSFix log) are dev-supplied and not present in this repository; verify.ps1 -Extra was not run.'
    $script:ctx.Blocked = $true
}
'TC-29' = {
    $r = Sql "SELECT ID FROM [testdata\KEYS.TPS] ORDER BY AMOUNT ASC, ID DESC"; Expect-Ok $r 'select'; Expect-Contains $r '"rows": [[5],[4],[3],[2],[1]]'; Expect-Contains $r '"truncated": false'; Tick 1
}
'TC-30' = {
    Fresh 'ALLTYPES'
    $r1 = Sql "INSERT INTO [testdata\work\ALLTYPES.TPS] (ID, D) VALUES (50, 54321.99)"; Expect-Ok $r1 'insert'; Expect-Contains $r1 '"affected": 1'; Tick 1
    $r2 = Sql "SELECT ID, D FROM [testdata\work\ALLTYPES.TPS] WHERE ID = 50"; Expect-Ok $r2 'select'; Expect-Contains $r2 '"rows": [[50,"54321.99"]]'; Tick 2
}
'TC-31' = {
    Fresh 'KEYS'
    $r = Sql "UPDATE [testdata\work\KEYS.TPS] SET NAME = 'nobody' WHERE ID = 999"
    Expect-True ($r.Out -eq '{ "ok": true, "op": "update", "matched": 0, "affected": 0, "complete": true }') "unexpected response: $($r.Out)"; Tick 1
    Expect-Exit $r 0; Tick 2
}
'TC-32' = {
    $i = 1
    foreach ($case in @(@("SELECT COUNT(*) FROM [testdata\KEYS.TPS]", 'COUNT', 'Aggregate functions are not supported (COUNT)'),
                        @("SELECT ID FROM [testdata\KEYS.TPS] WHERE CODE IS NULL", 'IS', 'IS NULL is not supported; TPS has no NULL'),
                        @("SELECT ID FROM [testdata\KEYS.TPS] GROUP BY CODE", 'GROUP', 'GROUP BY is not supported'),
                        @("SELECT ID FROM [testdata\KEYS.TPS] WHERE AMOUNT + 1 = 5", '+', 'Arithmetic expressions are not supported'))) {
        $r = Sql '--parse-only', $case[0]; Expect-Error $r 'UNSUPPORTED' 1
        Expect-Contains $r ('"token": "' + $case[1] + '"'); Expect-Contains $r '"position":'; Expect-Contains $r $case[2]; Tick $i; $i++
    }
    Expect-Exit $r 1; Tick 5
}
}

# ---- run ----
$missing = @($suite.cases | Where-Object { -not $run.ContainsKey($_.id) } | ForEach-Object id)
if ($missing.Count) { throw "no executor for instrument case(s): $($missing -join ', ')" }
$started = Get-Date
$results = @()
foreach ($c in $suite.cases) {
    if ($Only.Count -and $Only -notcontains $c.id) { continue }
    Start-Case $c
    $threw = $null
    try { & $run[$c.id] } catch { $threw = $_.Exception.Message; Fail "aborted: $threw" }
    $verdict = if ($script:ctx.Blocked) { 'BLOCKED' } elseif ($script:ctx.Fails.Count) { 'FAIL' } else { 'PASS' }
    $notes = if ($verdict -eq 'PASS') { "Automated run $($started.ToString('yyyy-MM-dd HH:mm')): every check passed." }
             elseif ($verdict -eq 'BLOCKED') { 'Dev-supplied -Extra/-Expected/-TpsFixLog inputs are not available in this repository.' }
             else { ($script:ctx.Fails -join "`n") }
    $results += [ordered]@{
        id = $c.id; title = $c.title; section = $c.section; priority = $c.priority
        verdict = $verdict; steps = @($script:ctx.Steps); notes = $notes
        evidence = ($script:ctx.Evidence -join "`n")
    }
    Write-Host ("{0,-8}{1}  {2}" -f $verdict, $c.id, $c.title)
    if ($verdict -eq 'FAIL') { $script:ctx.Fails | ForEach-Object { Write-Host "        $_" } }
}
$tally = @{ PASS = 0; FAIL = 0; BLOCKED = 0; NA = 0 }
$results | ForEach-Object { $tally[$_.verdict]++ }
$doc = [ordered]@{
    suite = 'tpscli-0-1-0'; storage_key = $suite.storageKey
    build = (git -C $root rev-parse --short HEAD); ref = (git -C $root rev-parse --abbrev-ref HEAD)
    env = "$env:COMPUTERNAME / $([Environment]::OSVersion.VersionString) / PowerShell $($PSVersionTable.PSVersion)"
    started = $started.ToString('s'); finished = (Get-Date).ToString('s'); tally = $tally; cases = $results
}
$json = ($doc | ConvertTo-Json -Depth 6) -replace "(?<!`r)`n", "`r`n"
[IO.File]::WriteAllText((Join-Path $repo $OutFile), $json + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
Write-Host ''
Write-Host "run-instrument.ps1: PASS $($tally.PASS) FAIL $($tally.FAIL) BLOCKED $($tally.BLOCKED) -> $OutFile"
if ($tally.FAIL -gt 0) { exit 1 } else { exit 0 }
