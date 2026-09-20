# Builds, qualifies and packs one release of tpscli: the exe (cli\verify.ps1 is the gate), the MCP
# server (npm ci, build, test), then one zip that installs by unzipping. Run by the release workflow
# on a tag push, or by hand from the repository root:
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\release.ps1 -Version v0.2.0 `
#       -Extra C:\tps\dtpos -Expected C:\tps\dtpos-expected -TpsFixLog C:\tps\tpsfix.log   # a release
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\release.ps1 -AllowSkips      # local build, corpus gate only
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\release.ps1 -SkipVerify      # pack only (dry run)
#
# cli\verify.ps1 without -Extra/-Expected/-TpsFixLog skips the real-file, dictionary-parity and TPSFix
# checks and says so ("not a release qualification") while still exiting 0; this script refuses that
# run unless -AllowSkips is given, so the workflow cannot publish an unqualified build by accident.
# -Version must match mcp\package.json (a leading v is allowed). The release number is the server's;
# the exe reports its own version inside (tpscli.exe --version) and in notes.md.
# Output: release\tpscli-<version>-win-x64.zip, its .sha256, and release\notes.md.
param(
    [string]$Version = '',
    [string]$Extra = '',        # forwarded to cli\verify.ps1: the folder of real-world .TPS copies
    [string]$Expected = '',     # forwarded: the folder of dictionary-export JSON
    [string]$TpsFixLog = '',    # forwarded: the TPSFix log for those files (required with -Extra)
    [switch]$AllowSkips,        # accept a verify.ps1 run that skipped the three checks above (local builds only)
    [switch]$SkipVerify         # skip cli\verify.ps1 and npm test: a dry run of the packing only, never a release
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$pkg = Get-Content (Join-Path $repo 'mcp\package.json') -Raw | ConvertFrom-Json
$ver = $pkg.version
if ($Version -and ($Version -replace '^v', '') -ne $ver) { throw "release.ps1: -Version $Version does not match mcp\package.json ($ver); bump the package first" }
$name = "tpscli-$ver-win-x64"
$out = Join-Path $repo 'release'
$stage = Join-Path $out $name

function Run([string]$Label, [string]$Dir, [scriptblock]$Body) {
    Write-Host "release.ps1: $Label"
    Push-Location $Dir
    try {
        $global:LASTEXITCODE = 0
        $output = & $Body 2>&1 | ForEach-Object { "$_" }
        $output | Write-Host
        if ($LASTEXITCODE -ne 0) { throw "release.ps1: $Label failed ($LASTEXITCODE)" }
        return $output
    } finally { Pop-Location }
}

# ---- build and qualify ----
if ($SkipVerify) {
    Run 'cli\tools\build.ps1' (Join-Path $repo 'cli') { powershell -NoProfile -ExecutionPolicy Bypass -File tools\build.ps1 } | Out-Null
} else {
    $verifyArgs = @()
    if ($Extra) { $verifyArgs += @('-Extra', $Extra) }
    if ($Expected) { $verifyArgs += @('-Expected', $Expected) }
    if ($TpsFixLog) { $verifyArgs += @('-TpsFixLog', $TpsFixLog) }
    $verifyOutput = Run 'cli\verify.ps1 (build, corpus, suites, gate)' (Join-Path $repo 'cli') { powershell -NoProfile -ExecutionPolicy Bypass -File verify.ps1 @verifyArgs }
    if (($verifyOutput -join "`n") -match 'not a release qualification' -and -not $AllowSkips) {
        throw 'release.ps1: verify.ps1 skipped the real-file checks (no -Extra/-Expected/-TpsFixLog); pass them, or -AllowSkips for a local build'
    }
}
$exe = Join-Path $repo 'cli\tpscli.exe'
. (Join-Path $repo 'cli\tests\TestHelpers.ps1')    # Invoke-Tpscli_Bounded: the exe never runs without a timeout
$v = Invoke-Tpscli_Bounded -FilePath $exe -ArgumentList @('--version') -WorkingDirectory (Join-Path $repo 'cli') -TimeoutMs 20000
if ($v.TimedOut -or $v.ExitCode -ne 0) { throw "release.ps1: tpscli.exe --version failed (timed out $($v.TimedOut), exit $($v.ExitCode)): $($v.StdOut)$($v.StdErr)" }
$exeVersion = ($v.StdOut | ConvertFrom-Json).version
Run 'npm ci' (Join-Path $repo 'mcp') { npm ci }
Run 'npm run build' (Join-Path $repo 'mcp') { npm run build }
if (-not $SkipVerify) { Run 'npm test' (Join-Path $repo 'mcp') { npm test } }

# ---- stage: the layout the MCP guide's "Move the server" describes; the exe inside dist\ is
# second in the server's search order, so no --exe flag is needed ----
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
New-Item -ItemType Directory -Force -Path (Join-Path $stage 'dist'), (Join-Path $stage 'tools'), (Join-Path $stage 'docs') | Out-Null
Copy-Item (Join-Path $repo 'mcp\dist\*.js') (Join-Path $stage 'dist')
Copy-Item $exe (Join-Path $stage 'dist\tpscli.exe')
Copy-Item (Join-Path $repo 'mcp\package.json') $stage
Copy-Item (Join-Path $repo 'mcp\package-lock.json') $stage
Copy-Item (Join-Path $repo 'mcp\tools\call.js') (Join-Path $stage 'tools')
Copy-Item (Join-Path $repo 'mcp\README.md') (Join-Path $stage 'README.md')
Copy-Item (Join-Path $repo 'cli\README.md') (Join-Path $stage 'docs\tpscli-cli-README.md')
Copy-Item (Join-Path $repo 'docs\UserGuide\*.html') (Join-Path $stage 'docs')
Run 'npm ci --omit=dev (production node_modules in the stage)' $stage { npm ci --omit=dev --ignore-scripts }
Remove-Item (Join-Path $stage 'package-lock.json')    # served its purpose; the zip needs no npm

# ---- zip, checksum, notes ----
New-Item -ItemType Directory -Force -Path $out | Out-Null
$zip = Join-Path $out "$name.zip"
if (Test-Path $zip) { Remove-Item $zip }
Compress-Archive -Path $stage -DestinationPath $zip
$hash = (Get-FileHash $zip -Algorithm SHA256).Hash
"$hash  $name.zip" | Set-Content (Join-Path $out "$name.zip.sha256") -Encoding ASCII
@"
tpscli ${ver}: tpscli.exe $exeVersion and tpscli-mcp $ver, Windows x64, Node 20 or later.

Unzip anywhere, then register the server (Claude Code shown; Claude Desktop takes the same command):

    claude mcp add -s user tpscli -- node "<folder>\$name\dist\server.js" --allow-writes

The exe is inside dist\ beside server.js, so no --exe flag is needed. tools\call.js runs one tool
from the command line (node tools\call.js tps_version). README.md and docs\ hold the guides.

SHA-256 $hash  $name.zip
"@ | Set-Content (Join-Path $out 'notes.md') -Encoding UTF8
Write-Host ("release.ps1: {0} ({1:N1} MB) sha256 {2}" -f $zip, ((Get-Item $zip).Length / 1MB), $hash)
