# Automates ..\docs\Testing\TpscliMcpConfig-Unit-Test-Cases.html: the MCP server against the real
# dtpos 4.04 CONFIG folder (reads, read-only server) and a copy of it under work\config (writes,
# each verified by a select). Same shape as tests\run-instrument.ps1 and deliberately self-contained:
# that runner is left as it is.
#
# Usage (from mcp\):  powershell -NoProfile -ExecutionPolicy Bypass -File tests\run-config-instrument.ps1
#                     [-Config C:\other\CONFIG] [-Only TC-05,TC-14]
# TC-08 needs the site's owner string in $env:TPSCLI_OWNER; without it the case records BLOCKED.
# Exit 0 when no case is FAIL, 1 otherwise.
param(
    [string]$OutFile = 'docs\Testing\TpscliMcpConfig-Unit-Test-Results.json',   # relative to the repository root
    [string]$Config = 'C:\Projects\GitLab\POS\dtpos_404_data\CONFIG',
    [string[]]$Only = @()
)
$ErrorActionPreference = 'Stop'
$Only = @($Only | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
$instrument = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'docs\Testing\TpscliMcpConfig-Unit-Test-Cases.html'
$root = Split-Path -Parent $PSScriptRoot          # mcp\
$repo = Split-Path -Parent $root                  # repository root, where docs\ and cli\ live
$callJs = Join-Path $root 'tools\call.js'
$serverJs = Join-Path $root 'dist\server.js'
$work = Join-Path $root 'work'
$node = (Get-Command node).Source
$cmdExe = $env:ComSpec

# ---- the case list comes from the instrument itself, so ids and step counts never drift ----
$parser = [IO.Path]::GetTempFileName() + '.js'
@'
const fs = require('fs'), vm = require('vm');
const html = fs.readFileSync(process.argv[2], 'utf8');
const s = html.indexOf('/* ============================ CUSTOMIZE START');
const e = html.indexOf('/* ============================= CUSTOMIZE END');
if (s < 0 || e < 0) { console.error('CUSTOMIZE block not found'); process.exit(2); }
const ctx = { document: undefined }; vm.runInNewContext(html.slice(s, e), ctx);
process.stdout.write(JSON.stringify({ storageKey: ctx.STORAGE_KEY, cases: ctx.CASES }));
'@ | Set-Content -Path $parser -Encoding ASCII
try { $suite = (& $node $parser $instrument) | ConvertFrom-Json } finally { Remove-Item $parser -ErrorAction SilentlyContinue }
if ($LASTEXITCODE -ne 0) { throw 'could not parse CASES from the instrument' }

# ---- per-case context and assertion helpers ----
$script:ctx = $null
function Start-Case($c) {
    $script:ctx = @{
        Id = $c.id; Steps = @($false) * $c.steps.Count
        Evidence = New-Object System.Collections.Generic.List[string]
        Fails    = New-Object System.Collections.Generic.List[string]
        Blocked  = $null
    }
}
function Tick([int]$n) { $script:ctx.Steps[$n - 1] = $true }
function Note([string]$text) { $script:ctx.Evidence.Add($text) }
function Fail([string]$why) { $script:ctx.Fails.Add($why); Note "  ** $why" }
function Block([string]$why) { $script:ctx.Blocked = $why; Note "  -- BLOCKED: $why" }   # verdict BLOCKED unless something also fails

function ConvertTo-CommandLine([string[]]$ArgumentList) {
    ($ArgumentList | ForEach-Object {
        if ($_ -eq '') { '""' } elseif ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ }
    }) -join ' '
}

