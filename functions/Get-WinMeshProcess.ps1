<#
.SYNOPSIS
    Asks a fleet machine about a process started by Start-WinMeshProcess.
.DESCRIPTION
    Answers three questions in one round trip: is it still running, how did it
    end, and where is its output now.

    "Still running" is not decided by the process id alone. A pid is recycled,
    and a recycled one answers Get-Process like a healthy job. So the start time
    recorded when the process was launched is compared with the start time of
    the process holding that pid now; a mismatch is reported as a reused pid
    rather than as a live run.

    "How did it end" comes from the done file the wrapper writes as its last
    act, never from elapsed time. Three states are distinguishable, and the
    third is the one that matters:

      * alive, no done file         - still working;
      * not alive, done file        - finished, ExitCode is its exit code;
      * not alive, no done file     - killed or died; nothing wrote a result.
.PARAMETER Name
    Machine name from the config.
.PARAMETER Process
    The object Start-WinMeshProcess returned.
.PARAMETER ProcessId
    Instead of -Process: the pid, with the paths given separately.
.PARAMETER Tail
    Also return the last N lines of the output file.
.EXAMPLE
    $job = Start-WinMeshProcess workstation-01 { ninja -C C:/src/build }
    Get-WinMeshProcess workstation-01 -Process $job -Tail 20
#>
function Get-WinMeshProcess {
    [CmdletBinding(DefaultParameterSetName = 'Process')]
    param(
        [Parameter(Mandatory, Position = 0)] [string]$Name,
        [Parameter(Mandatory, Position = 1, ParameterSetName = 'Process')] [object]$Process,
        [Parameter(Mandatory, ParameterSetName = 'Explicit')] [int]$ProcessId,
        [Parameter(ParameterSetName = 'Explicit')] [string]$DonePath,
        [Parameter(ParameterSetName = 'Explicit')] [string]$StdoutPath,
        [Parameter(ParameterSetName = 'Explicit')] [object]$StartUtc,
        [int]$Tail = 0,
        [object]$Config
    )

    if (-not $Config) { $Config = Get-WinMeshConfig }
    $h = $Config.Hosts[$Name]
    if (-not $h) { throw "Host '$Name' is not in config $($Config.Path)." }
    if ($h.Transport -ne 'ssh') {
        throw "Host '$Name' uses the '$($h.Transport)' transport. Get-WinMeshProcess is ssh only."
    }

    if ($PSCmdlet.ParameterSetName -eq 'Process') {
        if (-not $Process.ProcessId) {
            throw "-Process needs the object Start-WinMeshProcess returned (it has ProcessId, DonePath and StdoutPath)."
        }
        $ProcessId  = [int]$Process.ProcessId
        $DonePath   = "$($Process.DonePath)"
        $StdoutPath = "$($Process.StdoutPath)"
        $StartUtc   = $Process.StartUtc
    }

    $r = Invoke-WinMeshSsh -HostEntry $h -Defaults $Config.Defaults -ArgumentList @(
        $ProcessId, $StartUtc, $DonePath, $StdoutPath, $Tail
    ) -ScriptBlock {
        param($procId, $startUtc, $donePath, $outPath, $tail)

        $alive  = $false
        $reason = ''
        $live   = $null
        try { $live = Get-Process -Id $procId -ErrorAction Stop } catch { $live = $null }

        if ($live) {
            $liveStart = $null
            # StartTime throws for a process this account may not query.
            try { $liveStart = $live.StartTime.ToUniversalTime() } catch { $liveStart = $null }

            if ($startUtc -and $liveStart) {
                if ([math]::Abs(([datetime]$startUtc - $liveStart).TotalSeconds) -lt 2) {
                    $alive = $true
                } else {
                    $reason = "pid $procId is held by a different process now (it started $liveStart, this run started $([datetime]$startUtc))"
                }
            } elseif ($liveStart -or $startUtc) {
                $alive  = $true
                $reason = 'pid matches, start times could not be compared'
            } else {
                $alive  = $true
                $reason = 'pid matches, no start time on either side'
            }
        }

        $exitCode = $null
        $finished = $false
        if ($donePath -and (Test-Path -LiteralPath $donePath -PathType Leaf)) {
            $finished = $true
            $text = ([IO.File]::ReadAllText($donePath)).Trim()
            $n = 0
            if ([int]::TryParse($text, [ref]$n)) { $exitCode = $n }
        }

        if (-not $alive -and -not $finished -and -not $reason) {
            $reason = 'the process is gone and wrote no exit code: it was killed or died'
        }

        $bytes = $null
        $lastWrite = $null
        $lines = @()
        if ($outPath -and (Test-Path -LiteralPath $outPath -PathType Leaf)) {
            $f = Get-Item -LiteralPath $outPath
            $bytes = $f.Length
            $lastWrite = $f.LastWriteTimeUtc
            if ($tail -gt 0) { $lines = @(Get-Content -LiteralPath $outPath -Tail $tail) }
        }

        [pscustomobject]@{
            Alive        = $alive
            Finished     = $finished
            ExitCode     = $exitCode
            Reason       = $reason
            StdoutBytes  = $bytes
            LastWriteUtc = $lastWrite
            Tail         = $lines
        }
    }

    [pscustomobject]@{
        Host         = $Name
        ProcessId    = $ProcessId
        Alive        = $r.Alive
        Finished     = $r.Finished
        ExitCode     = $r.ExitCode
        Reason       = $r.Reason
        StdoutPath   = $StdoutPath
        StdoutBytes  = $r.StdoutBytes
        LastWriteUtc = $r.LastWriteUtc
        Tail         = $r.Tail
    }
}
