param()
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$exe = Join-Path $root 'tpscli.exe'
$holdExe = Join-Path $PSScriptRoot 'hold.exe'
. (Join-Path $PSScriptRoot 'TestHelpers.ps1')

# UPDATE/DELETE mutate the file, so every case runs against a fresh copy under testdata\work
# (gitignored) and never against the read-only fixture testdata\KEYS.TPS. tests\hold.exe has the
# same relative path baked into its FILE declaration, so both are run with $root as the working
# directory.
$workDir = Join-Path $root 'testdata\work'
$workKeys = Join-Path $workDir 'KEYS.TPS'
$flag = Join-Path $workDir 'held.flag'
New-Item -ItemType Directory -Force -Path $workDir | Out-Null
Copy-Item (Join-Path $root 'testdata\KEYS.TPS') $workKeys -Force
Remove-Item $flag -ErrorAction SilentlyContinue

$timeoutMs = 20000
$failures = 0

function Invoke-Case([string]$Name, [string]$Sql, [string]$Expected, [int]$Exit) {
    $result = Invoke-Tpscli_Bounded -FilePath $script:exe -ArgumentList @($Sql) -WorkingDirectory $script:root -TimeoutMs $script:timeoutMs

    if ($result.TimedOut) {
        Write-Host "update.ps1: FAILED (timeout) in '$Name' - exceeded $($script:timeoutMs)ms, process was killed"
        $script:failures++
        return
    }

    $actual = (($result.StdOut + $result.StdErr) -replace "`r`n", "`n").TrimEnd("`n")
    $exp = ($Expected -replace "`r`n", "`n").TrimEnd("`n")

    $ok = $true
    if ($actual -ne $exp) {
        $ok = $false
        Write-Host "update.ps1: MISMATCH in '$Name'"
        Write-Host "  sql:      $Sql"
        Write-Host "  expected: $exp"
        Write-Host "  actual:   $actual"
    }
    if ($result.ExitCode -ne $Exit) {
        $ok = $false
        Write-Host "update.ps1: EXIT MISMATCH in '$Name': expected $Exit, actual $($result.ExitCode)"
    }
    if (-not $ok) { $script:failures++ }
}

function Assert-Records([string]$Name, [int]$Expected) {
    $r = Invoke-Tpscli_Bounded -FilePath $script:exe -ArgumentList @("DESCRIBE [testdata\work\KEYS.TPS]") -WorkingDirectory $script:root -TimeoutMs $script:timeoutMs
    if ($r.TimedOut) {
        Write-Host "update.ps1: FAILED (timeout) in '$Name'"
        $script:failures++
        return
    }
    $actual = ($r.StdOut | ConvertFrom-Json).records
    if ($actual -ne $Expected) {
        Write-Host "update.ps1: MISMATCH in '$Name': expected records $Expected, actual $actual"
        $script:failures++
    }
}

# ---- task-9-brief.md's case sequence, in order, on one work copy ----

# OptKey is KEY(KY:Code),OPT - unique, so the second candidate (Id 4) collides with the first
# (Id 2) once both carry 'Z'. The whole statement rolls back: affected 0, not 1.
Invoke-Case 'UPDATE: unique OPT key collision -> DUPLICATE_KEY, rolled_back, matched 2, affected 0' `
    "UPDATE [testdata\work\KEYS.TPS] SET CODE = 'Z' WHERE CODE = ''" `
    '{ "ok": false, "op": "update", "error": { "code": "DUPLICATE_KEY", "message": "Creates Duplicate Key at 4", "row": "4" }, "outcome": "rolled_back", "matched": 2, "affected": 0, "complete": true }' `
    3

Invoke-Case 'SELECT: rollback restored both CODE values' `
    "SELECT ID, CODE FROM [testdata\work\KEYS.TPS] WHERE ID IN (2,4) ORDER BY ID" `
    '{ "ok": true, "op": "select", "columns": [{"name":"ID","type":"LONG"},{"name":"CODE","type":"STRING"}], "rows": [[2,""],[4,""]], "row_count": 2, "truncated": false, "complete": true }' `
    0

Invoke-Case 'UPDATE: two rows, non-key column' `
    "UPDATE [testdata\work\KEYS.TPS] SET NAME = 'zulu' WHERE CODE = ''" `
    '{ "ok": true, "op": "update", "matched": 2, "affected": 2, "complete": true }' `
    0

Invoke-Case 'SELECT: both rows carry the new NAME' `
    "SELECT ID FROM [testdata\work\KEYS.TPS] WHERE NAME = 'zulu' ORDER BY ID" `
    '{ "ok": true, "op": "select", "columns": [{"name":"ID","type":"LONG"}], "rows": [[2],[4]], "row_count": 2, "truncated": false, "complete": true }' `
    0