# Runs one bounded process with the given stdin text and optional extra environment, logs the
# command and its output as evidence, kills it on timeout.
function Invoke-Logged([string]$Label, [string]$FilePath, [string[]]$Argv, [string]$Stdin = '', [hashtable]$Env = @{}, [int]$TimeoutMs = 60000) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = ConvertTo-CommandLine $Argv
    $psi.WorkingDirectory = $root
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardInput = $true
    foreach ($k in $Env.Keys) { $psi.EnvironmentVariables[$k] = $Env[$k] }
    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    Note "> $Label"
    try {
        # .NET Framework builds the child's stdin writer from [Console]::InputEncoding; a UTF-8
        # console carries a preamble, and a BOM in front of the JSON would break JSON.parse.
        $savedInput = $null
        try {
            if ([Console]::InputEncoding.GetPreamble().Length -gt 0) {
                $savedInput = [Console]::InputEncoding
                [Console]::InputEncoding = New-Object System.Text.UTF8Encoding($false)
            }
        } catch { $savedInput = $null }
        try { $null = $proc.Start() }
        finally { if ($savedInput) { try { [Console]::InputEncoding = $savedInput } catch {} } }
        if ($Stdin -ne '') { $proc.StandardInput.Write($Stdin) }
        $proc.StandardInput.Close()
        $outTask = $proc.StandardOutput.ReadToEndAsync()
        $errTask = $proc.StandardError.ReadToEndAsync()
        if (-not $proc.WaitForExit($TimeoutMs)) {
            try { & taskkill /PID $proc.Id /T /F | Out-Null } catch {}
            Note "  (killed after $TimeoutMs ms)"
            throw "$Label timed out after $TimeoutMs ms"
        }
        $proc.WaitForExit()
        $out = ($outTask.Result + '') -replace "`r`n", "`n"
        $err = ($errTask.Result + '') -replace "`r`n", "`n"
        foreach ($l in $out.TrimEnd("`n") -split "`n") { if ($l -ne '') { Note "  $l" } }
        foreach ($l in $err.TrimEnd("`n") -split "`n") { if ($l -ne '') { Note "  stderr: $l" } }
        Note "  exit $($proc.ExitCode)"
        [pscustomobject]@{ Out = $out.TrimEnd("`n"); Err = $err.TrimEnd("`n"); Exit = $proc.ExitCode }
    } finally { $proc.Dispose() }
}
# One tool call exactly as the instrument's CP-2 spells it: JSON on stdin, tool then server flags.
function Call([string]$Tool, [string]$Json = '', [string[]]$Flags = @(), [hashtable]$Env = @{}) {
    $label = if ($Json) { "'$Json' | node tools\call.js $Tool $($Flags -join ' ')" } else { "node tools\call.js $Tool $($Flags -join ' ')" }
    Invoke-Logged $label.TrimEnd() $node (@($callJs, $Tool) + $Flags) $Json $Env
}
function Server([string[]]$Flags) { Invoke-Logged ("node dist\server.js " + ($Flags -join ' ')) $node (@($serverJs) + $Flags) }
function Npm([string]$What, [int]$TimeoutMs = 600000) { Invoke-Logged "npm $What" $cmdExe @('/c', "npm $What") '' @{} $TimeoutMs }
function Fresh() {
    New-Item -ItemType Directory -Force $work | Out-Null
    Copy-Item (Join-Path $repo 'cli\testdata\*.TPS') $work -Force
    Note "> (CP-3) Copy-Item ..\cli\testdata\*.TPS work\ -Force"
}
function Json($r) { try { return $r.Out | ConvertFrom-Json } catch { Fail "output is not JSON: $($_.Exception.Message)"; return $null } }
function Expect-True([bool]$Cond, [string]$What) { if (-not $Cond) { Fail $What } }
function Expect-Exit($r, [int]$Code) { if ($r.Exit -ne $Code) { Fail "expected exit $Code, got $($r.Exit)" } }
function Expect-Contains($r, [string]$Needle) { if (-not $r.Out.Contains($Needle)) { Fail "expected output to contain $Needle" } }
function Expect-StderrContains($r, [string]$Needle) { if (-not $r.Err.Contains($Needle)) { Fail "expected stderr to contain $Needle" } }
function Expect-NoCallLine($r, [string]$Tool) { if ($r.Err.Contains("tpscli-mcp $Tool ")) { Fail "the exe ran ($Tool call line present) although the refusal should come first" } }
function Expect-CallLine($r, [string]$Tool, [int]$ExeExit) { if ($r.Err -notmatch "tpscli-mcp $Tool \d+ms exit $ExeExit") { Fail "expected stderr call line 'tpscli-mcp $Tool <n>ms exit $ExeExit'" } }
function Expect-Error($r, [string]$Code, [string]$Message = $null, [string]$Op = $null, [string]$Outcome = $null) {
    $j = Json $r; if (-not $j) { return }
    Expect-True ($j.ok -eq $false) 'expected ok false'
    Expect-True ($j.error.code -eq $Code) "expected error.code $Code, got $($j.error.code)"
    if ($Message) { Expect-True ($j.error.message -eq $Message) "expected message '$Message', got '$($j.error.message)'" }
    if ($Op) { Expect-True ($j.op -eq $Op) "expected op $Op, got $($j.op)" }
    if ($Outcome) { Expect-True ($j.outcome -eq $Outcome) "expected outcome $Outcome, got $($j.outcome)" }
    Expect-True ($j.complete -eq $true) 'expected complete true'
    Expect-Exit $r 1
    return $j
}
function Expect-Ok($r, [string]$Op) {
    $j = Json $r; if (-not $j) { return }
    Expect-True ($j.ok -eq $true) "expected ok true, got $($r.Out)"
    Expect-True ($j.op -eq $Op) "expected op $Op, got $($j.op)"
    Expect-True ($j.complete -eq $true) 'expected complete true'
    Expect-Exit $r 0
    return $j
}
if (-not (Test-Path (Join-Path $Config 'OPTIONS.TPS'))) { throw "no OPTIONS.TPS under $Config" }
$cfg = $Config
$copy = Join-Path $work 'config'
$ro = @('--root', $cfg)                                  # read-only server on the real folder
$rw = @('--root', 'work\config', '--allow-writes')       # writes go to the copy only
$absOpt = (Join-Path $copy 'OPTIONS.TPS') -replace '\\', '\\'   # for tps_query statements (JSON string)
$qcm = "CUSTOMER = 'DLT' AND MODULE = 'Tenders' AND VARIABLE = 'QuickCashMode'"
$uts = "CUSTOMER = 'UTS'"

