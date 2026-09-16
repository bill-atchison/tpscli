param()
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$exe = Join-Path $root 'tpscli.exe'

$files = @(
    @{ name = 'ALLTYPES'; owner = $null },
    @{ name = 'KEYS';     owner = $null },
    @{ name = 'GROUPS';   owner = $null },
    @{ name = 'MEMOS';    owner = $null },
    @{ name = 'NOKEY';    owner = $null },
    @{ name = 'SECRET';   owner = 's3cret' }
)

$mismatches = 0

function Report([string]$ctx, [string]$prop, $expected, $actual) {
    Write-Host ("{0}: {1} expected={2} actual={3}" -f $ctx, $prop, $expected, $actual)
    $script:mismatches++
}

function CmpProp([string]$ctx, $exp, $act, [string[]]$props) {
    foreach ($p in $props) {
        $e = $exp.$p
        $a = $act.$p
        if ("$e" -ne "$a") { Report $ctx $p $e $a }
    }
}

foreach ($f in $files) {
    $name = $f.name
    $tpsPath = "testdata\$name.TPS"
    $argList = @('--dump-schema')
    if ($f.owner) { $argList += @('--owner', $f.owner) }
    $argList += "DESCRIBE [$tpsPath]"

    Push-Location $root
    try {
        $rawOut = & $exe @argList 2>&1
    } finally {
        Pop-Location
    }

    $expPath = Join-Path $root "testdata\expected\$name.json"
    $exp = Get-Content $expPath -Raw | ConvertFrom-Json

    try {
        $act = ($rawOut -join "`n") | ConvertFrom-Json
    } catch {
        Report $name 'output' 'valid JSON' ($rawOut -join ' | ')
        continue
    }

    if ($null -eq $act) {
        Report $name 'output' 'valid JSON' '<null>'
        continue
    }

    $expFields = @($exp.fields)
    $actFields = @($act.fields)
    if ($expFields.Count -ne $actFields.Count) {
        Report "$name.fields" 'count' $expFields.Count $actFields.Count
    } else {
        for ($i = 0; $i -lt $expFields.Count; $i++) {
            CmpProp "$name.fields[$i]" $expFields[$i] $actFields[$i] @('label','type','size','places','dim','over','fields','picture')
        }
    }

    $expMemos = @($exp.memos)
    $actMemos = @($act.memos)
    if ($expMemos.Count -ne $actMemos.Count) {
        Report "$name.memos" 'count' $expMemos.Count $actMemos.Count
    } else {
        for ($i = 0; $i -lt $expMemos.Count; $i++) {
            CmpProp "$name.memos[$i]" $expMemos[$i] $actMemos[$i] @('label','type','binary','size')
        }
    }

    $expKeys = @($exp.keys)
    $actKeys = @($act.keys)
    if ($expKeys.Count -ne $actKeys.Count) {
        Report "$name.keys" 'count' $expKeys.Count $actKeys.Count
    } else {
        for ($i = 0; $i -lt $expKeys.Count; $i++) {
            $ek = $expKeys[$i]
            $ak = $actKeys[$i]
            CmpProp "$name.keys[$i]" $ek $ak @('label','type','dup','primary','nocase','opt')
            $ec = @($ek.components)
            $ac = @($ak.components)
            if ($ec.Count -ne $ac.Count) {
                Report "$name.keys[$i].components" 'count' $ec.Count $ac.Count
            } else {
                for ($j = 0; $j -lt $ec.Count; $j++) {
                    CmpProp "$name.keys[$i].components[$j]" $ec[$j] $ac[$j] @('label','asc')
                }
            }
        }
    }
}

if ($mismatches -gt 0) {
    exit 1
} else {
    exit 0
}
