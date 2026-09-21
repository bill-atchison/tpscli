# tpscli release qualification - the six checks of spec section 7, as one script.
#
# Every verdict below comes from this script's own comparisons. The exe's exit code is one
# input among several, never the verdict on its own.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File verify.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File verify.ps1 -Extra C:\tps\dtpos `
#              -Expected C:\tps\dtpos-expected -TpsFixLog C:\tps\tpsfix-2026-09-18.log
#
# -Extra is a folder of real-world .TPS files (the dtpos test-store copies; never committed).
# When it is given, -TpsFixLog is REQUIRED: TPSFix has no verified command-line interface, so
# the manual TPSFix run over those same files is a checked input rather than a reminder.
# -Expected is a folder of oracle-format JSON (one <NAME>.json per file) produced from the
# dictionary-declared FILE structures, compared exactly as tests\describe.ps1 does.

param(
    [string]$Corpus = 'testdata',
    [string]$Extra = '',
    [string]$Expected = '',
    [string]$TpsFixLog = ''
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$exe = Join-Path $root 'tpscli.exe'
$holdExe = Join-Path $root 'tests\hold.exe'
. (Join-Path $root 'tests\TestHelpers.ps1')

$timeoutMs = 60000
$failures = 0
$skips = 0
$notes = New-Object System.Collections.ArrayList

# testdata\SECRET.TPS is the corpus's encrypted file; its owner string is baked into
# testdata\gen\mkcorpus.clw and repeated in tests\describe.ps1. Files under -Extra are plain.
$owners = @{ 'SECRET' = 's3cret' }

function Step-Pass([string]$name, [string]$detail) {
    Write-Host ("PASS  {0}{1}" -f $name, $(if ($detail) { " - $detail" } else { '' }))
}

function Step-Fail([string]$name, [string]$detail) {
    Write-Host ("FAIL  {0} - {1}" -f $name, $detail)
    $script:failures++
}

# A step that did not run is a SKIP, never a PASS. Spec section 7 makes this script the release
# gate over the dtpos corpus, and a default run (no -Extra/-Expected/-TpsFixLog) exercises
# neither the real files nor the dictionary parity nor the TPSFix report. Printing PASS for
# those made a run that covers four of the six checks read as a full release qualification.
function Step-Skip([string]$name, [string]$detail) {
    Write-Host ("SKIP  {0}{1}" -f $name, $(if ($detail) { " - $detail" } else { '' }))
    $script:skips++
}

function Note([string]$text) {
    Write-Host ("note  {0}" -f $text)
    $null = $script:notes.Add($text)
}

# ---- one bounded tpscli run, with its stdout parsed as the response object ----

function Invoke-Tps {
    param([string]$Sql, [string]$Owner = '', [string[]]$Options = @())
    $argList = @()
    if ($Owner) { $argList += @('--owner', $Owner) }
    $argList += $Options
    $argList += $Sql
    $r = Invoke-Tpscli_Bounded -FilePath $script:exe -ArgumentList $argList `
                               -WorkingDirectory $script:root -TimeoutMs $script:timeoutMs
    $raw = "$($r.StdOut)$($r.StdErr)"
    $obj = $null
    if (-not $r.TimedOut) { try { $obj = $raw | ConvertFrom-Json } catch { $obj = $null } }
    [pscustomobject]@{
        Sql       = $Sql
        TimedOut  = $r.TimedOut
        ExitCode  = $r.ExitCode
        Raw       = $raw.Trim()
        Json      = $obj
        ElapsedMs = $r.ElapsedMs
    }
}

# A run whose stdout only has to parse as JSON. --dump-schema is the hidden oracle dump; it
# carries file/fields/memos/keys and deliberately does NOT follow the ok/complete response
# contract, so it cannot go through Invoke-TpsOk.
function Invoke-TpsJson {
    param([string]$name, [string]$Sql, [string]$Owner = '', [string[]]$Options = @())
    $r = Invoke-Tps -Sql $Sql -Owner $Owner -Options $Options
    if ($r.TimedOut) { Step-Fail $name "timed out after ${script:timeoutMs}ms: $Sql"; return $null }
    if ($null -eq $r.Json) { Step-Fail $name "no JSON response to '$Sql': $($r.Raw)"; return $null }
    return $r.Json
}

# A run that is required to have succeeded: returns the parsed object, or $null after
# recording the failure against $name.
function Invoke-TpsOk {
    param([string]$name, [string]$Sql, [string]$Owner = '', [string[]]$Options = @())
    $r = Invoke-Tps -Sql $Sql -Owner $Owner -Options $Options
    if ($r.TimedOut) { Step-Fail $name "timed out after ${script:timeoutMs}ms: $Sql"; return $null }
    if ($null -eq $r.Json) { Step-Fail $name "no JSON response to '$Sql': $($r.Raw)"; return $null }
    if (-not $r.Json.ok) { Step-Fail $name "'$Sql' failed: $($r.Raw)"; return $null }
    if ($r.Json.complete -ne $true) { Step-Fail $name "response to '$Sql' is not complete: $($r.Raw)"; return $null }
    return $r.Json
}

# ---- SQL literal helpers ----

function Quote-Sql([string]$s) { "'" + ($s -replace "'", "''") + "'" }

function Test-NumericType([string]$t) {
    @('BYTE','SHORT','USHORT','LONG','ULONG','SREAL','REAL','DECIMAL','DATE','TIME') -contains $t.ToUpper()
}

# DECIMAL output trims trailing fraction zeros (a DECIMAL(7,2) holding 1.50 prints "1.5";
# with 0 places it prints "2"), so the expected text is the formatted value with those zeros
# and any bare trailing point removed. See README, "Deviations".
function Format-DecimalExpectation([decimal]$v, [int]$places) {
    $s = $v.ToString("F$places", [cultureinfo]::InvariantCulture)
    if ($s.Contains('.')) { $s = $s.TrimEnd('0').TrimEnd('.') }
    if ($s -eq '' -or $s -eq '-') { $s = '0' }
    return $s
}

# ---- schema reading ----

# The definition's flat field list, in order; a GROUP's "fields" count says how many of the
# entries that follow belong to it, at every nesting level. Walking it that way reproduces
# exactly the dotted paths DESCRIBE prints, and every entry stays addressed by its field
# ordinal. Nothing here matches on a label: two leaves in different groups can legitimately
# share a bare name (ADDR.CITY and SHIP.CITY), and a label-keyed join would collapse them and
# attribute one leaf's "over" or "picture" to the other.
function Expand-DumpFields {
    param($fields, [int]$start, [int]$count, [string]$prefix, [bool]$inDimGroup, $acc, $pathByNbr)
    $i = $start
    $end = $start + $count - 1
    while ($i -le $end) {
        $c = $fields[$i]
        $bare = (("$($c.label)") -split ':')[-1]
        $name = "$prefix$bare"
        $dim = [int]$c.dim; if ($dim -lt 1) { $dim = 1 }
        $members = [int]$c.fields
        $pathByNbr[[int]$c.nbr] = $name
        if ("$($c.type)" -eq 'GROUP') {
            # DESCRIBE names a dimmed group's members without a subscript, and every leaf under
            # one is unassignable, so the flag propagates down.
            Expand-DumpFields -fields $fields -start ($i + 1) -count $members -prefix "$name." `
                              -inDimGroup ($inDimGroup -or $dim -gt 1) -acc $acc -pathByNbr $pathByNbr
            $i += 1 + $members
            continue
        }
        $picture = "$($c.picture)"
        $skip = ''
        if ($inDimGroup) { $skip = "leaf inside a DIM'd GROUP" }
        elseif ([int]$c.over -ne 0) { $skip = 'OVER side of an overlay pair' }
        elseif ($picture -ne '') { $skip = "STRING with picture @$picture" }
        $names = @()
        if ($dim -gt 1) { 1..$dim | ForEach-Object { $names += "$name[$_]" } } else { $names = @($name) }
        foreach ($n in $names) {
            $null = $acc.Add([pscustomobject]@{
                Name    = $n
                Nbr     = [int]$c.nbr
                Type    = "$($c.type)"
                Size    = [int]$c.size
                Places  = [int]$c.places
                Picture = $picture
                IsMemo  = $false
                Skip    = $skip
            })
        }
        $i += 1
    }
}

