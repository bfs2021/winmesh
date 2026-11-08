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
.PARAMETER RunId
    Instead of -Process: the RunId Start-WinMeshProcess returned. Everything else
    is read from the files the job left on the target next to itself, so one
    twelve-character string survives the end of the session that started the
    work. This is the form to use from a script, a scheduled job or anything
    whose memory does not outlive the run.
.PARAMETER ProcessId
    Instead of -Process or -RunId: the pid, with the paths given separately.
.PARAMETER Tail
    Also return the last N lines of the output file.
.EXAMPLE
    $job = Start-WinMeshProcess workstation-01 { ninja -C C:/src/build }
    Get-WinMeshProcess workstation-01 -Process $job -Tail 20
.EXAMPLE
    # the same job from a later session, with only the run id written down
    Get-WinMeshProcess workstation-01 -RunId 7f3a19c2b40e -Tail 20
#>
function Get-WinMeshProcess {
    [CmdletBinding(DefaultParameterSetName = 'Process')]
    param(
        [Parameter(Mandatory, Position = 0)] [string]$Name,
        [Parameter(Mandatory, Position = 1, ParameterSetName = 'Process')] [object]$Process,
        [Parameter(Mandatory, Position = 1, ParameterSetName = 'RunId')] [string]$RunId,
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

    $byRunId = ''
    if ($PSCmdlet.ParameterSetName -eq 'RunId') {
        if ($RunId -notmatch '^[0-9a-fA-F]{4,64}$') {
            throw "RunId '$RunId' does not look like one: Start-WinMeshProcess returns twelve hex characters."
        }
        $byRunId = $RunId
        $ProcessId = 0
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
        $ProcessId, $StartUtc, $DonePath, $StdoutPath, $Tail, $byRunId
    ) -ScriptBlock {
        param($procId, $startUtc, $donePath, $outPath, $tail, $runId)

        # Asked by run id: recover the pid and the paths from what the job left
        # beside itself. The meta file is written at launch, the pid file by the
        # job's own first act, so the pid file wins where they disagree.
        if ($runId) {
            $base = Join-Path ([IO.Path]::GetTempPath()) "winmesh-$runId"
            $metaPath = "$base.meta"
            if (-not (Test-Path -LiteralPath $metaPath -PathType Leaf)) {
                throw "no job with run id '$runId' on this machine: $metaPath does not exist. The temp directory may have been cleaned, or the job ran as a different user."
            }
            foreach ($line in [IO.File]::ReadAllLines($metaPath)) {
                $kv = "$line".Split('=', 2)
                if ($kv.Count -ne 2) { continue }
                switch ($kv[0]) {
                    'pid'   { $n = 0; if ([int]::TryParse($kv[1], [ref]$n)) { $procId = $n } }
                    'out'   { $outPath = $kv[1] }
                    'done'  { $donePath = $kv[1] }
                    'start' { if ($kv[1]) { $startUtc = [datetime]::Parse($kv[1], [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind) } }
                }
            }
            $pidPath = "$base.pid"
            if (Test-Path -LiteralPath $pidPath -PathType Leaf) {
                $n = 0
                if ([int]::TryParse(([IO.File]::ReadAllText($pidPath)).Trim(), [ref]$n) -and $n -gt 0) { $procId = $n }
            }
        }

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
            ProcessId    = $procId
            DonePath     = $donePath
            StdoutPath   = $outPath
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
        RunId        = $byRunId
        ProcessId    = $r.ProcessId
        Alive        = $r.Alive
        Finished     = $r.Finished
        ExitCode     = $r.ExitCode
        Reason       = $r.Reason
        StdoutPath   = $r.StdoutPath
        StdoutBytes  = $r.StdoutBytes
        LastWriteUtc = $r.LastWriteUtc
        Tail         = $r.Tail
    }
}
