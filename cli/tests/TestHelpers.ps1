# Shared by every tests\*.ps1 suite, verify.ps1 and tests\run-instrument.ps1. Runs an exe with a
# hard wall-clock timeout so a
# crashed process sitting behind the Clarion runtime's modal crash dialog (confirmed to happen -
# see task-7-report.md) never blocks a test run for hours instead of seconds. On timeout the
# process is killed and the caller gets TimedOut=$true instead of hanging forever.
#
# Windows PowerShell that inherited PowerShell 7's PSModulePath (a shell, or the Actions runner,
# launched from pwsh) autoloads the PS7 copy of Microsoft.PowerShell.Utility and loses the script
# functions in the 5.1 one: Get-FileHash is "not recognized" (seen on the first release run).
# Every suite, verify.ps1 and release.ps1 dot-source this file, so the 5.1 module path is put back
# here, once, for the process and its children.
if ($PSVersionTable.PSEdition -ne 'Core') { $env:PSModulePath = "$env:ProgramFiles\WindowsPowerShell\Modules;$PSHOME\Modules" }
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
    # System.Diagnostics.Process is used instead of Start-Process -PassThru: with output
    # redirection, Windows PowerShell 5.1's Start-Process launches the child natively and returns
    # a Process object that does not own the handle, so a child that exits before the caller
    # touches .Handle (tpscli.exe finishes in milliseconds) reports ExitCode $null - reproduced
    # at roughly 1 in 300 runs by tests\helpers.ps1. Process.Start owns the handle from creation.
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = ConvertTo-Tpscli_CommandLine -ArgumentList $ArgumentList
    $psi.WorkingDirectory = $WorkingDirectory
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardInput = $true     # closed right after start: the child sees EOF, as with < $null
    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    try {
        # ElapsedMs times the child process only (launch to exit), not this function's stream
        # plumbing, so verify.ps1's performance step measures what the spec asks for: process
        # start plus the statement.
        $clock = [System.Diagnostics.Stopwatch]::StartNew()
        # .NET Framework builds the child's stdin writer from [Console]::InputEncoding, and when
        # the console is UTF-8 that encoding carries a preamble, so closing the writer sends a
        # byte-order mark (EF BB BF) that tpscli reads as a one-character statement. The known
        # workaround is a preamble-free console input encoding while the process starts.
        $savedInput = $null
        try {
            if ([Console]::InputEncoding.GetPreamble().Length -gt 0) {
                $savedInput = [Console]::InputEncoding
                [Console]::InputEncoding = New-Object System.Text.UTF8Encoding($false)
            }
        } catch { $savedInput = $null }
        try { $null = $proc.Start() }
        finally { if ($savedInput) { try { [Console]::InputEncoding = $savedInput } catch {} } }
        $proc.StandardInput.Close()
        # Both pipes are drained asynchronously so a child that fills one pipe while the caller
        # waits on the other can never deadlock.
        $outTask = $proc.StandardOutput.ReadToEndAsync()
        $errTask = $proc.StandardError.ReadToEndAsync()

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
        $proc.WaitForExit()   # the parameterless overload flushes the redirected streams

        return [pscustomobject]@{
            TimedOut  = $false
            ExitCode  = $proc.ExitCode
            StdOut    = $outTask.Result
            StdErr    = $errTask.Result
            ElapsedMs = $clock.Elapsed.TotalMilliseconds
        }
    } finally {
        $proc.Dispose()
    }
}
