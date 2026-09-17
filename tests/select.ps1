param()
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$exe = Join-Path $root 'tpscli.exe'
# Built via [char] concatenation, not a literal backslash-u escape in this source file: a
# literal  in this file's own authoring got reinterpreted as a real control byte by the
# tool that wrote the file. Building it here keeps the six literal ASCII characters intact.
$bs = [char]92
$rawGE = $bs + 'u0012'    # RAW's control byte in the GROUPS star row (RAW/RAWL share storage)
$rawNul = $bs + 'u0000'   # MEMOS.BIN's embedded CHR(0)
$rawFF = $bs + 'u00ff'    # MEMOS.BIN's embedded CHR(255)

# Each case: ExtraArgs (before the SQL), Sql, Expected (stdout), ExitCode.
$cases = @(
    @{
        Name = 'ALLTYPES basic column list'
        ExtraArgs = @()
        Sql = "SELECT ID, STR, D, DT, TM, ARR[2] FROM [testdata\ALLTYPES.TPS] WHERE ID = 1"
        Expected = '{ "ok": true, "op": "select", "columns": [{"name":"ID","type":"LONG"},{"name":"STR","type":"STRING"},{"name":"D","type":"DECIMAL"},{"name":"DT","type":"DATE"},{"name":"TM","type":"TIME"},{"name":"ARR[2]","type":"SHORT"}], "rows": [[1,"alpha","12345.67","2026-09-15","13:45:30.00",20]], "row_count": 1, "truncated": false, "complete": true }'
        Exit = 0
    },
    @{
        Name = 'GROUPS star, keyed ORDER BY, LIMIT 1 (truncated)'
        ExtraArgs = @()
        Sql = "SELECT * FROM [testdata\GROUPS.TPS] ORDER BY ID LIMIT 1"
        Expected = '{ "ok": true, "op": "select", "columns": [{"name":"ID","type":"LONG"},{"name":"ADDR.LINE1","type":"STRING"},{"name":"ADDR.CITY","type":"STRING"},{"name":"ADDR.GEO.LAT","type":"REAL"},{"name":"ADDR.GEO.LON","type":"REAL"},{"name":"PHONES[1].KIND","type":"STRING"},{"name":"PHONES[1].NUMBER","type":"STRING"},{"name":"PHONES[1].EXT[1]","type":"STRING"},{"name":"PHONES[1].EXT[2]","type":"STRING"},{"name":"PHONES[2].KIND","type":"STRING"},{"name":"PHONES[2].NUMBER","type":"STRING"},{"name":"PHONES[2].EXT[1]","type":"STRING"},{"name":"PHONES[2].EXT[2]","type":"STRING"},{"name":"RAW","type":"STRING"},{"name":"RAWL","type":"LONG"},{"name":"GRID[1]","type":"SHORT"},{"name":"GRID[2]","type":"SHORT"},{"name":"GRID[3]","type":"SHORT"},{"name":"GRID[4]","type":"SHORT"},{"name":"GRID[5]","type":"SHORT"},{"name":"GRID[6]","type":"SHORT"}], "rows": [[1,"One Main St","Springfield",39.78,-89.65,"H","555-1000","a1","a2","M","555-2000","b1","b2",' + '"xV4' + $rawGE + '"' + ',305419896,1,2,3,4,5,6]], "row_count": 1, "truncated": true, "complete": true }'
        Exit = 0
    },
    @{
        Name = 'ADDR.CITY column named with its dotted path'
        ExtraArgs = @()
        Sql = "SELECT ADDR.CITY FROM [testdata\GROUPS.TPS] WHERE ID = 1"
        Expected = '{ "ok": true, "op": "select", "columns": [{"name":"ADDR.CITY","type":"STRING"}], "rows": [["Springfield"]], "row_count": 1, "truncated": false, "complete": true }'
        Exit = 0
    },
    @{
        Name = 'PHONES[2].EXT[2]: leaf nested two DIMs deep, second group occurrence'
        ExtraArgs = @()
        Sql = "SELECT PHONES[2].EXT[2] FROM [testdata\GROUPS.TPS] WHERE ID = 1"
        Expected = '{ "ok": true, "op": "select", "columns": [{"name":"PHONES[2].EXT[2]","type":"STRING"}], "rows": [["b2"]], "row_count": 1, "truncated": false, "complete": true }'
        Exit = 0
    },
    @{
        Name = 'WHERE on a leaf inside a DIMd GROUP is UNSUPPORTED (EVALUATE cannot address it - see task-7-report.md)'
        ExtraArgs = @()
        Sql = "SELECT ID FROM [testdata\GROUPS.TPS] WHERE PHONES[2].KIND = 'M' ORDER BY ID"
        Expected = '{ "ok": false, "op": "select", "error": { "code": "UNSUPPORTED", "message": "Array elements in WHERE are not supported for a leaf inside a DIM''d GROUP (PHONES[2].KIND)", "position": 44, "token": "PHONES[2].KIND" }, "outcome": "none", "complete": true }'
        Exit = 1
    },
    @{
        Name = 'KEYS: LIKE proves MATCH mode 1, ORDER BY AMOUNT DESC, ID matches DescKey forward'
        ExtraArgs = @()
        Sql = "SELECT ID FROM [testdata\KEYS.TPS] WHERE NAME LIKE '%a%' ORDER BY AMOUNT DESC, ID"
        Expected = '{ "ok": true, "op": "select", "columns": [{"name":"ID","type":"LONG"}], "rows": [[2],[3],[4]], "row_count": 3, "truncated": false, "complete": true }'
        Exit = 0
    },
    @{
        Name = 'KEYS: ORDER BY AMOUNT ASC, ID DESC matches DescKey walked in reverse'
        ExtraArgs = @()
        Sql = "SELECT ID FROM [testdata\KEYS.TPS] ORDER BY AMOUNT ASC, ID DESC"
        Expected = '{ "ok": true, "op": "select", "columns": [{"name":"ID","type":"LONG"}], "rows": [[5],[4],[3],[2],[1]], "row_count": 5, "truncated": false, "complete": true }'
        Exit = 0
    },
    @{
        Name = 'KEYS: ORDER BY CODE has no matching key (OptKey is skipped) - sort fallback, all 5 rows'
        ExtraArgs = @()
        Sql = "SELECT ID, CODE FROM [testdata\KEYS.TPS] ORDER BY CODE"
        Expected = '{ "ok": true, "op": "select", "columns": [{"name":"ID","type":"LONG"},{"name":"CODE","type":"STRING"}], "rows": [[2,""],[4,""],[1,"A"],[3,"C"],[5,"E"]], "row_count": 5, "truncated": false, "complete": true }'
        Exit = 0
    },
    @{
        Name = 'KEYS: IN proves INLIST, ORDER BY NAME matches DupKey (NOCASE key still chosen)'
        ExtraArgs = @()
        Sql = "SELECT ID, NAME FROM [testdata\KEYS.TPS] WHERE CODE IN ('A','E') ORDER BY NAME"
        Expected = '{ "ok": true, "op": "select", "columns": [{"name":"ID","type":"LONG"},{"name":"NAME","type":"STRING"}], "rows": [[1,"Able"],[5,"Echo"]], "row_count": 2, "truncated": false, "complete": true }'
        Exit = 0
    },
    @{
        Name = 'KEYS: LIMIT + OFFSET together, truncated true'
        ExtraArgs = @()
        Sql = "SELECT ID FROM [testdata\KEYS.TPS] ORDER BY ID LIMIT 2 OFFSET 1"
        Expected = '{ "ok": true, "op": "select", "columns": [{"name":"ID","type":"LONG"}], "rows": [[2],[3]], "row_count": 2, "truncated": true, "complete": true }'
        Exit = 0
    },
    @{
        Name = 'KEYS: no matches -> empty rows, still ok:true'
        ExtraArgs = @()
        Sql = "SELECT ID FROM [testdata\KEYS.TPS] WHERE ID > 999"
        Expected = '{ "ok": true, "op": "select", "columns": [{"name":"ID","type":"LONG"}], "rows": [], "row_count": 0, "truncated": false, "complete": true }'
        Exit = 0
    },
    @{
        Name = 'MEMOS: MEMO by value, BINARY MEMO with a high byte escaped, BLOB base64'
        ExtraArgs = @()
        Sql = "SELECT ID, NOTES, BIN, PIC FROM [testdata\MEMOS.TPS] WHERE ID = 1"
        Expected = '{ "ok": true, "op": "select", "columns": [{"name":"ID","type":"LONG"},{"name":"NOTES","type":"MEMO"},{"name":"BIN","type":"MEMO"},{"name":"PIC","type":"BLOB"}], "rows": [[1,"line one\r\nline two",' + '"x' + $rawNul + 'y' + $rawFF + '"' + ',"UE5HPw=="]], "row_count": 1, "truncated": false, "complete": true }'
        Exit = 0
    },
    @{
        Name = 'SECRET: encrypted file opened with --owner'
        ExtraArgs = @('--owner', 's3cret')
        Sql = "SELECT ID FROM [testdata\SECRET.TPS]"
        Expected = '{ "ok": true, "op": "select", "columns": [{"name":"ID","type":"LONG"}], "rows": [[1],[2]], "row_count": 2, "truncated": false, "complete": true }'
        Exit = 0
    },
    @{
        Name = 'KEYS: LIMIT 2 of 5 rows -> truncated true (the probe row proves it)'
        ExtraArgs = @()
        Sql = "SELECT ID FROM [testdata\KEYS.TPS] LIMIT 2"
        Expected = '{ "ok": true, "op": "select", "columns": [{"name":"ID","type":"LONG"}], "rows": [[1],[2]], "row_count": 2, "truncated": true, "complete": true }'
        Exit = 0
    },
    @{
        Name = 'KEYS: LIMIT 5 of 5 rows -> truncated false (limit exactly exhausts the filter)'
        ExtraArgs = @()
        Sql = "SELECT ID FROM [testdata\KEYS.TPS] LIMIT 5"
        Expected = '{ "ok": true, "op": "select", "columns": [{"name":"ID","type":"LONG"}], "rows": [[1],[2],[3],[4],[5]], "row_count": 5, "truncated": false, "complete": true }'
        Exit = 0
    },
    @{
        Name = '--table: aligned grid, right-align numeric columns, left-align text'
        ExtraArgs = @('--table')
        Sql = "SELECT ID, NAME, CODE, AMOUNT FROM [testdata\KEYS.TPS] ORDER BY ID"
        Expected = @(
            'ID  NAME     CODE  AMOUNT'
            '--  -------  ----  ------'
            ' 1  Able     A          5'
            ' 2  baker               4'
            ' 3  Charlie  C          3'
            ' 4  delta               2'
            ' 5  Echo     E          1'
            '(5 rows)'
        ) -join "`n"
        Exit = 0
    }
)