# One schema read per file. --dump-schema is the only output that carries the overlay target,
# the picture and the KEY/INDEX distinction, all three of which decide what this script may
# write and what it must expect.
function Get-Schema {
    param([string]$name, [string]$tps, [string]$owner)
    $d = Invoke-TpsJson -name $name -Sql "DESCRIBE [$tps]" -Owner $owner -Options @('--dump-schema')
    if ($null -eq $d) { return $null }

    $fields = @($d.fields)
    $leaves = New-Object System.Collections.ArrayList
    $pathByNbr = @{}
    Expand-DumpFields -fields $fields -start 0 -count $fields.Count -prefix '' `
                      -inDimGroup $false -acc $leaves -pathByNbr $pathByNbr

    foreach ($m in @($d.memos)) {
        $null = $leaves.Add([pscustomobject]@{
            Name    = (("$($m.label)") -split ':')[-1]
            Nbr     = 0
            Type    = $(if ("$($m.type)" -eq 'B') { 'BLOB' } else { 'MEMO' })
            Size    = [int]$m.size
            Places  = 0
            Picture = ''
            IsMemo  = $true
            Skip    = ''
        })
    }

    $keys = @()
    foreach ($k in @($d.keys)) {
        $comps = @()
        $unresolved = @()
        foreach ($c in @($k.components)) {
            $p = $pathByNbr[[int]$c.nbr]
            if ($null -eq $p) { $unresolved += "field $($c.nbr)" } else { $comps += $p }
        }
        $keys += [pscustomobject]@{
            Name       = (("$($k.label)") -split ':')[-1]
            IsKey      = ("$($k.type)" -eq 'K')       # 'I' is an INDEX
            Unique     = ([int]$k.dup -eq 0)
            Primary    = ([int]$k.primary -eq 1)
            Opt        = ([int]$k.opt -eq 1)
            Components = $comps
            Unresolved = $unresolved
        }
    }

    [pscustomobject]@{ Leaves = @($leaves); Keys = $keys }
}

# The literal written to a non-key leaf, and the text that literal must read back as.
function Get-LeafValue {
    param($leaf, [int]$pass)
    $t = $leaf.Type.ToUpper()
    switch -Regex ($t) {
        '^(BYTE|SHORT|USHORT|LONG|ULONG|SREAL|REAL)$' {
            $n = 6 + $pass
            return [pscustomobject]@{ Literal = "$n"; Expected = "$n" }
        }
        '^DECIMAL$' {
            # 1.5 (pass 1) / 2.5 (pass 2) rounded to the column's places; a column with no room
            # for an integer digit gets 0 instead of overflowing.
            $v = [decimal](0.5 + $pass)
            if ($leaf.Size - $leaf.Places -lt 1) { $v = [decimal]0 }
            $v = [Math]::Round($v, $leaf.Places, [MidpointRounding]::AwayFromZero)
            $lit = $v.ToString([cultureinfo]::InvariantCulture)
            return [pscustomobject]@{ Literal = $lit; Expected = (Format-DecimalExpectation $v $leaf.Places) }
        }
        '^DATE$' {
            $d = @('2026-01-02','2026-03-04')[$pass - 1]
            return [pscustomobject]@{ Literal = (Quote-Sql $d); Expected = $d }
        }
        '^TIME$' {
            $tm = @('01:02:03','05:06:07')[$pass - 1]
            return [pscustomobject]@{ Literal = (Quote-Sql $tm); Expected = "$tm.00" }
        }
        '^BLOB$' {
            $b = @('AQID','AgQG')[$pass - 1]
            return [pscustomobject]@{ Literal = (Quote-Sql $b); Expected = $b }
        }
        '^MEMO$' {
            $m = @('memo','memo2')[$pass - 1]
            return [pscustomobject]@{ Literal = (Quote-Sql $m); Expected = $m }
        }
        default {
            $ch = @('r','s')[$pass - 1]
            $w = [Math]::Max(1, [Math]::Min($leaf.Size, 3))
            $s = $ch * $w
            return [pscustomobject]@{ Literal = (Quote-Sql $s); Expected = $s }
        }
    }
}

# The value written to a key component: proven absent from the file, not merely type-correct.
# Numbers are the column's current maximum plus 1 (pass 1) or 2 (pass 2); strings are a run of
# '~' or '}'. Whether it really is absent is proved by a SELECT further down, never assumed.
function Get-KeyValue {
    param($leaf, [int]$pass, [decimal]$max)
    $t = $leaf.Type.ToUpper()
    switch -Regex ($t) {
        '^DATE$' {
            $d = @('2099-12-30','2099-12-31')[$pass - 1]
            return [pscustomobject]@{ Literal = (Quote-Sql $d); Expected = $d }
        }
        '^TIME$' {
            $tm = @('23:59:58','23:59:59')[$pass - 1]
            return [pscustomobject]@{ Literal = (Quote-Sql $tm); Expected = "$tm.00" }
        }
        '^DECIMAL$' {
            $v = [Math]::Round($max + $pass, $leaf.Places, [MidpointRounding]::AwayFromZero)
            return [pscustomobject]@{ Literal = $v.ToString([cultureinfo]::InvariantCulture)
                                      Expected = (Format-DecimalExpectation $v $leaf.Places) }
        }
        '^(BYTE|SHORT|USHORT|LONG|ULONG|SREAL|REAL)$' {
            $n = [long]$max + $pass
            return [pscustomobject]@{ Literal = "$n"; Expected = "$n" }
        }
        default {
            $ch = @('~','}')[$pass - 1]
            $w = [Math]::Max(1, [Math]::Min($leaf.Size, 8))
            $s = $ch * $w
            return [pscustomobject]@{ Literal = (Quote-Sql $s); Expected = $s }
        }
    }
}

function Get-ColumnMax {
    param([string]$tps, [string]$owner, [string]$col)
    $r = Invoke-Tps -Sql "SELECT $col FROM [$tps] ORDER BY $col DESC LIMIT 1" -Owner $owner
    if ($null -eq $r.Json -or -not $r.Json.ok) { return $null }
    $rows = @($r.Json.rows)
    if ($rows.Count -eq 0) { return [decimal]0 }
    return [decimal]("$(@($rows[0])[0])")
}

# ================================================================================
# Step 1 - build every project, regenerate the corpus
# ================================================================================

function Step1-Build {
    $name = 'step 1 build + corpus'
    $projects = @('tpscli.cwproj', 'testdata\gen\mkcorpus.cwproj', 'tests\hold.cwproj')
    Push-Location $root
    try {
        foreach ($p in $projects) {
            $exePath = Join-Path $root ([IO.Path]::ChangeExtension($p, '.exe'))
            $before = if (Test-Path $exePath) { (Get-Item $exePath).LastWriteTimeUtc } else { [datetime]::MinValue }
            $out = ''
            try {
                $out = & (Join-Path $root 'tools\build.ps1') -Proj $p 2>&1 | Out-String
            } catch {
                Step-Fail $name "$p did not build: $_"
                return
            }
            # Build success is the exe's timestamp advancing with zero error lines, not the
            # exit code alone (see CLAUDE.md).
            $errLines = @($out -split "`r?`n" | Where-Object { $_ -match '\berror\b' -and $_ -notmatch '\bwarning\b' })
            if ($errLines.Count -gt 0) {
                Step-Fail $name "$p reported errors: $($errLines[0])"
                return
            }
            if (-not (Test-Path $exePath)) { Step-Fail $name "$p produced no $exePath"; return }
            if ((Get-Item $exePath).LastWriteTimeUtc -le $before) {
                Step-Fail $name "$p rebuilt but $exePath timestamp did not advance"
                return
            }
        }
    } finally {
        Pop-Location
    }

    # mkcorpus writes testdata\*.TPS and testdata\expected\*.json through relative NAME()
    # attributes, so it must run with the repository root as its working directory.
    $mk = Invoke-Tpscli_Bounded -FilePath (Join-Path $root 'testdata\gen\mkcorpus.exe') `
                                -ArgumentList @() -WorkingDirectory $root -TimeoutMs $timeoutMs
    if ($mk.TimedOut) { Step-Fail $name "mkcorpus.exe timed out"; return }
    if ($mk.ExitCode -ne 0) { Step-Fail $name "mkcorpus.exe exited $($mk.ExitCode): $($mk.StdOut)$($mk.StdErr)"; return }
    foreach ($f in @('ALLTYPES','GROUPS','KEYS','MEMOS','NOKEY','SECRET')) {
        if (-not (Test-Path (Join-Path $root "$Corpus\$f.TPS"))) {
            Step-Fail $name "mkcorpus.exe left no $Corpus\$f.TPS"; return
        }
    }
    Step-Pass $name "3 projects rebuilt, corpus regenerated"
}

