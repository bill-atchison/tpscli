param()
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$exe = Join-Path $root 'tpscli.exe'
. (Join-Path $PSScriptRoot 'TestHelpers.ps1')

# DESCRIBE and SELECT open the file ReadOnly + DenyNone (OPEN 40h), so a read leaves the modified
# time and the bytes alone and works on a file the account cannot write; INSERT, UPDATE and DELETE
# keep SHARE (42h). Ticket docs\tickets\2026-09-20-reads-open-read-write.md. Works on copies under
# testdata\work (gitignored), never on the fixtures.
$workDir = Join-Path $root 'testdata\work'
$roDir = Join-Path $workDir 'ro'
New-Item -ItemType Directory -Force -Path $roDir | Out-Null
$copy = Join-Path $workDir 'KEYS_RO.TPS'
$locked = Join-Path $roDir 'KEYS.TPS'
Copy-Item (Join-Path $root 'testdata\KEYS.TPS') $copy -Force
Copy-Item (Join-Path $root 'testdata\KEYS.TPS') $locked -Force

$timeoutMs = 20000
$failures = 0

function Run([string]$Sql) {
    $r = Invoke-Tpscli_Bounded -FilePath $script:exe -ArgumentList @($Sql) -WorkingDirectory $script:root -TimeoutMs $script:timeoutMs
    if ($r.TimedOut) { throw "readonly.ps1: timeout running '$Sql'" }
    return $r
}
function Check([bool]$Cond, [string]$What) {
    if ($Cond) { Write-Host "readonly.ps1: ok   $What" } else { Write-Host "readonly.ps1: FAIL $What"; $script:failures++ }
}
function Stamp([string]$Path) { (Get-Item $Path).LastWriteTimeUtc.Ticks }
function Hash([string]$Path) { (Get-FileHash $Path -Algorithm SHA256).Hash }

# ---- 1. a read leaves the modified time and the bytes alone; a write moves the time ----
$t0 = Stamp $copy; $h0 = Hash $copy
$d = Run "DESCRIBE [testdata\work\KEYS_RO.TPS]"
Check ($d.ExitCode -eq 0) "DESCRIBE exit 0 (got $($d.ExitCode): $($d.StdOut)$($d.StdErr))"
$s = Run "SELECT * FROM [testdata\work\KEYS_RO.TPS] LIMIT 0"
Check ($s.ExitCode -eq 0) "SELECT exit 0 (got $($s.ExitCode): $($s.StdOut)$($s.StdErr))"
Check ((Stamp $copy) -eq $t0) 'LastWriteTime unchanged after DESCRIBE and SELECT'
Check ((Hash $copy) -eq $h0) 'SHA-256 unchanged after DESCRIBE and SELECT'
Start-Sleep -Milliseconds 1200    # a second of margin so the write below lands on a later stamp
$u = Run "UPDATE [testdata\work\KEYS_RO.TPS] SET NAME = 'zulu' WHERE ID = 1"
Check ($u.ExitCode -eq 0) "UPDATE exit 0 (got $($u.ExitCode): $($u.StdOut)$($u.StdErr))"
Check ((Stamp $copy) -ne $t0) 'LastWriteTime moved after UPDATE (so the unchanged check above can detect a regression)'

# ---- 2. a read works on a file the account cannot write; the UPDATE control proves the ACE took ----
# (W) is generic write and bundles SYNCHRONIZE, which every synchronous CreateFile requests, so it
# would block reads too; deny only the specific write rights instead.
$who = "$env:USERDOMAIN\$env:USERNAME"
$hadDeny = $false
try {
    icacls $locked /deny "${who}:(WD,AD,WA,WEA)" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "readonly.ps1: icacls could not add the deny entry ($LASTEXITCODE)" }
    $hadDeny = $true
    $w = Run "UPDATE [testdata\work\ro\KEYS.TPS] SET NAME = 'zulu' WHERE ID = 1"
    $wj = try { $w.StdOut | ConvertFrom-Json } catch { $null }
    Check ($w.ExitCode -eq 2 -and $wj -and $wj.ok -eq $false -and $wj.error.code -eq 'DRIVER') "control: UPDATE on the write-denied file is refused by the driver, exit 2 (got exit $($w.ExitCode): $($w.StdOut)$($w.StdErr))"
    $r = Run "SELECT ID, NAME FROM [testdata\work\ro\KEYS.TPS] WHERE ID = 1"
    Check ($r.ExitCode -eq 0) "SELECT on the write-denied file exits 0 (got $($r.ExitCode): $($r.StdOut)$($r.StdErr))"
    Check ($r.StdOut -like '*"row_count": 1*') 'SELECT on the write-denied file returns the row'
} finally {
    if ($hadDeny) {
        icacls $locked /remove:d $who | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-Host "readonly.ps1: FAIL could not remove the deny entry from $locked"; $failures++ }
    }
}

if ($failures -gt 0) {
    Write-Host "readonly.ps1: $failures check(s) FAILED"
    exit 1
} else {
    Write-Host "readonly.ps1: OK"
    exit 0
}
