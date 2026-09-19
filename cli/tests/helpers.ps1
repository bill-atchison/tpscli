# Regression check for tests\TestHelpers.ps1: a fast-exiting child must never come back with a
# blank ExitCode or empty output. Before Invoke-Tpscli_Bounded owned the process handle this
# failed about once in 300 runs (Start-Process -PassThru race on a child that exits in
# milliseconds), which surfaced as a spurious "expected exit 1, got " in the instrument run.
param([int]$Runs = 300)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'TestHelpers.ps1')
$exe = Join-Path $root 'tpscli.exe'
$bad = 0
for ($i = 0; $i -lt $Runs; $i++) {
    $r = Invoke-Tpscli_Bounded -FilePath $exe -ArgumentList @('--version') -WorkingDirectory $root
    if ($r.TimedOut -or $null -eq $r.ExitCode -or $r.ExitCode -ne 0 -or -not "$($r.StdOut)".Contains('"version"')) {
        $bad++
        Write-Host "helpers.ps1: run $i came back exit=[$($r.ExitCode)] timedOut=$($r.TimedOut) out=[$($r.StdOut)]"
    }
}
# stdin must read as EOF, not block: no argument means the exe looks at stdin for the statement
$n = Invoke-Tpscli_Bounded -FilePath $exe -ArgumentList @() -WorkingDirectory $root -TimeoutMs 5000
if ($n.TimedOut -or $n.ExitCode -ne 1 -or -not "$($n.StdOut)".Contains('No SQL statement given')) {
    $bad++
    Write-Host "helpers.ps1: empty-stdin run came back exit=[$($n.ExitCode)] timedOut=$($n.TimedOut) out=[$($n.StdOut)]"
}
if ($bad) { Write-Host "helpers.ps1: $bad of $Runs run(s) FAILED"; exit 1 }
Write-Host "helpers.ps1: OK ($Runs runs)"
exit 0