# ================================================================================
# Step 2 - the per-task test scripts
# ================================================================================

function Step2-Tests {
    foreach ($t in @('describe','parser','select','insert','update','readonly')) {
        $name = "step 2 tests\$t.ps1"
        $script = Join-Path $root "tests\$t.ps1"
        if (-not (Test-Path $script)) { Step-Fail $name 'script is missing'; continue }
        # A failing test script writes to stderr, and '2>&1 | Out-String' under
        # ErrorActionPreference Stop turns that into a terminating NativeCommandError. Without
        # this catch the FAIL line below would be replaced by an exception and steps 3-7 would
        # never run, exactly when a test has failed.
        $out = ''
        $code = 0
        try {
            $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $script 2>&1 | Out-String
            $code = $LASTEXITCODE
        } catch {
            $out = "$_"
            $code = if ($LASTEXITCODE) { $LASTEXITCODE } else { 1 }
        }
        if ($code -ne 0) {
            Step-Fail $name "exit $code`n$($out.Trim())"
        } else {
            Step-Pass $name 'exit 0'
        }
    }
}

# ================================================================================
# Step 3 - round trip: DESCRIBE, INSERT, SELECT, UPDATE, SELECT, DELETE, DESCRIBE
# ================================================================================

function Invoke-RoundTrip {
    param([string]$label, [string]$tps, [string]$owner)
    $name = "step 3 round trip $label"

    $d0 = Invoke-TpsOk -name $name -Sql "DESCRIBE [$tps]" -Owner $owner
    if ($null -eq $d0) { return }
    $records0 = [int]$d0.records

    $sch = Get-Schema -name $name -tps $tps -owner $owner
    if ($null -eq $sch) { return }

    $leaves = $sch.Leaves
    foreach ($s in @($leaves | Where-Object { $_.Skip -ne '' })) {
        Note "$label : $($s.Name) not written ($($s.Skip))"
    }
    $writable = @($leaves | Where-Object { $_.Skip -eq '' })
    if ($writable.Count -eq 0) { Step-Fail $name 'no writable leaf'; return }

    $byName = @{}
    foreach ($l in $leaves) { $byName[$l.Name.ToUpper()] = $l }

    # The unique keys decide which columns need proven-absent values, and which of them
    # addresses the inserted row in every later WHERE. A unique key this script cannot write
    # is a FAIL, not a skip: the brief allows exactly one skip reason (a candidate row that
    # would still collide), and silently covering nothing is the failure mode a release gate
    # exists to prevent.
    $uniqueKeys = @($sch.Keys | Where-Object { $_.Unique })
    $keyCols = New-Object System.Collections.ArrayList
    foreach ($k in $uniqueKeys) {
        if ($k.Unresolved.Count -gt 0) {
            Step-Fail $name "unique key $($k.Name) has a component this script cannot address ($($k.Unresolved -join ', '))"
            return
        }
        foreach ($c in $k.Components) {
            $l = $byName[$c.ToUpper()]
            if ($null -eq $l) {
                Step-Fail $name "unique key $($k.Name) component $c is not a leaf in the schema"
                return
            }
            if ($l.Skip -ne '') {
                Step-Fail $name "unique key $($k.Name) component $c is not writable ($($l.Skip)), so this file cannot be round-tripped"
                return
            }
            if (-not ($keyCols | Where-Object { $_.Name -eq $l.Name })) { $null = $keyCols.Add($l) }
        }
    }

    # No unique key at all (NOKEY.TPS): the row is addressed by every value inserted into it.
    $addressing = @()
    if ($uniqueKeys.Count -gt 0) {
        $pk = @($uniqueKeys | Where-Object { $_.Primary })
        $addrKey = if ($pk.Count -gt 0) { $pk[0] } else { $uniqueKeys[0] }
        $addressing = @($addrKey.Components | ForEach-Object { $byName[$_.ToUpper()] })
    } else {
        $addressing = @($writable | Where-Object { -not $_.IsMemo })
        foreach ($l in $addressing) { if (-not ($keyCols | Where-Object { $_.Name -eq $l.Name })) { $null = $keyCols.Add($l) } }
    }
    if ($addressing.Count -eq 0) { Step-Fail $name 'no column can address the inserted row'; return }

    # Values: key columns get a proven-absent value, everything else a type-derived literal.
    $v1 = @{}; $v2 = @{}
    foreach ($l in $writable) {
        if ($keyCols | Where-Object { $_.Name -eq $l.Name }) {
            $max = [decimal]0
            if (Test-NumericType $l.Type) {
                $m = Get-ColumnMax -tps $tps -owner $owner -col $l.Name
                if ($null -eq $m) { Step-Fail $name "could not read the maximum of $($l.Name)"; return }
                $max = $m
            }
            $v1[$l.Name] = Get-KeyValue -leaf $l -pass 1 -max $max
            $v2[$l.Name] = Get-KeyValue -leaf $l -pass 2 -max $max
        } else {
            $v1[$l.Name] = Get-LeafValue -leaf $l -pass 1
            $v2[$l.Name] = Get-LeafValue -leaf $l -pass 2
        }
    }

    # Prove absence: for every unique key (or, with no key, the whole inserted row) both
    # value sets must match zero existing rows. A collision is the one reason to skip a file.
    $absenceSets = @()
    if ($uniqueKeys.Count -gt 0) {
        foreach ($k in $uniqueKeys) {
            $absenceSets += ,@($k.Components | ForEach-Object { $byName[$_.ToUpper()] })
        }
    } else {
        $absenceSets += ,$addressing
    }
    foreach ($vals in @($v1, $v2)) {
        foreach ($set in $absenceSets) {
            $w = (@($set | ForEach-Object { "$($_.Name) = $($vals[$_.Name].Literal)" }) -join ' AND ')
            $r = Invoke-TpsOk -name $name -Sql "SELECT $($set[0].Name) FROM [$tps] WHERE $w" -Owner $owner
            if ($null -eq $r) { return }
            if ([int]$r.row_count -ne 0) {
                Note "$label : candidate row ($w) already exists; file skipped"
                return
            }
        }
    }

    $cols = (@($writable | ForEach-Object { $_.Name }) -join ', ')
    $vals1 = (@($writable | ForEach-Object { $v1[$_.Name].Literal }) -join ', ')
    $ins = Invoke-TpsOk -name $name -Sql "INSERT INTO [$tps] ($cols) VALUES ($vals1)" -Owner $owner
    if ($null -eq $ins) { return }
    if ([int]$ins.affected -ne 1) { Step-Fail $name "INSERT affected $($ins.affected), expected 1"; return }

    $where1 = (@($addressing | ForEach-Object { "$($_.Name) = $($v1[$_.Name].Literal)" }) -join ' AND ')
    if (-not (Compare-RoundTripRow -name $name -tps $tps -owner $owner `
                                   -where $where1 -values $v1 -writable $writable -phase 'after INSERT')) { return }

    $sets = (@($writable | ForEach-Object { "$($_.Name) = $($v2[$_.Name].Literal)" }) -join ', ')
    $upd = Invoke-TpsOk -name $name -Sql "UPDATE [$tps] SET $sets WHERE $where1" -Owner $owner
    if ($null -eq $upd) { return }
    if ([int]$upd.affected -ne 1) { Step-Fail $name "UPDATE affected $($upd.affected), expected 1"; return }

    $where2 = (@($addressing | ForEach-Object { "$($_.Name) = $($v2[$_.Name].Literal)" }) -join ' AND ')
    if (-not (Compare-RoundTripRow -name $name -tps $tps -owner $owner `
                                   -where $where2 -values $v2 -writable $writable -phase 'after UPDATE')) { return }

    $del = Invoke-TpsOk -name $name -Sql "DELETE FROM [$tps] WHERE $where2" -Owner $owner
    if ($null -eq $del) { return }
    if ([int]$del.affected -ne 1) { Step-Fail $name "DELETE affected $($del.affected), expected 1"; return }

    # A picture STRING is left out of the round trip above because the runtime deformats and
    # reformats it, so no literal survives unchanged. That exclusion must not hide the defect
    # class it came from, so assert the exe refuses a literal the picture cannot read instead
    # of storing the picture's zero. A regression here also shows up in the record count below,
    # because an accepted INSERT would leave a row behind.
    foreach ($p in @($leaves | Where-Object { $_.Picture -ne '' -and $_.Skip -like 'STRING with picture*' })) {
        $r = Invoke-Tps -Sql "INSERT INTO [$tps] ($($p.Name)) VALUES ('rrr')" -Owner $owner
        if ($null -eq $r.Json -or $r.Json.ok -ne $false -or
            "$($r.Json.error.code)" -ne 'VALUE_OUT_OF_RANGE' -or $r.ExitCode -ne 3) {
            Step-Fail $name "writing 'rrr' to picture column $($p.Name) was not refused with VALUE_OUT_OF_RANGE (exit $($r.ExitCode)): $($r.Raw)"
            return
        }
    }

    $d1 = Invoke-TpsOk -name $name -Sql "DESCRIBE [$tps]" -Owner $owner
    if ($null -eq $d1) { return }
    if ([int]$d1.records -ne $records0) {
        Step-Fail $name "records went from $records0 to $($d1.records)"; return
    }
    Step-Pass $name "$($writable.Count) leaves written, records back to $records0"
}

