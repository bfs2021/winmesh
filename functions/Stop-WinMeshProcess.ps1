<#
.SYNOPSIS
    Stops a detached process started by Start-WinMeshProcess.
.DESCRIPTION
    Stopping a job by hand is one line - Stop-Process through
    Invoke-WinMeshCommand - and that line gets two things silently wrong. A pid
    is recycled, so the line can kill an unrelated process that now holds it;
    and on a Unix target the job is its own session, so killing one pid leaves
    its children running. This does the identification first and kills the right
    thing second.

    What it refuses to do matters more than what it does:

      * a pid whose recorded start time does not match the process holding it
        now is NOT killed, and -Force does not override that. It is a different
        process, and the caller who really means to kill it can say so
        explicitly with Invoke-WinMeshCommand { Stop-Process };
      * a pid that is alive but whose start time could not be read is killed
        only with -Force, because "probably the right process" is not a reason
        to kill something on a shared machine;
      * a job that already finished is not an error: nothing is stopped and the
        result says so.

    How the kill is done differs per platform, and the difference is real rather
    than cosmetic:

      * Windows - `taskkill /T /F`, which takes the job and the process tree
        still attached to it. A child that was reparented (its own parent exited
        first) is no longer in that tree and survives; that is a limit, not a
        bug to work around here.
      * Linux/macOS - SIGTERM to the job's process group, read from `ps` at stop
        time rather than assumed, then SIGKILL to the same group if it is still
        there after a short grace window. The result says which signal ended it.

    The completion file is deliberately left alone: a stopped job genuinely has
    no exit code, and pretending otherwise would make "stopped" indistinguishable
    from "finished". Instead a stop record is written next to it, so a later
    Get-WinMeshProcess can say "stopped at <time>" rather than "killed or died".

    ssh transport only.
.PARAMETER Name
    Machine name from the config.
.PARAMETER Process
    The object Start-WinMeshProcess returned.
.PARAMETER RunId
    That object's RunId - the form that works after the session which started
    the job is gone.
.PARAMETER Force
    Kill a live process whose start time could not be read. It does not, and
    cannot, override a start time that was read and did not match.
.EXAMPLE
    Stop-WinMeshProcess workstation-01 -RunId 7f3a19c2b40e
.EXAMPLE
    Stop-WinMeshProcess workstation-01 -Process $job -WhatIf
