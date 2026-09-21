# Builds, qualifies and packs one release of tpscli: the exe (cli\verify.ps1 over the generated corpus
# is the gate), the MCP server (npm ci, build, test), then one zip that installs by unzipping. Run by
# the release workflow on a tag push, or by hand from the repository root:
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\release.ps1 -Version v0.2.0   # a release
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\release.ps1 -SkipVerify       # pack only (dry run)
#
# tpscli reads every layout from the .TPS file itself and depends on no dictionary, so the release
# gate is the repository's own corpus and suites. verify.ps1's real-file checks (-Extra, -Expected,
# -TpsFixLog: your own files, your dictionary export, your TPSFix log) are an optional extra a site
# can run before adopting a build; they are forwarded when given and never required.
# -Version must match mcp\package.json (a leading v is allowed). The release number is the server's;
# the exe reports its own version inside (tpscli.exe --version) and in notes.md.
# Output: release\tpscli-<version>-win-x64.zip, its .sha256, and release\notes.md.
param(
    [string]$Version = '',
    [string]$Extra = '',        # optional, forwarded to cli\verify.ps1: a folder of your own .TPS copies
    [string]$Expected = '',     # optional, forwarded: the folder of dictionary-export JSON for those files
    [string]$TpsFixLog = '',    # optional, forwarded: the TPSFix log for those files (required with -Extra)
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
        $ErrorActionPreference = 'Continue'    # scoped to this function; a native command's stderr line
                                                # (npm warn/notice) must not become a terminating error under
                                                # the script-level Stop -- only $LASTEXITCODE decides failure
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
    # Step 7 budgets the exe's process lifetime at 250 ms on the reference machine; the first release
    # run measured 731 ms inside the Actions job on the same (ARM64, emulating) machine that gives
    # 96 ms by hand. A release build only fails a gross regression; the median is printed either way.
    $verifyArgs += @('-PerfBudgetMs', '1000')
    Run 'cli\verify.ps1 (build, corpus, suites, gate)' (Join-Path $repo 'cli') { powershell -NoProfile -ExecutionPolicy Bypass -File verify.ps1 @verifyArgs } | Out-Null
}
$exe = Join-Path $repo 'cli\tpscli.exe'
. (Join-Path $repo 'cli\tests\TestHelpers.ps1')    # Invoke-Tpscli_Bounded: the exe never runs without a timeout
$v = Invoke-Tpscli_Bounded -FilePath $exe -ArgumentList @('--version') -WorkingDirectory (Join-Path $repo 'cli') -TimeoutMs 20000
if ($v.TimedOut -or $v.ExitCode -ne 0) { throw "release.ps1: tpscli.exe --version failed (timed out $($v.TimedOut), exit $($v.ExitCode)): $($v.StdOut)$($v.StdErr)" }
$exeVersion = ($v.StdOut | ConvertFrom-Json).version
Run 'npm ci' (Join-Path $repo 'mcp') { npm ci } | Out-Null
Run 'npm run build' (Join-Path $repo 'mcp') { npm run build } | Out-Null
if (-not $SkipVerify) { Run 'npm test' (Join-Path $repo 'mcp') { npm test } | Out-Null }

# ---- stage: the layout the MCP guide's "Move the server" describes; the exe inside dist\ is
# first in the server's search order, so no --exe flag is needed ----
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
Run 'npm ci --omit=dev (production node_modules in the stage)' $stage { npm ci --omit=dev --ignore-scripts } | Out-Null
Remove-Item (Join-Path $stage 'package-lock.json')    # served its purpose; the zip needs no npm

# ---- zip, checksum, notes ----
New-Item -ItemType Directory -Force -Path $out | Out-Null
$zip = Join-Path $out "$name.zip"
if (Test-Path $zip) { Remove-Item $zip }
Compress-Archive -Path $stage -DestinationPath $zip
$hash = (Get-FileHash $zip -Algorithm SHA256).Hash
"$hash  $name.zip" | Set-Content (Join-Path $out "$name.zip.sha256") -Encoding ASCII
$notes = @"
tpscli ${ver}: tpscli.exe $exeVersion and tpscli-mcp $ver, Windows x64, Node 20 or later.

Unzip anywhere, then register the server (Claude Code shown; Claude Desktop takes the same command):

    claude mcp add -s user tpscli -- node "<folder>\$name\dist\server.js" --allow-writes

The exe is inside dist\ beside server.js, so no --exe flag is needed. tools\call.js runs one tool
from the command line (node tools\call.js tps_version). README.md and docs\ hold the guides.

SHA-256 $hash  $name.zip
"@
[IO.File]::WriteAllText((Join-Path $out 'notes.md'), $notes, (New-Object System.Text.UTF8Encoding($false)))
Write-Host ("release.ps1: {0} ({1:N1} MB) sha256 {2}" -f $zip, ((Get-Item $zip).Length / 1MB), $hash)
