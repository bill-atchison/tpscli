# Shared by select.ps1/parser.ps1/describe.ps1. Runs an exe with a hard wall-clock timeout so a
# crashed process sitting behind the Clarion runtime's modal crash dialog (confirmed to happen -
# see task-7-report.md) never blocks a test run for hours instead of seconds. On timeout the
# process is killed and the caller gets TimedOut=$true instead of hanging forever.
#
# Start-Process -ArgumentList, given a string ARRAY, does not quote elements containing spaces
# (each element is passed through as its own raw command-line word) - confirmed by a failing
# probe run before this helper existed. Build one correctly quoted command-line STRING instead.
function ConvertTo-Tpscli_CommandLine {
    param([string[]]$ArgumentList)
    ($ArgumentList | ForEach-Object {
        if ($_ -eq '') { '""' }
        elseif ($_ -match '[\s]') { '"' + ($_ -replace '"', '\"') + '"' }
        else { $_ }
    }) -join ' '
}

function Invoke-Tpscli_Bounded {
    param(
        [Parameter(Mandatory)] [string]$FilePath,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]]$ArgumentList,
        [Parameter(Mandatory)] [string]$WorkingDirectory,
        [int]$TimeoutMs = 20000
    )
    $outFile = [System.IO.Path]::GetTempFileName()
    $errFile = [System.IO.Path]::GetTempFileName()
    try {
        # An exe that takes no arguments (testdata\gen\mkcorpus.exe) passes @(); Start-Process
        # rejects an empty -ArgumentList, so the parameter is omitted entirely in that case.
        $cmdLine = ConvertTo-Tpscli_CommandLine -ArgumentList $ArgumentList
        $common = @{
            FilePath = $FilePath; WorkingDirectory = $WorkingDirectory
            RedirectStandardOutput = $outFile; RedirectStandardError = $errFile
            PassThru = $true; NoNewWindow = $true
        }
        if ($cmdLine -ne '') { $common['ArgumentList'] = $cmdLine }
        # ElapsedMs below times the child process only (launch to exit), not this function's
        # temp-file and Get-Content plumbing, so verify.ps1's performance step measures what
        # the spec asks for: process start plus the statement.
        $clock = [System.Diagnostics.Stopwatch]::StartNew()
        $proc = Start-Process @common
        # Start-Process -PassThru does not populate ExitCode reliably (a documented Windows
        # PowerShell quirk) unless .Handle is touched before the process exits - confirmed by a
        # failing probe run (ExitCode came back blank) before this line was added.
        $null = $proc.Handle

        if (-not $proc.WaitForExit($TimeoutMs)) {
            try { $proc.Kill() } catch {}
            $clock.Stop()
            return [pscustomobject]@{
                TimedOut  = $true
                ExitCode  = -1
                StdOut    = ''
                StdErr    = ''
                ElapsedMs = $clock.Elapsed.TotalMilliseconds
            }
        }

        $clock.Stop()
        return [pscustomobject]@{
            TimedOut  = $false
            ExitCode  = $proc.ExitCode
            StdOut    = (Get-Content -Path $outFile -Raw -ErrorAction SilentlyContinue)
            StdErr    = (Get-Content -Path $errFile -Raw -ErrorAction SilentlyContinue)
            ElapsedMs = $clock.Elapsed.TotalMilliseconds
        }
    } finally {
        Remove-Item $outFile, $errFile -ErrorAction SilentlyContinue
    }
}