function Compare-RoundTripRow {
    param([string]$name, [string]$tps, [string]$owner,
          [string]$where, $values, $writable, [string]$phase)
    $sel = Invoke-TpsOk -name $name -Sql "SELECT * FROM [$tps] WHERE $where" -Owner $owner
    if ($null -eq $sel) { return $false }
    if ([int]$sel.row_count -ne 1) {
        Step-Fail $name "$phase : SELECT returned $($sel.row_count) rows, expected 1"; return $false
    }
    $colNames = @(@($sel.columns) | ForEach-Object { "$($_.name)" })
    $row = @(@($sel.rows)[0])
    $bad = @()
    foreach ($l in $writable) {
        $i = [array]::IndexOf($colNames, $l.Name)
        if ($i -lt 0) { $bad += "$($l.Name) missing from SELECT *"; continue }
        $actual = "$($row[$i])"
        $want = $values[$l.Name].Expected
        if ($actual -ne $want) { $bad += "$($l.Name) expected '$want' actual '$actual'" }
    }
    if ($bad.Count -gt 0) {
        Step-Fail $name "$phase : $($bad -join '; ')"; return $false
    }
    return $true
}

function Step3-RoundTrip {
    param($files)
    foreach ($f in $files) { Invoke-RoundTrip -label $f.Label -tps $f.Work -owner $f.Owner }
}

