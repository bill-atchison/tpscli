param()
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$exe = Join-Path $root 'tpscli.exe'
. (Join-Path $PSScriptRoot 'TestHelpers.ps1')

# INSERT works on copies so the read-only fixtures under testdata\ stay pristine across runs.
# testdata\work is gitignored (see .gitignore); each run starts from a fresh copy of the source
# fixture so the case sequence below - and its final DESCRIBE record count - is reproducible.
$workDir = Join-Path $root 'testdata\work'
New-Item -ItemType Directory -Force -Path $workDir | Out-Null
Copy-Item (Join-Path $root 'testdata\ALLTYPES.TPS') (Join-Path $workDir 'ALLTYPES.TPS') -Force
Copy-Item (Join-Path $root 'testdata\ALLTYPES.TPS') (Join-Path $workDir 'ALLTYPES_DEC.TPS') -Force
Copy-Item (Join-Path $root 'testdata\MEMOS.TPS') (Join-Path $workDir 'MEMOS.TPS') -Force

$timeoutMs = 20000
$failures = 0

function Invoke-Case([string]$Name, [string[]]$ExtraArgs, [string]$Sql, [string]$Expected, [int]$Exit) {
    $argList = @() + $ExtraArgs + @($Sql)
    $result = Invoke-Tpscli_Bounded -FilePath $script:exe -ArgumentList $argList -WorkingDirectory $script:root -TimeoutMs $script:timeoutMs

    if ($result.TimedOut) {
        Write-Host "insert.ps1: FAILED (timeout) in '$Name' - exceeded $($script:timeoutMs)ms, process was killed"
        $script:failures++
        return
    }

    $actual = ($result.StdOut + $result.StdErr) -replace "`r`n", "`n"
    $actual = $actual.TrimEnd("`n")
    $exp = $Expected -replace "`r`n", "`n"
    $exp = $exp.TrimEnd("`n")

    $ok = $true
    if ($actual -ne $exp) {
        $ok = $false
        Write-Host "insert.ps1: MISMATCH in '$Name'"
        Write-Host "  sql:      $Sql"
        Write-Host "  expected: $exp"
        Write-Host "  actual:   $actual"
    }
    if ($result.ExitCode -ne $Exit) {
        $ok = $false
        Write-Host "insert.ps1: EXIT MISMATCH in '$Name': expected $Exit, actual $($result.ExitCode)"
    }
    if (-not $ok) { $script:failures++ }
}

# ---- primary sequence: testdata\work\ALLTYPES.TPS, exactly task-8-brief.md's case order ----
# (3 pre-existing records + 2 successful inserts (ID 9, 10) = 5; the later cases (11-14) all fail
# validation and never mutate the file, so the DESCRIBE check at the bottom stays at 5.)

Invoke-Case 'INSERT: typed literals into every scalar type, 9.995 rounds into DECIMAL(7,2)' @() `
    "INSERT INTO [testdata\work\ALLTYPES.TPS] (ID, STR, D, DT, TM, ARR[3]) VALUES (9, 'nine', 9.995, '2026-01-31', '23:59:59', 7)" `
    '{ "ok": true, "op": "insert", "affected": 1, "complete": true }' `
    0

# D=9.995 rounds half-away-from-zero to 10.00; DECIMAL-to-STRING display trims trailing fraction
# zeros for every row in this file, including untouched pre-existing data (row ID=3 in the
# original testdata\ALLTYPES.TPS reads back as "0", not "0.00" - confirmed empirically), so the
# rounded value reads back as "10" here, not "10.00". See task-8-report.md.
Invoke-Case 'SELECT the just-inserted row back' @() `
    "SELECT ID, STR, D, DT, TM, ARR[3] FROM [testdata\work\ALLTYPES.TPS] WHERE ID = 9" `
    '{ "ok": true, "op": "select", "columns": [{"name":"ID","type":"LONG"},{"name":"STR","type":"STRING"},{"name":"D","type":"DECIMAL"},{"name":"DT","type":"DATE"},{"name":"TM","type":"TIME"},{"name":"ARR[3]","type":"SHORT"}], "rows": [[9,"nine","10","2026-01-31","23:59:59.00",7]], "row_count": 1, "truncated": false, "complete": true }' `
    0

Invoke-Case 'INSERT: duplicate primary key -> DUPLICATE_KEY, outcome none, exit 3' @() `
    "INSERT INTO [testdata\work\ALLTYPES.TPS] (ID) VALUES (9)" `
    '{ "ok": false, "op": "insert", "error": { "code": "DUPLICATE_KEY", "message": "Duplicate value for key IDKEY", "key": "IDKEY" }, "outcome": "none", "complete": true }' `
    3

Invoke-Case 'INSERT: string overflow truncates with a STRING_TRUNCATED warning, still ok' @() `
    "INSERT INTO [testdata\work\ALLTYPES.TPS] (ID, STR) VALUES (10, 'this string is far longer than twenty characters')" `
    '{ "ok": true, "op": "insert", "affected": 1, "warnings": [{ "code": "STRING_TRUNCATED", "column": "STR", "message": "Value truncated to 20 characters" }], "complete": true }' `
    0