# AMOUNT is the first component of DescKey, so this rewrites a key the statement is not reading.
Invoke-Case 'UPDATE: changes a key component' `
    "UPDATE [testdata\work\KEYS.TPS] SET AMOUNT = 100 WHERE ID = 1" `
    '{ "ok": true, "op": "update", "matched": 1, "affected": 1, "complete": true }' `
    0

# SET takes a literal only; a column reference on the right is rejected by the parser, before
# the schema is even opened, so this never reaches Mutate.
Invoke-Case 'UPDATE: SET to a column reference -> SYNTAX, exit 1' `
    "UPDATE [testdata\work\KEYS.TPS] SET NAME = NAME WHERE ID = 1" `
    '{ "ok": false, "op": "update", "error": { "code": "SYNTAX", "message": "Expected a literal value", "position": 44, "token": "NAME" }, "outcome": "none", "complete": true }' `
    1

Invoke-Case 'UPDATE: primary key collision on a single row -> DUPLICATE_KEY, rolled_back' `
    "UPDATE [testdata\work\KEYS.TPS] SET ID = 2 WHERE ID = 3" `
    '{ "ok": false, "op": "update", "error": { "code": "DUPLICATE_KEY", "message": "Creates Duplicate Key at 3", "row": "3" }, "outcome": "rolled_back", "matched": 1, "affected": 0, "complete": true }' `
    3

Invoke-Case 'DELETE: two rows' `
    "DELETE FROM [testdata\work\KEYS.TPS] WHERE AMOUNT < 3" `
    '{ "ok": true, "op": "delete", "matched": 2, "affected": 2, "complete": true }' `
    0

Assert-Records 'DESCRIBE after the two-row DELETE' 3

Invoke-Case 'DELETE: every remaining row' `
    "DELETE FROM [testdata\work\KEYS.TPS] WHERE 1 = 1" `
    '{ "ok": true, "op": "delete", "matched": 3, "affected": 3, "complete": true }' `
    0

Assert-Records 'DESCRIBE after the delete-everything DELETE' 0

# ---- the hold case: a fresh five-row copy, with Id 2 held by another process ----
# tests\hold.exe SHAREs the same work copy, HOLDs Id 2 for eight seconds and drops held.flag once
# the record is actually held; the DELETE below only starts after the flag appears. Candidate Id 1
# is deleted first inside the transaction, so a rollback that does not take would leave 4 records.

Copy-Item (Join-Path $root 'testdata\KEYS.TPS') $workKeys -Force
Remove-Item $flag -ErrorAction SilentlyContinue

$holder = Start-Process -FilePath $holdExe -WorkingDirectory $root -PassThru -NoNewWindow
$null = $holder.Handle
$deadline = (Get-Date).AddSeconds(10)
$held = $false
while ((Get-Date) -lt $deadline) {
    if (Test-Path $flag) { $held = $true; break }
    if ($holder.HasExited) { break }
    Start-Sleep -Milliseconds 100
}

if (-not $held) {
    Write-Host "update.ps1: FAILED - tests\hold.exe never reported holding the record (held.flag did not appear within 10s); exited=$($holder.HasExited)"
    $failures++
    if (-not $holder.HasExited) { try { $holder.Kill() } catch {} }
} else {
    Invoke-Case 'DELETE: another process holds row 2 -> RECORD_HELD, rolled_back, matched 5, affected 0' `
        "DELETE FROM [testdata\work\KEYS.TPS] WHERE ID > 0" `
        '{ "ok": false, "op": "delete", "error": { "code": "RECORD_HELD", "message": "Record held by another process (2). Statement rolled back.", "row": "2" }, "outcome": "rolled_back", "matched": 5, "affected": 0, "complete": true }' `
        3

    # Wait for the holder to let go before the DESCRIBE, so the record count is read against a
    # file nobody is holding - and so no test run ever leaves the work copy held.
    if (-not $holder.WaitForExit(30000)) {
        Write-Host "update.ps1: FAILED - tests\hold.exe did not exit within 30s; killing it"
        try { $holder.Kill() } catch {}
        $failures++
    } elseif ($holder.ExitCode -ne 0) {
        Write-Host "update.ps1: FAILED - tests\hold.exe exited with $($holder.ExitCode) (2=SHARE failed, 3=GET/HOLD failed, 4=flag write failed)"
        $failures++
    }

    Assert-Records 'DESCRIBE after the rolled-back DELETE: nothing was removed' 5
}

# No candidate row at all: the statement reports matched 0 and never opens a transaction.
Invoke-Case 'UPDATE: no row matches -> matched 0, affected 0, exit 0' `
    "UPDATE [testdata\work\KEYS.TPS] SET NAME = 'nobody' WHERE ID = 999" `
    '{ "ok": true, "op": "update", "matched": 0, "affected": 0, "complete": true }' `
    0

if ($failures -gt 0) {
    Write-Host "update.ps1: $failures case(s) FAILED"
    exit 1
} else {
    Write-Host "update.ps1: OK"
    exit 0
}