# ================================================================================
# Step 4 - dictionary parity for -Extra files
# ================================================================================

function Compare-OracleJson {
    param($exp, $act)
    $bad = New-Object System.Collections.ArrayList
    function Cmp($ctx, $e, $a, $props, $out) {
        foreach ($p in $props) { if ("$($e.$p)" -ne "$($a.$p)") { $null = $out.Add("$ctx.$p expected $($e.$p) actual $($a.$p)") } }
    }
    $ef = @($exp.fields); $af = @($act.fields)
    if ($ef.Count -ne $af.Count) { $null = $bad.Add("fields count expected $($ef.Count) actual $($af.Count)") }
    else { for ($i = 0; $i -lt $ef.Count; $i++) { Cmp "fields[$i]" $ef[$i] $af[$i] @('label','type','size','places','dim','over','fields','picture') $bad } }
    $em = @($exp.memos); $am = @($act.memos)
    if ($em.Count -ne $am.Count) { $null = $bad.Add("memos count expected $($em.Count) actual $($am.Count)") }
    else { for ($i = 0; $i -lt $em.Count; $i++) { Cmp "memos[$i]" $em[$i] $am[$i] @('label','type','binary','size') $bad } }
    $ek = @($exp.keys); $ak = @($act.keys)
    if ($ek.Count -ne $ak.Count) { $null = $bad.Add("keys count expected $($ek.Count) actual $($ak.Count)") }
    else {
        for ($i = 0; $i -lt $ek.Count; $i++) {
            Cmp "keys[$i]" $ek[$i] $ak[$i] @('label','type','dup','primary','nocase','opt') $bad
            $ec = @($ek[$i].components); $ac = @($ak[$i].components)
            if ($ec.Count -ne $ac.Count) { $null = $bad.Add("keys[$i].components count expected $($ec.Count) actual $($ac.Count)") }
            else { for ($j = 0; $j -lt $ec.Count; $j++) { Cmp "keys[$i].components[$j]" $ec[$j] $ac[$j] @('label','asc') $bad } }
        }
    }
    return @($bad)
}