# DATE/TIME/integer/DECIMAL range checks are already enforced by tpsSql's ParseBody (SqlLitConvert)
# before Exec.Run() is ever called, so these four cases fail at parse time rather than inside
# DoInsert/Validate - same error code, column and exit code either way, but the JSON carries
# "position"/"token" from the parser instead of coming through tpsExec.ErrOut. See task-8-report.md.
Invoke-Case 'INSERT: invalid date -> VALUE_OUT_OF_RANGE column DT, exit 3' @() `
    "INSERT INTO [testdata\work\ALLTYPES.TPS] (ID, DT) VALUES (11, '2026-02-30')" `
    '{ "ok": false, "op": "insert", "error": { "code": "VALUE_OUT_OF_RANGE", "message": "Invalid date ''2026-02-30'' for column DT", "position": 63, "token": "2026-02-30", "column": "DT" }, "outcome": "none", "complete": true }' `
    3

Invoke-Case 'INSERT: BYTE out of range -> VALUE_OUT_OF_RANGE column B, exit 3' @() `
    "INSERT INTO [testdata\work\ALLTYPES.TPS] (ID, B) VALUES (12, 300)" `
    '{ "ok": false, "op": "insert", "error": { "code": "VALUE_OUT_OF_RANGE", "message": "B value 300 is outside the range of BYTE", "position": 62, "token": "300", "column": "B" }, "outcome": "none", "complete": true }' `
    3

Invoke-Case 'INSERT: SHORT with a fraction -> VALUE_OUT_OF_RANGE column S, exit 3' @() `
    "INSERT INTO [testdata\work\ALLTYPES.TPS] (ID, S) VALUES (13, 1.5)" `
    '{ "ok": false, "op": "insert", "error": { "code": "VALUE_OUT_OF_RANGE", "message": "S does not accept a fraction", "position": 62, "token": "1.5", "column": "S" }, "outcome": "none", "complete": true }' `
    3

Invoke-Case 'INSERT: DECIMAL(7,2) overflow (8 digits > 7) -> VALUE_OUT_OF_RANGE column D, exit 3' @() `
    "INSERT INTO [testdata\work\ALLTYPES.TPS] (ID, D) VALUES (14, 123456.78)" `
    '{ "ok": false, "op": "insert", "error": { "code": "VALUE_OUT_OF_RANGE", "message": "D value 123456.78 overflows DECIMAL(7,2)", "position": 62, "token": "123456.78", "column": "D" }, "outcome": "none", "complete": true }' `
    3

# ---- DECIMAL digit-count regression: SchFieldQ.Digits is NOT the total digit count for a DECIMAL
# field (that's Fields.Size - see the fix and comment in tpsSql.clw's SqlLitConvert). Before that
# fix, ANY literal needing more than 4 significant digits into AT:D (a real DECIMAL(7,2)) was
# incorrectly rejected as "overflows DECIMAL(4,2)", even though the field already held a 7-digit
# value (testdata\ALLTYPES.TPS row 1, D=12345.67) written by the corpus generator. This proves a
# legitimate 7-digit value round-trips through INSERT correctly now.

Invoke-Case 'INSERT: DECIMAL value needing 7 significant digits now succeeds (regression)' @() `
    "INSERT INTO [testdata\work\ALLTYPES_DEC.TPS] (ID, D) VALUES (50, 54321.99)" `
    '{ "ok": true, "op": "insert", "affected": 1, "complete": true }' `
    0

Invoke-Case 'SELECT it back: full 7-digit precision round-trips' @() `
    "SELECT ID, D FROM [testdata\work\ALLTYPES_DEC.TPS] WHERE ID = 50" `
    '{ "ok": true, "op": "select", "columns": [{"name":"ID","type":"LONG"},{"name":"D","type":"DECIMAL"}], "rows": [[50,"54321.99"]], "row_count": 1, "truncated": false, "complete": true }' `
    0

# ---- BLOB write: unverified per task-8-brief.md ("try it; if it does not compile or work, report
# it and fall back to UNSUPPORTED"). This proves the PROP:Blob write path (negative memo index,
# matching FormatMemo's proven read convention) works end to end on testdata\MEMOS.TPS's PIC field.

Invoke-Case 'INSERT: BLOB column from a base64 literal' @() `
    "INSERT INTO [testdata\work\MEMOS.TPS] (ID, TITLE, PIC) VALUES (3, 'blobtest', 'UE5HPw==')" `
    '{ "ok": true, "op": "insert", "affected": 1, "complete": true }' `
    0

Invoke-Case 'SELECT it back: base64 round-trips through the BLOB write' @() `
    "SELECT ID, TITLE, PIC FROM [testdata\work\MEMOS.TPS] WHERE ID = 3" `
    '{ "ok": true, "op": "select", "columns": [{"name":"ID","type":"LONG"},{"name":"TITLE","type":"STRING"},{"name":"PIC","type":"BLOB"}], "rows": [[3,"blobtest","UE5HPw=="]], "row_count": 1, "truncated": false, "complete": true }' `
    0

# ---- final sanity: task-8-brief.md's own verification step - the primary work copy has exactly
# 5 records (3 original + the 2 successful inserts above; every other case above failed validation
# and never reached ADD()).

$descResult = Invoke-Tpscli_Bounded -FilePath $exe -ArgumentList @("DESCRIBE [testdata\work\ALLTYPES.TPS]") -WorkingDirectory $root -TimeoutMs $timeoutMs
if ($descResult.TimedOut) {
    Write-Host "insert.ps1: FAILED (timeout) in 'DESCRIBE record count'"
    $failures++
} else {
    $descJson = $descResult.StdOut | ConvertFrom-Json
    if ($descJson.records -ne 5) {
        Write-Host "insert.ps1: MISMATCH in 'DESCRIBE record count': expected 5, actual $($descJson.records)"
        $failures++
    }
}

if ($failures -gt 0) {
    Write-Host "insert.ps1: $failures case(s) FAILED"
    exit 1
} else {
    Write-Host "insert.ps1: OK"
    exit 0
}