$failures = 0

foreach ($c in $cases) {
    $argList = @() + $c.ExtraArgs + @($c.Sql)

    Push-Location $root
    try {
        $stdout = & $exe @argList 2>&1
        $exit = $LASTEXITCODE
    } finally {
        Pop-Location
    }

    $actual = (($stdout | Out-String)) -replace "`r`n", "`n"
    $actual = $actual.TrimEnd("`n")
    $expected = $c.Expected -replace "`r`n", "`n"
    $expected = $expected.TrimEnd("`n")

    $ok = $true
    if ($actual -ne $expected) {
        $ok = $false
        Write-Host "select.ps1: MISMATCH in '$($c.Name)'"
        Write-Host "  sql:      $($c.Sql)"
        Write-Host "  expected: $expected"
        Write-Host "  actual:   $actual"
    }
    if ($exit -ne $c.Exit) {
        $ok = $false
        Write-Host "select.ps1: EXIT MISMATCH in '$($c.Name)': expected $($c.Exit), actual $exit"
    }
    if (-not $ok) { $failures++ }
}

if ($failures -gt 0) {
    Write-Host "select.ps1: $failures of $($cases.Count) cases FAILED"
    exit 1
} else {
    Write-Host "select.ps1: OK ($($cases.Count) cases)"
    exit 0
}