#>
function Stop-WinMeshProcess {
    [CmdletBinding(SupportsShouldProcess = $true, DefaultParameterSetName = 'Process')]
    param(
        [Parameter(Mandatory, Position = 0)] [string]$Name,
        [Parameter(Mandatory, Position = 1, ParameterSetName = 'Process')] [object]$Process,
        [Parameter(Mandatory, Position = 1, ParameterSetName = 'RunId')] [string]$RunId,
        [Parameter(Mandatory, ParameterSetName = 'Explicit')] [int]$ProcessId,
        [Parameter(ParameterSetName = 'Explicit')] [object]$StartUtc,
        [Parameter(ParameterSetName = 'Explicit')] [string]$DonePath,
        [Parameter(ParameterSetName = 'Explicit')] [string]$StdoutPath,
        [int]$GraceSeconds = 5,
        [switch]$Force,
        [object]$Config
    )

    if (-not $Config) { $Config = Get-WinMeshConfig }
    $h = $Config.Hosts[$Name]
    if (-not $h) { throw "Host '$Name' is not in config $($Config.Path)." }
    if ($h.Transport -ne 'ssh') {
        throw "Host '$Name' uses the '$($h.Transport)' transport. Stop-WinMeshProcess is ssh only."
    }

    # Identify first, through the command that already does it: one place knows
    # how to resolve a run id, read the pid file and compare start times.
    $ask = @{ Name = $Name; Config = $Config }
    switch ($PSCmdlet.ParameterSetName) {
        'Process' { $ask['Process'] = $Process }
        'RunId'   { $ask['RunId']   = $RunId }
        'Explicit' {
            $ask['ProcessId'] = $ProcessId
            if ($StartUtc)   { $ask['StartUtc']   = $StartUtc }
            if ($DonePath)   { $ask['DonePath']   = $DonePath }
            if ($StdoutPath) { $ask['StdoutPath'] = $StdoutPath }
        }
    }
    $state = Get-WinMeshProcess @ask

    $result = [pscustomobject]@{
        Host      = $Name
        RunId     = $state.RunId
        ProcessId = $state.ProcessId
        WasAlive  = [bool]$state.Alive
        Stopped   = $false
        Method    = ''
        Finished  = [bool]$state.Finished
        ExitCode  = $state.ExitCode
        Reason    = ''
    }

    if ($state.Reason -match 'different process') {
        throw "winmesh($Name): pid $($state.ProcessId) is not this job any more - $($state.Reason). Refusing to kill it, and -Force does not change that. If you do mean that process, say so: Invoke-WinMeshCommand $Name { Stop-Process -Id $($state.ProcessId) -Force }."
    }

    if (-not $state.Alive) {
        $result.Reason = if ($state.Finished) { "already finished with exit code $($state.ExitCode)" }
                         elseif ($state.Reason) { $state.Reason }
                         else { 'not running' }
        $result.Method = 'nothing to stop'
        return $result
    }

    if ($state.Reason -match 'start times could not be compared' -and -not $Force) {
        throw "winmesh($Name): pid $($state.ProcessId) is alive but its start time could not be read, so this may not be the job. Pass -Force to kill it anyway."
    }

    if (-not $PSCmdlet.ShouldProcess("$Name pid $($state.ProcessId)", 'stop the detached process')) {
        $result.Method = 'not stopped (-WhatIf)'
        return $result
    }

    $stoppedPath = if ($state.DonePath) { [regex]::Replace("$($state.DonePath)", '\.done$', '.stopped') } else { '' }

    $killed = Invoke-WinMeshSsh -HostEntry $h -Defaults $Config.Defaults -ArgumentList @(
        $state.ProcessId, $stoppedPath, $GraceSeconds
    ) -ScriptBlock {
        param($procId, $stoppedPath, $grace)

        $win = $env:OS -eq 'Windows_NT'
        function Test-Live($id) {
            try { $null = Get-Process -Id $id -ErrorAction Stop; $true } catch { $false }
        }
        function Wait-Gone($id, $seconds) {
            $waited = 0
            while ($waited -lt ($seconds * 1000) -and (Test-Live $id)) {
                Start-Sleep -Milliseconds 200
                $waited += 200
            }
            -not (Test-Live $id)
        }

        if (-not (Test-Live $procId)) {
            return [pscustomobject]@{ Stopped = $false; Method = 'already gone'; Detail = '' }
        }

        $method = ''
        $detail = ''
        if ($win) {
            # /T takes the tree still attached to this process; /F does not ask.
            $out = & taskkill /PID $procId /T /F 2>&1
            $detail = (@($out) -join '; ')
            $method = 'taskkill /T /F'
            $gone = Wait-Gone $procId $grace
        } else {
            # Read the process group rather than assuming it equals the pid:
            # setsid gives the job its own group only when it did not fork.
            $pgid = ''
            try { $pgid = ("$(& ps -o pgid= -p $procId 2>$null)").Trim() } catch { $pgid = '' }
            if ($pgid -match '^\d+$' -and [int]$pgid -gt 1) {
                $target = "-$pgid"
                $method = "SIGTERM to process group $pgid"
            } else {
                $target = "$procId"
                $method = 'SIGTERM to the pid (process group could not be read)'
                $detail = 'ps gave no usable pgid'
            }
            & /bin/sh -c "kill -TERM $target" 2>&1 | Out-Null
            $gone = Wait-Gone $procId $grace
            if (-not $gone) {
                & /bin/sh -c "kill -KILL $target" 2>&1 | Out-Null
                $method += ", then SIGKILL after ${grace}s"
                $gone = Wait-Gone $procId 3
            }
        }

        # Not a completion record: a stopped job has no exit code, and writing
        # one would make it indistinguishable from a job that finished. This is
        # only so a later query can say "stopped" instead of "killed or died".
        if ($gone -and $stoppedPath) {
            try {
                [IO.File]::WriteAllText($stoppedPath,
                    "stopped=$((Get-Date).ToUniversalTime().ToString('o'))`nmethod=$method")
            } catch { }
        }

        [pscustomobject]@{ Stopped = $gone; Method = $method; Detail = $detail }
    }

    $result.Stopped = [bool]$killed.Stopped
    $result.Method  = "$($killed.Method)"
    $result.Reason  = if ($killed.Stopped) { '' }
                      elseif ($killed.Method -eq 'already gone') { 'it ended between the two calls' }
                      else { "still alive after $($killed.Method)$(if ($killed.Detail) { ": $($killed.Detail)" })" }
    $result
}