function FreshConfig() {
    New-Item -ItemType Directory -Force $copy | Out-Null
    Copy-Item (Join-Path $cfg '*.TPS') $copy -Force
    Note "> (CP-3) Copy-Item `$cfg\*.TPS work\config\ -Force"
}
function Expect-Rows($r, [int]$Count) {
    $j = Expect-Ok $r 'select'; if (-not $j) { return $null }
    Expect-True ($j.row_count -eq $Count) "expected row_count $Count, got $($j.row_count)"
    Expect-True ($j.rows.Count -eq $Count) "expected $Count rows, got $($j.rows.Count)"
    return $j
}
function Expect-Row($j, [int]$Index, [string[]]$Values) {
    if (-not $j) { return }
    $row = @($j.rows[$Index])
    $got = $row -join '|'; $want = $Values -join '|'
    Expect-True ($got -eq $want) "row $Index expected [$want], got [$got]"
}
function Expect-Value([string[]]$Flags, [string]$Where, [string]$Value) {
    $r = Call tps_select ('{"file":"OPTIONS.TPS","columns":["VALUE"],"where":"' + $Where + '"}') $Flags
    $j = Expect-Rows $r 1; Expect-Row $j 0 @($Value); return $r
}
function Expect-Write($r, [string]$Op, [int]$Matched, [int]$Affected) {
    $j = Expect-Ok $r $Op; if (-not $j) { return $null }
    if ($Op -ne 'insert') { Expect-True ($j.matched -eq $Matched) "expected matched $Matched, got $($j.matched)" }
    Expect-True ($j.affected -eq $Affected) "expected affected $Affected, got $($j.affected)"
    return $j
}
function Expect-OptionsRecords([string[]]$Flags, [int]$Expected) {
    $r = Call tps_describe '{"file":"OPTIONS.TPS"}' $Flags; $j = Expect-Ok $r 'describe'
    if ($j) { Expect-True ($j.records -eq $Expected) "expected records $Expected, got $($j.records)" }
}

