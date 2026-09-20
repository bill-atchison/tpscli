# Automates ..\docs\Testing\TpscliMcp-Unit-Test-Cases.html (docs live at the repository root): runs
# every "Run" step of every case through tools\call.js, checks the concrete values each case's
# expected text names, and writes a results JSON whose shape mirrors the instrument's per-case
# state (steps ticks, verdict, notes, evidence) so the run can be loaded into the page through its
# own engine functions by tests\record-instrument.cjs.
#
# Usage (from mcp\):  powershell -NoProfile -ExecutionPolicy Bypass -File tests\run-instrument.ps1
# Exit 0 when no case is FAIL, 1 otherwise.
param(
    [string]$OutFile = 'docs\Testing\TpscliMcp-Unit-Test-Results.json',   # relative to the repository root
    [string[]]$Only = @()      # e.g. -Only TC-13,TC-14 (TC-01/TC-02 are not implied)
)
$ErrorActionPreference = 'Stop'
$Only = @($Only | ForEach-Object { $_ -split ',' } | Where-Object { $_ })   # -Only TC-13,TC-14 arrives as one string from powershell -File
$root = Split-Path -Parent $PSScriptRoot          # mcp\
$repo = Split-Path -Parent $root                  # repository root, where docs\ and cli\ live
$instrument = Join-Path $repo 'docs\Testing\TpscliMcp-Unit-Test-Cases.html'
$callJs = Join-Path $root 'tools\call.js'
$serverJs = Join-Path $root 'dist\server.js'
$work = Join-Path $root 'work'
$absKeys = Join-Path $work 'KEYS.TPS'
$absKeysJson = $absKeys -replace '\\', '\\'      # backslashes doubled for a JSON string
$workJson = $work -replace '\\', '\\'
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
    }
}
function Tick([int]$n) { $script:ctx.Steps[$n - 1] = $true }
function Note([string]$text) { $script:ctx.Evidence.Add($text) }
function Fail([string]$why) { $script:ctx.Fails.Add($why); Note "  ** $why" }

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
function Expect-Records($Expected) {
    $r = Call tps_describe '{"file":"KEYS.TPS"}' @('--root', 'work'); $j = Expect-Ok $r 'describe'
    if ($j) { Expect-True ($j.records -eq $Expected) "expected records $Expected, got $($j.records)" }
}