function Step4-Parity {
    param($files)
    $name = 'step 4 dictionary parity'
    if ($Expected -eq '') {
        if ($Extra -ne '') { Note 'no -Expected folder given, so dictionary parity was not checked' }
        Step-Skip $name 'no -Expected folder given'
        return
    }
    $checked = 0
    $failed = 0
    foreach ($f in @($files | Where-Object { $_.IsExtra })) {
        $expPath = Join-Path $Expected "$($f.Label).json"
        if (-not (Test-Path $expPath)) { Step-Fail $name "no oracle JSON at $expPath"; $failed++; continue }
        $act = Invoke-TpsJson -name $name -Sql "DESCRIBE [$($f.Source)]" -Owner $f.Owner -Options @('--dump-schema')
        if ($null -eq $act) { $failed++; continue }
        $exp = Get-Content $expPath -Raw | ConvertFrom-Json
        $bad = Compare-OracleJson -exp $exp -act $act
        if ($bad.Count -gt 0) { Step-Fail $name "$($f.Label): $($bad -join '; ')"; $failed++ } else { $checked++ }
    }
    if ($failed -eq 0) { Step-Pass $name "$checked file(s) matched the dictionary export" }
}

# ================================================================================
# Step 5 - key walk integrity, and the TPSFix log when -Extra is given
# ================================================================================