$run = @{
'TC-01' = {
    $r = Npm 'run build'; Expect-Exit $r 0; Tick 1
    $r = Call tps_version; $j = Json $r
    if ($j) { Expect-True ($j.server -eq '0.2.0' -and $j.exe.version -eq '0.1.0' -and $j.exe.ok -eq $true) "expected server 0.2.0 and exe 0.1.0, got $($r.Out)" }
    Expect-Exit $r 0; Tick 2
    $r = Call tps_describe '{"file":"OPTIONS.TPS"}' $ro; $j = Json $r
    if ($j -and $j.ok -ne $true) { Block "the exe cannot open OPTIONS.TPS ($($j.error.code): $($j.error.message)); rebuild the CLI from commit 9aab623 or later" }
    elseif ($j) { Expect-True ($j.records -eq 407) "expected records 407, got $($j.records)" }
    Tick 3
}
'TC-02' = {
    FreshConfig; Tick 1
    $n = (Get-ChildItem (Join-Path $copy '*.TPS')).Count; Note "> (Get-ChildItem work\config\*.TPS).Count"; Note "  $n"
    Expect-True ($n -eq 64) "expected 64 files in the copy, got $n"; Tick 2
    $r = Call tps_list_files '' @('--root', 'work\config'); $j = Json $r; Expect-Exit $r 0
    if ($j) {
        Expect-True ($j.files.Count -eq 64) "expected 64 listed, got $($j.files.Count)"
        $o = $j.files | Where-Object { $_.name -eq 'OPTIONS.TPS' }
        Expect-True ($null -ne $o -and $o.size -eq 118016 -and $o.path.StartsWith($copy)) "expected OPTIONS.TPS size 118016 under $copy, got $($o | ConvertTo-Json -Compress)"
    }
    Tick 3
}
'TC-03' = {
    $r = Call tps_list_files '' $ro; $j = Json $r; Expect-Exit $r 0; Expect-NoCallLine $r 'tps_list_files'
    if ($j) {
        Expect-True ($j.files.Count -eq 64) "expected 64 files, got $($j.files.Count)"
        $o = $j.files | Where-Object { $_.name -eq 'OPTIONS.TPS' }
        Expect-True ($null -ne $o -and $o.size -eq 118016 -and $o.path.StartsWith($cfg)) "expected OPTIONS.TPS size 118016 under $cfg"
        Expect-True (($j.files | Where-Object { -not $_.path.StartsWith($cfg) }).Count -eq 0) 'every path starts with the config folder'
    }
    Tick 1
    $r = Call tps_list_files '{"pattern":"OPT*"}' $ro; $j = Json $r; Expect-Exit $r 0; Expect-NoCallLine $r 'tps_list_files'
    if ($j) { $names = @($j.files | ForEach-Object name) -join ','; Expect-True ($names -eq 'options.SCN,OPTIONS.TPS') "expected options.SCN,OPTIONS.TPS, got $names" }
    Tick 2
}
'TC-04' = {
    $r = Call tps_describe '{"file":"OPTIONS.TPS"}' $ro; $j = Expect-Ok $r 'describe'; Expect-CallLine $r 'tps_describe' 0; Tick 1
    if ($j) {
        Expect-True ($j.file.EndsWith('\CONFIG\OPTIONS.TPS')) "file is $($j.file)"
        Expect-True ($j.encrypted -eq $false -and $j.records -eq 407) "expected encrypted false, records 407; got $($j.encrypted), $($j.records)"
        $cols = ($j.columns | ForEach-Object { "$($_.name) $($_.type) $($_.size)" }) -join '; '
        Expect-True ($cols -eq 'CUSTOMER STRING 32; MODULE STRING 32; VARIABLE STRING 32; VALUE STRING 64; ENTRYPICTURE STRING 20; DESCRIPTION STRING 50; COMMENTS STRING 1024') "columns: $cols"
        $keys = ($j.keys | ForEach-Object { "$($_.name) primary=$($_.primary) unique=$($_.unique) nocase=$($_.nocase) " + (($_.components | ForEach-Object { "$($_.col):$($_.asc)" }) -join ',') }) -join '; '
        Expect-True ($keys -eq 'OPTKEY primary=False unique=True nocase=True CUSTOMER:True,MODULE:True,VARIABLE:True; DESCRIPTKEY primary=False unique=False nocase=True CUSTOMER:True,MODULE:True,DESCRIPTION:True') "keys: $keys"
    }
    Tick 2
}
'TC-05' = {
    $r = Call tps_select '{"file":"OPTIONS.TPS","columns":["CUSTOMER","VARIABLE","VALUE"],"where":"MODULE = ''Tenders''"}' $ro
    $j = Expect-Rows $r 6
    if ($j) {
        Expect-True ($j.truncated -eq $false) 'expected truncated false'
        $got = ($j.rows | ForEach-Object { $_ -join '/' }) -join '; '
        Expect-True ($got -eq 'JDA/Accept All Manual Credit Cards/N; JDA/EBT Default Expiration/1249; DLT/EnableQuickCash/N; DLT/QuickCashMode/I; DLT/AmountOKThreshold/999.99; DLT/AmountOKCashBack/N') "Tenders rows: $got"
    }
    Tick 1
    $r = Call tps_select '{"file":"OPTIONS.TPS","columns":["VARIABLE","VALUE"],"where":"CUSTOMER = ''DLT'' AND MODULE = ''BOPIS''","order_by":"VARIABLE"}' $ro
    $j = Expect-Rows $r 6
    if ($j) { $got = ($j.rows | ForEach-Object { $_ -join '=' }) -join '; '; Expect-True ($got -eq 'CheckInterval=10; Enabled=N; Path=C:\JDA\BOPIS\JSON; UnprocessedPath=C:\JDA\BOPIS\Unprocessed; ValidTypes=1,2,3; WarningThreshold=20') "BOPIS rows: $got" }
    Tick 2
    Expect-Value $ro $qcm 'I' | Out-Null; Tick 3
}
'TC-06' = {
    $base = '{"file":"OPTIONS.TPS","columns":["CUSTOMER","MODULE","VARIABLE","VALUE"],"order_by":"CUSTOMER, MODULE, VARIABLE","limit":12'
    $r = Call tps_select ($base + '}') $ro; $j = Expect-Rows $r 12
    if ($j) { Expect-True ($j.truncated -eq $true) 'expected truncated true'; Expect-Row $j 0 @('DLT', 'AssociateSale', 'DefaultAllowPurchase', 'Y') }
    Tick 1
    $r = Call tps_select ($base + ',"offset":12}') $ro; $j = Expect-Rows $r 12
    if ($j) { Expect-True ($j.truncated -eq $true) 'expected truncated true'; Expect-Row $j 0 @('DLT', 'Device', 'Serial Secondary Scanner Port', 'COM7'); Expect-Row $j 11 @('DLT', 'GiftCard', 'GiftCardType', '00950') }
    Tick 2
    $r = Call tps_select '{"file":"OPTIONS.TPS","columns":["CUSTOMER"],"limit":0}' $ro; $j = Expect-Rows $r 407
    if ($j) { Expect-True ($j.truncated -eq $false) 'expected truncated false' }
    Tick 3
    $r = Call tps_select '{"file":"OPTIONS.TPS","columns":["CUSTOMER","MODULE","VARIABLE"],"order_by":"CUSTOMER, MODULE, VARIABLE","limit":3,"format":"table"}' $ro
    Expect-Exit $r 0
    $lines = @($r.Out -split "`n" | ForEach-Object { $_.TrimEnd() })
    Expect-True ($lines[0] -eq 'CUSTOMER  MODULE         VARIABLE') "header line: $($lines[0])"
    Expect-True ($lines[2] -eq 'DLT       AssociateSale  DefaultAllowPurchase' -and $lines[3] -eq 'DLT       AssociateSale  ReportDayofWeek' -and $lines[4] -eq 'DLT       BOPIS          CheckInterval') "grid rows: $($lines[2..4] -join ' / ')"
    Expect-True ($lines[-1] -eq '(3 rows, truncated by LIMIT)') "last line: $($lines[-1])"
    Tick 4
}
'TC-07' = {
    $want = @{ CACODE = '107/7'; COMNDMST = '97/50'; CRPCMCFG = '42/4'; EODMNT = '133/10'; ERRORMSG = '247/3'; INCOMMCC = '56/8'; keybrdrv = '67/7'; OPTIONS = '407/7'; PMINTHDR = '137/8'; RPTDEF = '12/14' }
    foreach ($n in 'CACODE', 'COMNDMST', 'CRPCMCFG', 'EODMNT', 'ERRORMSG', 'INCOMMCC', 'keybrdrv', 'OPTIONS', 'PMINTHDR', 'RPTDEF') {
        $r = Call tps_describe ('{"file":"' + $n + '.TPS"}') $ro; $j = Json $r
        if ($j -and $j.ok -ne $true) { Fail "$n : $($j.error.code) $($j.error.message)" }
        elseif ($j) { $got = "$($j.records)/$($j.columns.Count)"; Expect-True ($got -eq $want[$n]) "$n expected records/cols $($want[$n]), got $got" }
    }
    Tick 1
    $r = Call tps_describe '{"file":"SCRFIELD.TPS"}' $ro
    Expect-Error $r 'DEFINITION_UNREADABLE' 'File holds more than one table (1 and 17669); multi-table TPS files are not supported' 'describe' | Out-Null
    Tick 2
}
'TC-08' = {
    $r = Call tps_describe '{"file":"ACCESS.TPS"}' $ro
    Expect-Error $r 'OWNER_REQUIRED' 'Not a plain TopSpeed file; if it is encrypted pass --owner' 'describe' | Out-Null
    Tick 1
    $owner = $env:TPSCLI_OWNER
    if (-not $owner) { Block 'owner string not available in TPSCLI_OWNER; steps 2 and 3 not run'; return }
    Note "> (CP-4) `$env:TPSCLI_OWNER set for this window"
    $r = Call tps_describe '{"file":"ACCESS.TPS"}' $ro @{ TPSCLI_OWNER = $owner }; $j = Expect-Ok $r 'describe'
    if ($j) { Expect-True ($j.encrypted -eq $true) 'expected encrypted true' }
    Expect-True (-not $r.Out.Contains($owner) -and -not $r.Err.Contains($owner)) 'the owner string leaked into the output'
    Expect-StderrContains $r 'owner set'
    Tick 2
    Note "> Remove-Item Env:TPSCLI_OWNER"; Tick 3
}
'TC-09' = {
    $file = Join-Path $cfg 'OPTIONS.TPS'
    $h1 = (Get-FileHash $file).Hash; Note "> `$h1 = (Get-FileHash `$cfg\OPTIONS.TPS).Hash"; Note "  $h1"; Tick 1
    $r = Call tps_describe '{"file":"OPTIONS.TPS"}' $ro; Expect-Exit $r 0
    $r = Call tps_select '{"file":"OPTIONS.TPS","limit":0}' $ro; Expect-Exit $r 0; Tick 2
    $h2 = (Get-FileHash $file).Hash; Note "> `$h2 = (Get-FileHash `$cfg\OPTIONS.TPS).Hash ; `$h1 -eq `$h2"; Note "  $h2"; Note "  $($h1 -eq $h2)"
    Expect-True ($h1 -eq $h2) "the file's SHA-256 changed: $h1 -> $h2"; Tick 3
}
'TC-10' = {
    $msg = 'This server was started without --allow-writes, so INSERT, UPDATE and DELETE are refused. Restart it with --allow-writes to enable them.'
    $r = Call tps_update ('{"file":"OPTIONS.TPS","set":{"VALUE":"C"},"where":"' + $qcm + '"}') $ro
    Expect-Error $r 'WRITES_DISABLED' $msg 'update' 'none' | Out-Null; Expect-NoCallLine $r 'tps_update'; Tick 1
    $r = Call tps_delete ('{"file":"OPTIONS.TPS","where":"' + $uts + '"}') $ro
    Expect-Error $r 'WRITES_DISABLED' $msg 'delete' 'none' | Out-Null; Expect-NoCallLine $r 'tps_delete'; Tick 2
    Expect-Value $ro $qcm 'I' | Out-Null; Tick 3
}
'TC-11' = {
    $r = Call tps_insert '{"file":"OPTIONS.TPS","values":{"CUSTOMER":"UTS","MODULE":"Test","VARIABLE":"InsertedByMcp","VALUE":"yes","ENTRYPICTURE":"@s64","DESCRIPTION":"Inserted by the unit-test instrument","COMMENTS":"TC-11"}}' $rw
    Expect-Write $r 'insert' 0 1 | Out-Null; Tick 1
    $r = Call tps_select ('{"file":"OPTIONS.TPS","where":"' + $uts + '"}') @('--root', 'work\config'); $j = Expect-Rows $r 1
    Expect-Row $j 0 @('UTS', 'Test', 'InsertedByMcp', 'yes', '@s64', 'Inserted by the unit-test instrument', 'TC-11'); Tick 2
    Expect-OptionsRecords @('--root', 'work\config') 408; Tick 3
}
'TC-12' = {
    foreach ($v in '{"file":"OPTIONS.TPS","values":{"CUSTOMER":"UTS","MODULE":"Test","VARIABLE":"InsertedByMcp","VALUE":"again"}}',
                   '{"file":"OPTIONS.TPS","values":{"CUSTOMER":"uts","MODULE":"test","VARIABLE":"insertedbymcp","VALUE":"again"}}') {
        $r = Call tps_insert $v $rw; $j = Expect-Error $r 'DUPLICATE_KEY' 'Duplicate value for key OPTKEY' 'insert' 'none'
        if ($j) { Expect-True ($j.error.key -eq 'OPTKEY') "expected error.key OPTKEY, got $($j.error.key)" }
    }
    Tick 1; Tick 2
    Expect-Value @('--root', 'work\config') $uts 'yes' | Out-Null; Tick 3
}
'TC-13' = {
    $r = Call tps_update '{"file":"OPTIONS.TPS","set":{"VALUE":"no","COMMENTS":"TC-13 updated"},"where":"CUSTOMER = ''UTS'' AND VARIABLE = ''InsertedByMcp''"}' $rw
    Expect-Write $r 'update' 1 1 | Out-Null; Tick 1
    $r = Call tps_select ('{"file":"OPTIONS.TPS","columns":["VALUE","COMMENTS","DESCRIPTION"],"where":"' + $uts + '"}') @('--root', 'work\config')
    $j = Expect-Rows $r 1; Expect-Row $j 0 @('no', 'TC-13 updated', 'Inserted by the unit-test instrument'); Tick 2
}
'TC-14' = {
    $r = Call tps_update ('{"file":"OPTIONS.TPS","set":{"VALUE":"C"},"where":"' + $qcm + '"}') $rw; Expect-Write $r 'update' 1 1 | Out-Null; Tick 1
    Expect-Value @('--root', 'work\config') $qcm 'C' | Out-Null; Tick 2
    $r = Call tps_select '{"file":"OPTIONS.TPS","columns":["CUSTOMER","VARIABLE","VALUE"],"where":"MODULE = ''Tenders''"}' @('--root', 'work\config')
    $j = Expect-Rows $r 6
    if ($j) { $got = ($j.rows | ForEach-Object { $_ -join '/' }) -join '; '; Expect-True ($got -eq 'JDA/Accept All Manual Credit Cards/N; JDA/EBT Default Expiration/1249; DLT/EnableQuickCash/N; DLT/QuickCashMode/C; DLT/AmountOKThreshold/999.99; DLT/AmountOKCashBack/N') "Tenders rows after the update: $got" }
    Tick 3
    $r = Call tps_update ('{"file":"OPTIONS.TPS","set":{"VALUE":"I"},"where":"' + $qcm + '"}') $rw; Expect-Write $r 'update' 1 1 | Out-Null; Tick 4
    Expect-Value @('--root', 'work\config') $qcm 'I' | Out-Null; Tick 5
}
'TC-15' = {
    $long = '0123456789' * 7
    Note "> `$long = '0123456789' * 7"
    $r = Call tps_update ('{"file":"OPTIONS.TPS","set":{"VALUE":"' + $long + '"},"where":"' + $uts + '"}') $rw
    $j = Expect-Write $r 'update' 1 1
    if ($j) {
        $w = @($j.warnings)
        Expect-True ($w.Count -eq 1 -and $w[0].code -eq 'STRING_TRUNCATED' -and $w[0].column -eq 'VALUE' -and $w[0].message -eq 'Value truncated to 64 characters') "warnings: $($j.warnings | ConvertTo-Json -Compress)"
    }
    Tick 1
    Expect-Value @('--root', 'work\config') $uts $long.Substring(0, 64) | Out-Null; Tick 2
}
'TC-16' = {
    $r = Call tps_delete ('{"file":"OPTIONS.TPS","where":"' + $uts + '"}') $rw; Expect-Write $r 'delete' 1 1 | Out-Null; Tick 1
    $r = Call tps_select ('{"file":"OPTIONS.TPS","where":"' + $uts + '"}') @('--root', 'work\config'); Expect-Rows $r 0 | Out-Null; Tick 2
    Expect-OptionsRecords @('--root', 'work\config') 407; Tick 3
}
'TC-17' = {
    $where = "CUSTOMER = 'DLT' AND MODULE = 'BOPIS' AND VARIABLE = 'CheckInterval'"
    $upd = { param($v) '{"sql":"UPDATE [' + $absOpt + '] SET VALUE = ''' + $v + ''' WHERE ' + $where + '"' }
    $sel = '{"sql":"SELECT VALUE FROM [' + $absOpt + '] WHERE ' + $where + '"}'
    $r = Call tps_query ((& $upd '15') + ',"parse_only":true}') @(); $j = Expect-Ok $r 'update'
    if ($j) { Expect-True ($j.parse_only -eq $true -and $null -eq $j.matched -and $null -eq $j.affected) "expected parse_only true and no matched/affected, got $($r.Out)" }
    Tick 1
    $r = Call tps_query $sel @(); $j = Expect-Rows $r 1; Expect-Row $j 0 @('10'); Tick 2
    $r = Call tps_query ((& $upd '15') + '}') @('--allow-writes'); Expect-Write $r 'update' 1 1 | Out-Null; Tick 3
    $r = Call tps_query $sel @(); $j = Expect-Rows $r 1; Expect-Row $j 0 @('15'); Tick 4
    $r = Call tps_query ((& $upd '10') + '}') @('--allow-writes'); Expect-Write $r 'update' 1 1 | Out-Null; Tick 5
    $r = Call tps_query $sel @(); $j = Expect-Rows $r 1; Expect-Row $j 0 @('10'); Tick 6
}
'TC-18' = {
    $want = @{ PMINTDTL = '926/4'; PDCONFIG = '1/43'; CPSTATE = '68/3'; REFSMTBL = '268/3' }
    foreach ($n in 'PMINTDTL', 'PDCONFIG', 'CPSTATE', 'REFSMTBL') {
        $r = Call tps_describe ('{"file":"' + $n + '.TPS"}') $ro; $d = Expect-Ok $r 'describe'
        $r = Call tps_select ('{"file":"' + $n + '.TPS","limit":0}') $ro; $s = Expect-Ok $r 'select'
        if ($d -and $s) {
            $got = "$($d.records)/$($d.columns.Count)"
            Expect-True ($got -eq $want[$n]) "$n expected records/cols $($want[$n]), got $got"
            Expect-True ($s.row_count -eq $d.records -and $s.truncated -eq $false) "$n rows $($s.row_count) truncated $($s.truncated) vs records $($d.records)"
        }
    }
    Tick 1
}
}

$missing = @($suite.cases | Where-Object { -not $run.ContainsKey($_.id) } | ForEach-Object id)
if ($missing.Count) { throw "no executor for instrument case(s): $($missing -join ', ')" }
$started = Get-Date
$results = @()
foreach ($c in $suite.cases) {
    if ($Only.Count -and $Only -notcontains $c.id) { continue }
    Start-Case $c
    $threw = $null
    try { & $run[$c.id] } catch { $threw = $_.Exception.Message; Fail "aborted: $threw" }
    $verdict = if ($script:ctx.Fails.Count) { 'FAIL' } elseif ($script:ctx.Blocked) { 'BLOCKED' } else { 'PASS' }
    $notes = if ($verdict -eq 'PASS') { "Automated run $($started.ToString('yyyy-MM-dd HH:mm')): every check passed." } elseif ($verdict -eq 'BLOCKED') { "Automated run $($started.ToString('yyyy-MM-dd HH:mm')): $($script:ctx.Blocked)" } else { ($script:ctx.Fails -join "`n") }
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
    suite = 'tpscli-mcp-config-0-1-0'; storage_key = $suite.storageKey; runner = 'tests\run-config-instrument.ps1'
    build = (git -C $root rev-parse --short HEAD); ref = (git -C $root rev-parse --abbrev-ref HEAD)
    env = "$env:COMPUTERNAME / $([Environment]::OSVersion.VersionString) / PowerShell $($PSVersionTable.PSVersion) / node $(& $node --version)"
    started = $started.ToString('s'); finished = (Get-Date).ToString('s'); tally = $tally; cases = $results
}
$json = ($doc | ConvertTo-Json -Depth 6) -replace "(?<!`r)`n", "`r`n"
[IO.File]::WriteAllText((Join-Path $repo $OutFile), $json + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
Write-Host ''
Write-Host "run-config-instrument.ps1: PASS $($tally.PASS) FAIL $($tally.FAIL) BLOCKED $($tally.BLOCKED) -> $OutFile"
if ($tally.FAIL -gt 0) { exit 1 } else { exit 0 }
