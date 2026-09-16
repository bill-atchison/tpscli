param()
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$exe = Join-Path $root 'tpscli.exe'
$sqlPath = Join-Path $root 'tests\parser.sql'
$expPath = Join-Path $root 'tests\parser.expected.txt'

$lines = Get-Content $sqlPath
$out = New-Object System.Text.StringBuilder

foreach ($line in $lines) {
    $trimmed = $line.Trim()
    if ($trimmed -eq '' -or $trimmed.StartsWith('--')) { continue }

    $argList = @('--parse-only')
    if ($trimmed -match 'SECRET\.TPS') { $argList += @('--owner', 's3cret') }
    $argList += $trimmed

    Push-Location $root
    try {
        $stdout = & $exe @argList 2>&1
        $exit = $LASTEXITCODE
    } finally {
        Pop-Location
    }

    [void]$out.AppendLine($trimmed)
    foreach ($l in $stdout) { [void]$out.AppendLine([string]$l) }
    [void]$out.AppendLine("EXIT=$exit")
}

$actual = $out.ToString() -replace "`r`n", "`n"
$actual = $actual.TrimEnd("`n")

if (-not (Test-Path $expPath)) {
    Write-Host "No expected file at $expPath; writing actual output there for review."
    Set-Content -Path $expPath -Value $actual -NoNewline
    exit 1
}

$expected = (Get-Content $expPath -Raw) -replace "`r`n", "`n"
$expected = $expected.TrimEnd("`n")

if ($actual -ne $expected) {
    Write-Host "parser.ps1: MISMATCH between actual and expected output"
    $actLines = $actual -split "`n"
    $expLines = $expected -split "`n"
    $max = [Math]::Max($actLines.Count, $expLines.Count)
    for ($i = 0; $i -lt $max; $i++) {
        $a = if ($i -lt $actLines.Count) { $actLines[$i] } else { '<missing>' }
        $e = if ($i -lt $expLines.Count) { $expLines[$i] } else { '<missing>' }
        if ($a -ne $e) {
            Write-Host ("line {0}:" -f ($i+1))
            Write-Host ("  expected: {0}" -f $e)
            Write-Host ("  actual:   {0}" -f $a)
        }
    }
    exit 1
}

Write-Host "parser.ps1: OK ($($lines.Count) source lines)"
exit 0