function Step5-Keys {
    param($files)
    foreach ($f in $files) {
        $name = "step 5 key walk $($f.Label)"
        $d = Invoke-TpsOk -name $name -Sql "DESCRIBE [$($f.Work)]" -Owner $f.Owner
        if ($null -eq $d) { continue }
        $sch = Get-Schema -name $name -tps $f.Work -owner $f.Owner
        if ($null -eq $sch) { continue }
        $byName = @{}
        foreach ($l in $sch.Leaves) { $byName[$l.Name.ToUpper()] = $l }

        $records = [int]$d.records
        $bad = @()
        $walked = 0
        foreach ($k in $sch.Keys) {
            $r = Invoke-TpsOk -name $name -Sql "DESCRIBE [$($f.Work)]" -Owner $f.Owner -Options @('--walk-key', $k.Name)
            if ($null -eq $r) { $bad += "$($k.Name) did not walk"; continue }
            $walked++
            if ($r.ordered -ne $true) { $bad += "$($k.Name) walked out of key order" }

            if ($k.Unresolved.Count -gt 0) {
                $bad += "$($k.Name) has a component this script cannot address ($($k.Unresolved -join ', '))"
                continue
            }

            $want = $records
            if ($k.Opt) {
                # An OPT key omits rows whose every component is blank or zero, so the
                # expected count is the record count less exactly those rows.
                $terms = @()
                foreach ($c in $k.Components) {
                    $l = $byName[$c.ToUpper()]
                    $t = if ($l) { $l.Type } else { 'STRING' }
                    $terms += $(if (Test-NumericType $t) { "$c = 0" } else { "$c = ''" })
                }
                $blank = Invoke-TpsOk -name $name -Sql "SELECT $($k.Components[0]) FROM [$($f.Work)] WHERE $($terms -join ' AND ')" -Owner $f.Owner
                if ($null -eq $blank) { continue }
                $want = $records - [int]$blank.row_count
            }
            $got = [int]$r.count
            if ($got -ne $want) {
                if (-not $k.IsKey -and $got -eq 0) {
                    # An INDEX is populated by BUILD, which tpscli never issues, so an index
                    # that was never built legitimately walks zero rows. See README.
                    Note "$($f.Label) : INDEX $($k.Name) walks 0 rows (never BUILT); count check skipped"
                } else {
                    $bad += "$($k.Name) walked $got rows, expected $want"
                }
            }
        }
        if ($bad.Count -gt 0) { Step-Fail $name ($bad -join '; ') }
        else { Step-Pass $name "$walked key(s) walked in order against $records records" }
    }

    $name = 'step 5 TPSFix log'
    if ($Extra -eq '') {
        Step-Skip $name 'no -Extra folder given'
        return
    }
    if ($TpsFixLog -eq '') { Step-Fail $name '-Extra was given without -TpsFixLog'; return }
    if (-not (Test-Path $TpsFixLog)) { Step-Fail $name "-TpsFixLog $TpsFixLog does not exist"; return }
    $age = (Get-Date) - (Get-Item $TpsFixLog).LastWriteTime
    if ($age.TotalHours -gt 24) { Step-Fail $name "-TpsFixLog is $([int]$age.TotalHours)h old; rerun TPSFix today"; return }
    $errLines = @(Get-Content $TpsFixLog | Where-Object { $_ -match '(?i)\b(error|corrupt|damaged|cannot|failed)\b' })
    if ($errLines.Count -gt 0) { Step-Fail $name "TPSFix log reports $($errLines.Count) problem line(s): $($errLines[0])"; return }
    Step-Pass $name 'TPSFix log is clean and current'
}

# ================================================================================
# Step 6 - shared access: a second process holds a record
# ================================================================================

function Step6-SharedAccess {
    $name = 'step 6 shared access'
    $workDir = Join-Path $root 'testdata\work'
    $workKeys = Join-Path $workDir 'KEYS.TPS'
    $flag = Join-Path $workDir 'held.flag'
    New-Item -ItemType Directory -Force -Path $workDir | Out-Null
    Copy-Item (Join-Path $root "$Corpus\KEYS.TPS") $workKeys -Force
    Remove-Item $flag -ErrorAction SilentlyContinue

    # tests\hold.exe opens testdata\work\KEYS.TPS through a relative NAME(), so it runs with
    # the repository root as its working directory, and drops held.flag once the record on
    # Id 2 is actually held. Same sequence as tests\update.ps1.
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
        if (-not $holder.HasExited) { try { $holder.Kill() } catch {} }
        Step-Fail $name 'tests\hold.exe never reported holding the record'
        return
    }

    $bad = @()
    $sel = Invoke-Tps -Sql 'SELECT ID, NAME FROM [testdata\work\KEYS.TPS] ORDER BY ID'
    if ($null -eq $sel.Json -or -not $sel.Json.ok) { $bad += "SELECT against the held file failed: $($sel.Raw)" }
    elseif ([int]$sel.Json.row_count -ne 5) { $bad += "SELECT returned $($sel.Json.row_count) rows, expected 5" }

    $del = Invoke-Tps -Sql 'DELETE FROM [testdata\work\KEYS.TPS] WHERE ID > 0'
    if ($null -eq $del.Json) { $bad += "DELETE produced no JSON: $($del.Raw)" }
    else {
        if ($del.Json.ok -ne $false) { $bad += 'DELETE against a held record reported ok' }
        if ("$($del.Json.error.code)" -ne 'RECORD_HELD') { $bad += "DELETE error code was '$($del.Json.error.code)', expected RECORD_HELD" }
        if ("$($del.Json.outcome)" -ne 'rolled_back') { $bad += "DELETE outcome was '$($del.Json.outcome)', expected rolled_back" }
        if ([int]$del.Json.affected -ne 0) { $bad += "DELETE affected $($del.Json.affected), expected 0" }
        if ($del.ExitCode -ne 3) { $bad += "DELETE exited $($del.ExitCode), expected 3" }
    }

    if (-not $holder.WaitForExit(30000)) {
        try { $holder.Kill() } catch {}
        $bad += 'tests\hold.exe did not exit within 30s'
    } elseif ($holder.ExitCode -ne 0) {
        $bad += "tests\hold.exe exited $($holder.ExitCode)"
    }

    $d = Invoke-Tps -Sql 'DESCRIBE [testdata\work\KEYS.TPS]'
    if ($null -eq $d.Json) { $bad += "DESCRIBE after the rollback produced no JSON: $($d.Raw)" }
    elseif ([int]$d.Json.records -ne 5) { $bad += "rollback left $($d.Json.records) records, expected 5" }

    if ($bad.Count -gt 0) { Step-Fail $name ($bad -join '; ') }
    else { Step-Pass $name 'read succeeded, write reported RECORD_HELD and rolled back' }
}