# ---- one executor per case; each Tick n marks step n of the instrument as performed ----
$run = @{
'TC-01' = {
    $r = Npm 'install'; Expect-Exit $r 0
    Expect-True (@($r.Out -split "`n" | Where-Object { $_ -match '\bERR!\b' }).Count -eq 0) 'npm install printed ERR! lines'; Tick 1
    $r = Npm 'run build'; Expect-Exit $r 0
    Expect-True (@($r.Out -split "`n" | Where-Object { $_ -match 'error TS' }).Count -eq 0) 'tsc printed errors'; Tick 2
    Note "> Test-Path dist\server.js -> $(Test-Path $serverJs)"
    Expect-True (Test-Path $serverJs) 'dist\server.js missing'; Tick 3
    $r = Npm 'ls --depth=0'
    Expect-True ($r.Out -match '@modelcontextprotocol/sdk@1\.30\.\d+') 'sdk 1.30.x not listed'
    Expect-True ($r.Out -match 'zod@3\.25\.\d+') 'zod 3.25.x not listed'
}
'TC-02' = {
    $r = Npm 'test'; Tick 1
    $lines = @($r.Out -split "`n")
    $get = { param($k) $m = $lines | Where-Object { $_ -match "^# $k (\d+)" } | Select-Object -Last 1; if ($m -match "(\d+)$") { [int]$Matches[1] } else { -1 } }
    $tests = & $get 'tests'; $pass = & $get 'pass'; $fail = & $get 'fail'; $skipped = & $get 'skipped'
    Note "> counted tests=$tests pass=$pass fail=$fail skipped=$skipped"
    Expect-True ($tests -eq 40 -and $pass -eq 40 -and $fail -eq 0 -and $skipped -eq 0) "expected 40/40/0/0"
    Expect-Exit $r 0; Tick 2
}
'TC-03' = {
    Fresh
    $r = Server @('--bogus'); Expect-StderrContains $r 'tpscli-mcp: unknown option --bogus'; Expect-Exit $r 2; Tick 1
    $r = Server @('--root', 'C:\no\such\folder'); Expect-StderrContains $r 'tpscli-mcp: --root C:\no\such\folder is not a folder'; Expect-Exit $r 2; Tick 2
    $r = Server @('--exe', 'C:\no\tpscli.exe'); Expect-StderrContains $r 'tpscli-mcp: tpscli.exe not found; tried C:\no\tpscli.exe. Pass --exe <path> or set TPSCLI_EXE.'; Expect-Exit $r 2; Tick 3
    $r = Server @('--timeout', '0'); Expect-StderrContains $r 'tpscli-mcp: --timeout needs a positive whole number of seconds, not 0'; Expect-Exit $r 2; Tick 4
    $r = Server @('--root', 'work')
    Expect-True ($r.Err -match "^tpscli-mcp 0\.2\.0 ready: exe (.+?); roots (.+?); writes disabled; owner none; timeout 60s") 'ready line missing or different'
    if ($Matches) { Expect-True ($Matches[1] -eq (Join-Path $repo 'cli\tpscli.exe')) "ready line names exe $($Matches[1])" }
    Expect-Exit $r 0; Tick 5
}
'TC-04' = {
    $r = Call tps_version '' @('--root', 'work'); $j = Json $r
    if ($j) { Expect-True ($j.server -eq '0.2.0') "server version $($j.server)"; Expect-True ($j.exe.version -eq '0.1.0') "exe version $($j.exe.version)"; Expect-True ($j.exe.ok -eq $true -and $j.exe.complete -eq $true) 'exe object not ok/complete'; Expect-True (@($j.roots).Count -eq 1 -and $j.roots[0] -eq $work) "roots $($j.roots -join ';')" }
    Expect-Exit $r 0; Tick 1
}
'TC-05' = {
    $r = Call tps_list_files '' @('--root', 'work'); $j = Json $r
    if ($j) {
        $names = @($j.files | ForEach-Object name)
        Expect-True (($names -join ',') -eq 'ALLTYPES.TPS,GROUPS.TPS,KEYS.TPS,MEMOS.TPS,NOKEY.TPS,SECRET.TPS') "files: $($names -join ',')"
        $f = $j.files[0]; Expect-True ($f.path -like "$work\*" -and $f.size -is [int64] -or $f.size -is [int32]) 'path/size shape'; Expect-True ($f.modified -match '^\d{4}-\d{2}-\d{2}T') 'modified is not ISO'
    }
    Expect-Exit $r 0; Tick 1
    $r = Call tps_list_files '{"pattern":"k*"}' @('--root', 'work'); $j = Json $r
    if ($j) { Expect-True (@($j.files).Count -eq 1 -and $j.files[0].name -eq 'KEYS.TPS') "pattern k* gave $(@($j.files | ForEach-Object name) -join ',')" }; Tick 2
    $r = Call tps_list_files ('{"directory":"' + $workJson + '"}') @(); $j = Json $r
    if ($j) { Expect-True (@($j.files).Count -eq 6) "directory listing gave $(@($j.files).Count) files" }; Expect-Exit $r 0; Tick 3
    $r = Call tps_list_files '' @(); Expect-Error $r 'INVALID_ARGUMENT' 'The server has no root folders; pass directory, or call tps_set_roots first.' | Out-Null; Tick 4
    $r = Call 'tps_set_roots,tps_list_files' ('[{"roots":["' + $workJson + '"]},{}]') @(); $j = Json $r
    if ($j) { Expect-True (@($j).Count -eq 2 -and @($j[0].roots).Count -eq 1 -and $j[0].roots[0] -eq $work -and @($j[1].files).Count -eq 6) "sequence gave $($r.Out)" }
    Expect-StderrContains $r "tpscli-mcp tps_set_roots 1 root(s): $work"; Expect-Exit $r 0; Tick 5
    $r = Call tps_set_roots '{"roots":["work"]}' @(); Expect-Error $r 'INVALID_ARGUMENT' 'roots[0] "work" must be an absolute path' | Out-Null; Tick 6
}
'TC-06' = {
    $check = { param($j)
        Expect-True ($j.records -eq 5 -and $j.encrypted -eq $false) "records $($j.records) encrypted $($j.encrypted)"
        Expect-True ($j.file -like '*mcp\work\KEYS.TPS') "file $($j.file)"
        $cols = @($j.columns | ForEach-Object { "$($_.name):$($_.type):$($_.size):$($_.places)" }) -join ' '
        Expect-True ($cols -eq 'ID:LONG:: NAME:STRING:30: CODE:STRING:4: AMOUNT:DECIMAL:9:2') "columns $cols"
        $k = $j.keys[0]; Expect-True ($k.name -eq 'PKEY' -and $k.primary -eq $true -and $k.unique -eq $true -and $k.components[0].col -eq 'ID') 'PKEY shape'
    }
    $r = Call tps_describe '{"file":"KEYS.TPS"}' @('--root', 'work'); $j = Expect-Ok $r 'describe'; if ($j) { & $check $j }; Tick 1
    $r = Call tps_describe ('{"file":"' + $absKeysJson + '"}') @(); $j = Expect-Ok $r 'describe'; if ($j) { & $check $j }; Tick 2
}
'TC-07' = {
    $r = Call tps_select '{"file":"KEYS.TPS","columns":["ID","NAME"],"where":"NAME LIKE ''b%''","order_by":"ID","limit":2}' @('--root', 'work')
    $j = Expect-Ok $r 'select'
    if ($j) { Expect-True ((@($j.columns | ForEach-Object name) -join ',') -eq 'ID,NAME') 'columns'; Expect-True ($j.row_count -eq 1 -and $j.rows[0][0] -eq 2 -and $j.rows[0][1] -eq 'baker' -and $j.truncated -eq $false) "rows $($r.Out)" }; Tick 1
    $r = Call tps_select '{"file":"KEYS.TPS","limit":2}' @('--root', 'work'); $j = Expect-Ok $r 'select'
    if ($j) { Expect-True ($j.row_count -eq 2 -and $j.truncated -eq $true) "row_count $($j.row_count) truncated $($j.truncated)" }; Tick 2
    $r = Call tps_select '{"file":"KEYS.TPS","where":"ID > 999"}' @('--root', 'work'); $j = Expect-Ok $r 'select'
    if ($j) { Expect-True (@($j.rows).Count -eq 0 -and $j.row_count -eq 0 -and $j.truncated -eq $false) 'empty result shape' }; Tick 3
}
'TC-08' = {
    $r = Call tps_select '{"file":"KEYS.TPS","limit":2,"format":"table"}' @('--root', 'work')
    $lines = @($r.Out -split "`n")
    Expect-True ($lines[0] -eq 'ID  NAME   CODE  AMOUNT') "header line '$($lines[0])'"
    Expect-True ($lines[2] -match '^ 1\s+Able\s+A\s+5$' -and $lines[3] -match '^ 2\s+baker\s+4$') 'data rows'
    Expect-True ($lines[-1] -eq '(2 rows, truncated by LIMIT)') "summary '$($lines[-1])'"
    Expect-True (-not $r.Out.Contains('{')) 'JSON present in table output'; Expect-Exit $r 0; Tick 1
    $r = Call tps_select '{"file":"KEYS.TPS","where":"ZZ = 1","format":"table"}' @('--root', 'work')
    Expect-True ($r.Out -eq 'UNKNOWN_COLUMN: Unknown column ZZ; valid columns: ID, NAME, CODE, AMOUNT') "table failure output '$($r.Out)'"; Expect-Exit $r 1; Tick 2
}
'TC-09' = {
    $r = Call tps_describe '{"file":"SECRET.TPS"}' @('--root', 'work')
    Expect-Error $r 'OWNER_REQUIRED' 'Not a plain TopSpeed file; if it is encrypted pass --owner' | Out-Null; Tick 1
    $r2 = Call tps_describe '{"file":"SECRET.TPS","owner":"s3cret"}' @('--root', 'work'); $j = Expect-Ok $r2 'describe'
    if ($j) { Expect-True ($j.records -eq 2 -and $j.encrypted -eq $true) 'records/encrypted (per call)' }; Tick 2
    $r3 = Call tps_describe '{"file":"SECRET.TPS"}' @('--root', 'work', '--owner', 's3cret'); $j = Expect-Ok $r3 'describe'
    if ($j) { Expect-True ($j.records -eq 2) 'records (server flag)' }; Tick 3
    Note "> (CP-4) `$env:TPSCLI_OWNER = 's3cret'  (applied to the next call's environment)"; Tick 4
    $r5 = Call tps_describe '{"file":"SECRET.TPS"}' @('--root', 'work') @{ TPSCLI_OWNER = 's3cret' }; $j = Expect-Ok $r5 'describe'
    if ($j) { Expect-True ($j.records -eq 2) 'records (environment)' }
    Expect-StderrContains $r5 'owner set'; Tick 5
    Note '> (CP-4) Remove-Item Env:TPSCLI_OWNER'; Tick 6
    $r7 = Call tps_describe '{"file":"SECRET.TPS"}' @('--root', 'work', '--owner', 'wrong')
    Expect-Error $r7 'OWNER_WRONG' 'Owner string does not decrypt this file' | Out-Null
    Expect-StderrContains $r7 'owner set'; Expect-CallLine $r7 'tps_describe' 2
    $all = $r7.Out + $r7.Err
    Note "> `$out -cmatch 'wrong' -> $($all -cmatch 'wrong')"
    Expect-True (-not ($all -cmatch 'wrong')) 'the owner value "wrong" appears in the output'
    foreach ($x in @($r2, $r3, $r5)) { Expect-True (-not (($x.Out + $x.Err) -cmatch 's3cret')) 'the owner value s3cret appears in an output' }
    Note '> s3cret searched for in the outputs of steps 2, 3 and 5: absent'; Tick 7
}
'TC-10' = {
    $r = Call tps_describe '{"file":"NOPE.TPS"}' @('--root', 'work')
    Expect-Error $r 'FILE_NOT_FOUND' "NOPE.TPS not found inside $work" | Out-Null; Expect-NoCallLine $r 'tps_describe'; Tick 1
    $r = Call tps_describe '{"file":"..\\package.json"}' @('--root', 'work')
    Expect-Error $r 'FILE_NOT_FOUND' "..\package.json not found inside $work" | Out-Null; Expect-NoCallLine $r 'tps_describe'; Tick 2
    $r = Call tps_describe '{"file":"KEYS.TPS"}' @()
    Expect-Error $r 'FILE_NOT_FOUND' 'KEYS.TPS is not an absolute path and the server currently has no root folders; call tps_set_roots or pass an absolute path' | Out-Null; Expect-NoCallLine $r 'tps_describe'; Tick 3
    $r = Call tps_describe '{"file":"\\data\\KEYS.TPS"}' @()
    Expect-Error $r 'FILE_NOT_FOUND' '\data\KEYS.TPS is not an absolute path and the server currently has no root folders; call tps_set_roots or pass an absolute path' | Out-Null; Expect-NoCallLine $r 'tps_describe'; Tick 4
}
'TC-11' = {
    Fresh
    $msg = 'This server was started without --allow-writes, so INSERT, UPDATE and DELETE are refused. Restart it with --allow-writes to enable them.'
    $r = Call tps_insert '{"file":"KEYS.TPS","values":{"ID":9,"NAME":"nine"}}' @('--root', 'work')
    Expect-Error $r 'WRITES_DISABLED' $msg 'insert' 'none' | Out-Null; Expect-NoCallLine $r 'tps_insert'; Tick 1
    $r = Call tps_update '{"file":"KEYS.TPS","set":{"NAME":"x"},"where":"ID = 1"}' @('--root', 'work')
    Expect-Error $r 'WRITES_DISABLED' $msg 'update' 'none' | Out-Null; Expect-NoCallLine $r 'tps_update'; Tick 2
    $r = Call tps_delete '{"file":"KEYS.TPS","where":"ID = 1"}' @('--root', 'work')
    Expect-Error $r 'WRITES_DISABLED' $msg 'delete' 'none' | Out-Null; Expect-NoCallLine $r 'tps_delete'; Tick 3
    Expect-Records 5; Tick 4
}
'TC-12' = {
    Fresh
    $del = '{"sql":"DELETE FROM [' + $absKeysJson + '] WHERE ID = 1"'
    $r = Call tps_query ($del + '}') @('--root', 'work'); Expect-Error $r 'WRITES_DISABLED' $null 'delete' 'none' | Out-Null; Tick 1
    $r = Call tps_query ($del + ',"parse_only":true}') @('--root', 'work'); $j = Expect-Ok $r 'delete'
    if ($j) { Expect-True ($j.parse_only -eq $true) 'parse_only true missing' }; Tick 2
    $r = Call tps_query ('{"sql":"UPDATE [' + $absKeysJson + '] SET NAME = ''x'' WHERE ID = 1","format":"table"}') @('--root', 'work', '--allow-writes')
    Expect-Error $r 'INVALID_ARGUMENT' 'format "table" is not available for a write: the grid drops the outcome field' 'update' 'none' | Out-Null; Tick 3
    $r = Call tps_query ('{"sql":"SELECT ID FROM [' + $absKeysJson + ']","limit_default":2}') @('--root', 'work'); $j = Expect-Ok $r 'select'
    if ($j) { Expect-True ($j.row_count -eq 2 -and $j.truncated -eq $true) 'limit_default cap' }; Tick 4
    Expect-Records 5; Tick 5
}
'TC-13' = {
    Fresh
    $rw = @('--root', 'work', '--allow-writes')
    $r = Call tps_insert '{"file":"KEYS.TPS","values":{"ID":9,"NAME":"O''Nine","CODE":"N"}}' $rw; $j = Expect-Ok $r 'insert'
    if ($j) { Expect-True ($j.affected -eq 1) "affected $($j.affected)" }; Tick 1
    $r = Call tps_update '{"file":"KEYS.TPS","set":{"NAME":"12\" pizza\\"},"where":"ID = 9"}' $rw; $j = Expect-Ok $r 'update'
    if ($j) { Expect-True ($j.matched -eq 1 -and $j.affected -eq 1) "matched $($j.matched) affected $($j.affected)" }; Tick 2
    $r = Call tps_select '{"file":"KEYS.TPS","columns":["NAME"],"where":"ID = 9"}' $rw; $j = Expect-Ok $r 'select'
    if ($j) { Expect-True ($j.rows[0][0] -ceq '12" pizza\') "read back '$($j.rows[0][0])'" }; Tick 3
    $r = Call tps_delete '{"file":"KEYS.TPS","where":"ID = 9"}' $rw; $j = Expect-Ok $r 'delete'
    if ($j) { Expect-True ($j.matched -eq 1 -and $j.affected -eq 1) 'delete counts' }; Tick 4
    $r = Call tps_select '{"file":"KEYS.TPS","where":"ID = 9"}' @('--root', 'work'); $j = Expect-Ok $r 'select'
    if ($j) { Expect-True ($j.row_count -eq 0) 'row 9 still present' }; Tick 5
}
'TC-14' = {
    Fresh
    $rw = @('--root', 'work', '--allow-writes')
    $r = Call tps_update '{"file":"KEYS.TPS","set":{},"where":"ID = 1"}' $rw
    Expect-Error $r 'INVALID_ARGUMENT' 'set must name at least one column' 'update' 'none' | Out-Null; Expect-NoCallLine $r 'tps_update'; Tick 1
    $r = Call tps_insert '{"file":"KEYS.TPS","values":{"ID":9,"NAME":null}}' $rw
    Expect-Error $r 'INVALID_ARGUMENT' 'NAME: null is not a value (TopSpeed has no NULL); omit the column instead' 'insert' 'none' | Out-Null; Expect-NoCallLine $r 'tps_insert'; Tick 2
    $r = Call tps_update '{"file":"KEYS.TPS","set":{"NAME":"x"}}' $rw
    Expect-True ($r.Out -eq 'MCP error -32602: Input validation error: Invalid arguments for tool tps_update: Required at where') "SDK line '$($r.Out)'"; Expect-Exit $r 1; Tick 3
    $r = Call tps_select '{"file":"KEYS.TPS","offset":1}' $rw
    Expect-Error $r 'INVALID_ARGUMENT' 'offset requires limit; pass limit: 0 for no cap' 'select' | Out-Null; Expect-NoCallLine $r 'tps_select'; Tick 4
    $r = Call tps_select '{"file":"KEYS.TPS","columns":["ID; DROP"]}' $rw
    Expect-Error $r 'INVALID_ARGUMENT' '"ID; DROP" is not an identifier path such as ID, ADDR.CITY or QTY[3]' 'select' | Out-Null; Expect-NoCallLine $r 'tps_select'; Tick 5
    Expect-Records 5; Tick 6
}
'TC-15' = {
    Fresh
    $rw = @('--root', 'work', '--allow-writes')
    $r = Call tps_insert '{"file":"KEYS.TPS","values":{"ID":1,"NAME":"dup"}}' $rw
    $j = Expect-Error $r 'DUPLICATE_KEY' 'Duplicate value for key PKEY' 'insert' 'none'
    if ($j) { Expect-True ($j.error.key -eq 'PKEY') 'error.key' }; Expect-CallLine $r 'tps_insert' 3; Tick 1
    $r = Call tps_query ('{"sql":"UPDATE [' + $absKeysJson + '] SET NAME = ''x''"}') $rw
    Expect-Error $r 'WHERE_REQUIRED' 'UPDATE without WHERE is refused. Use WHERE 1 = 1 to update every row.' 'update' 'none' | Out-Null; Expect-CallLine $r 'tps_query' 1; Tick 2
    $r = Call tps_select '{"file":"KEYS.TPS","where":"ZZ = 1"}' @('--root', 'work')
    $j = Expect-Error $r 'UNKNOWN_COLUMN' 'Unknown column ZZ; valid columns: ID, NAME, CODE, AMOUNT' 'select'
    if ($j) { Expect-True ($j.error.column -eq 'ZZ') 'error.column' }; Tick 3
    Expect-Records 5
    $r = Call tps_select '{"file":"KEYS.TPS","columns":["NAME"],"where":"ID = 1"}' @('--root', 'work'); $j = Expect-Ok $r 'select'
    if ($j) { Expect-True ($j.rows[0][0] -eq 'Able') 'NAME of ID 1 changed' }; Tick 4
}
'TC-16' = {
    $r = Call tps_query '{"sql":"SELECT ID FROM [KEYS.TPS]"}' @('--root', 'work')
    Expect-Error $r 'FILE_NOT_FOUND' 'File not found: KEYS.TPS' 'select' | Out-Null; Expect-CallLine $r 'tps_query' 2; Tick 1
    $r = Call tps_query ('{"sql":"SELECT ID, NAME FROM [' + $absKeysJson + '] WHERE ID < 3 ORDER BY ID"}') @('--root', 'work'); $j = Expect-Ok $r 'select'
    if ($j) { Expect-True ($j.row_count -eq 2 -and $j.rows[0][1] -eq 'Able' -and $j.rows[1][1] -eq 'baker') 'rows' }; Tick 2
    $abs = (Join-Path $work 'NOKEY.TPS') -replace '\\', '\\'
    $r = Call tps_query ('{"sql":"DESCRIBE [' + $abs + ']","format":"table"}') @('--root', 'work')
    Expect-Contains $r '"op": "describe"'; Expect-Exit $r 0; Tick 3
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
    $verdict = if ($script:ctx.Fails.Count) { 'FAIL' } else { 'PASS' }
    $notes = if ($verdict -eq 'PASS') { "Automated run $($started.ToString('yyyy-MM-dd HH:mm')): every check passed." } else { ($script:ctx.Fails -join "`n") }
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
    suite = 'tpscli-mcp-0-2-0'; storage_key = $suite.storageKey
    build = (git -C $root rev-parse --short HEAD); ref = (git -C $root rev-parse --abbrev-ref HEAD)
    env = "$env:COMPUTERNAME / $([Environment]::OSVersion.VersionString) / PowerShell $($PSVersionTable.PSVersion) / node $(& $node --version)"
    started = $started.ToString('s'); finished = (Get-Date).ToString('s'); tally = $tally; cases = $results
}
$json = ($doc | ConvertTo-Json -Depth 6) -replace "(?<!`r)`n", "`r`n"
[IO.File]::WriteAllText((Join-Path $repo $OutFile), $json + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
Write-Host ''
Write-Host "run-instrument.ps1: PASS $($tally.PASS) FAIL $($tally.FAIL) BLOCKED $($tally.BLOCKED) -> $OutFile"
if ($tally.FAIL -gt 0) { exit 1 } else { exit 0 }