# ================================================================================
# Step 7 - performance: a keyed SELECT against the largest file, five times
# ================================================================================

function Step7-Performance {
    param($files)
    $name = 'step 7 performance'
    $largest = $files | Sort-Object { (Get-Item $_.Full).Length } -Descending | Select-Object -First 1
    if ($null -eq $largest) { Step-Fail $name 'no corpus file'; return }

    $sch = Get-Schema -name $name -tps $largest.Source -owner $largest.Owner
    if ($null -eq $sch) { return }
    # A real KEY, not an INDEX: an INDEX is only populated by BUILD, so ordering by an unbuilt
    # one returns no rows and this step would blame the timing for a schema fact.
    $k = @($sch.Keys | Where-Object { $_.IsKey -and -not $_.Opt -and $_.Components.Count -gt 0 }) | Select-Object -First 1
    if ($null -eq $k) { Step-Fail $name "$($largest.Label) has no non-optional KEY"; return }
    $col = $k.Components[0]
    $sql = "SELECT $col FROM [$($largest.Source)] ORDER BY $col LIMIT 1"

    # One discarded warm-up, then five timed runs. Each timing is the exe's own lifetime
    # (process start through exit), which is what spec section 7 budgets at 250 ms.
    $null = Invoke-Tps -Sql $sql -Owner $largest.Owner
    $times = @()
    for ($i = 0; $i -lt 5; $i++) {
        $r = Invoke-Tps -Sql $sql -Owner $largest.Owner
        if ($null -eq $r.Json -or -not $r.Json.ok) { Step-Fail $name "run $($i+1) failed: $($r.Raw)"; return }
        if ([int]$r.Json.row_count -ne 1) { Step-Fail $name "run $($i+1) returned $($r.Json.row_count) rows, expected 1"; return }
        $times += $r.ElapsedMs
    }
    $median = (@($times | Sort-Object))[2]
    if ($median -gt 250) {
        Step-Fail $name ("median {0:N0} ms over 250 ms on {1} ({2})" -f $median, $largest.Label, $sql)
    } else {
        Step-Pass $name ("median {0:N0} ms on {1} (key {2}); runs {3}" -f $median, $largest.Label, $k.Name, ((@($times | ForEach-Object { '{0:N0}' -f $_ })) -join '/'))
    }
}

# ================================================================================
# Driver
# ================================================================================

Write-Host "tpscli verify - corpus '$Corpus'$(if ($Extra) { ", extra '$Extra'" })"
Write-Host ''

if ($Extra -ne '' -and $TpsFixLog -eq '') {
    Write-Host 'FAIL  -Extra requires -TpsFixLog (the manual TPSFix run over those files)'
    exit 1
}

Step1-Build

# Round trips and key walks run against copies so the committed fixtures stay pristine and a
# failed run never leaves a corpus file mutated.
$verifyDir = Join-Path $root 'testdata\work\verify'
if (Test-Path $verifyDir) { Remove-Item $verifyDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $verifyDir | Out-Null

$files = @()
foreach ($p in @(Get-ChildItem (Join-Path $root $Corpus) -Filter *.TPS -File | Sort-Object Name)) {
    $label = [IO.Path]::GetFileNameWithoutExtension($p.Name)
    Copy-Item $p.FullName (Join-Path $verifyDir $p.Name) -Force
    $files += [pscustomobject]@{
        Label   = $label
        Source  = "$Corpus\$($p.Name)"
        Full    = $p.FullName
        Work    = "testdata\work\verify\$($p.Name)"
        Owner   = $(if ($owners.ContainsKey($label)) { $owners[$label] } else { '' })
        IsExtra = $false
    }
}
if ($Extra -ne '') {
    foreach ($p in @(Get-ChildItem $Extra -Filter *.TPS -File | Sort-Object Name)) {
        $label = [IO.Path]::GetFileNameWithoutExtension($p.Name)
        Copy-Item $p.FullName (Join-Path $verifyDir $p.Name) -Force
        $files += [pscustomobject]@{
            Label   = $label
            Source  = $p.FullName
            Full    = $p.FullName
            Work    = "testdata\work\verify\$($p.Name)"
            Owner   = $(if ($owners.ContainsKey($label)) { $owners[$label] } else { '' })
            IsExtra = $true
        }
    }
}

Step2-Tests
Step3-RoundTrip -files $files
Step4-Parity -files $files
Step5-Keys -files $files
Step6-SharedAccess
Step7-Performance -files $files

Write-Host ''
if ($notes.Count -gt 0) { Write-Host "$($notes.Count) note(s) above" }
if ($failures -gt 0) {
    Write-Host "verify.ps1: $failures step(s) FAILED"
    exit 1
}
if ($skips -gt 0) {
    Write-Host "verify.ps1: all steps PASS ($skips skipped - not a release qualification)"
} else {
    Write-Host 'verify.ps1: all steps PASS'
}
exit 0
