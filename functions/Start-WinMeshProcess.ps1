<#
.SYNOPSIS
    Starts a scriptblock on a fleet machine and returns immediately, leaving it
    running after the ssh session closes.
.DESCRIPTION
    Invoke-WinMeshCommand is one shot: the command lives and dies with the
    connection and nothing comes back until it ends, so a long build or a
    multi-hour measurement cannot be run through it at all.

    This starts the work detached and hands back what is needed to ask about it
    later: the process id on the target, the file its output goes to, and the
    file that will hold its exit code. Get-WinMeshProcess answers "is it still
    running, and how did it end".

    How detaching is done, and why:

      * Windows target - the process is created through WMI
        (Win32_Process.Create). A process started from inside the ssh session
        with Start-Process is a child of that session and is killed with it;
        the WMI-created process is not.
      * Linux/macOS target - `setsid nohup ... </dev/null >/dev/null 2>&1 &`,
        which puts the work in its own session so the SIGHUP that follows the
        closing connection does not reach it.

    Completion is proven by an artifact, never by elapsed time: the wrapper's
    last act is to write the exit code to the done file. A process that is gone
    with no done file died rather than finished, and that is reported as such -
    a state the one-shot path cannot even express.

    ssh transport only. The WinRM path has no equivalent here and refuses with
    that message rather than pretending.
.PARAMETER Name
    Machine name from the config.
.PARAMETER ScriptBlock
    What to run on the other side. It runs in a fresh PowerShell process on the
    target, not in the ssh session, so it cannot see anything from the caller
    except ArgumentList.
.PARAMETER ArgumentList
    Arguments passed into the ScriptBlock (via param in the block).
.PARAMETER WorkingDirectory
    Directory to start in on the target. A Windows drive letter that is a mapping
    rather than a real volume is worth checking once: mappings can belong to a
    logon session, and the detached process is created by the WMI service rather
    than inside the ssh session. On the Windows target used to verify this, a
    mapped Z:\ did resolve; that is one target, not a rule. If it does not,
    Win32_Process.Create reports it (the error below names the code) or the job
    starts somewhere else, which `{ (Get-Location).Path }` will tell you.
.PARAMETER StdoutPath
    Where the output goes on the target. Default: next to the generated scripts
    in the target's temp directory.
.EXAMPLE
    $job = Start-WinMeshProcess workstation-01 { ninja -C C:/src/build }
    Get-WinMeshProcess workstation-01 -Process $job -Tail 20
#>
function Start-WinMeshProcess {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory, Position = 0)] [string]$Name,
        [Parameter(Mandatory, Position = 1)] [scriptblock]$ScriptBlock,
        [object[]]$ArgumentList,
        [string]$WorkingDirectory,
        [string]$StdoutPath,
        [object]$Config
    )

    if (-not $Config) { $Config = Get-WinMeshConfig }
    $h = $Config.Hosts[$Name]
    if (-not $h) { throw "Host '$Name' is not in config $($Config.Path)." }
    if ($h.Transport -ne 'ssh') {
        throw "Host '$Name' uses the '$($h.Transport)' transport. Start-WinMeshProcess is ssh only."
    }
    if (-not $PSCmdlet.ShouldProcess($Name, "start a detached process")) { return }

    $s = Get-WinMeshSshSetting -HostEntry $h -Defaults $Config.Defaults

    # A run id from here, not from the target: the target may have no usable
    # random source in a non-interactive session, and one id must identify one
    # run in the file names on both sides.
    $runId = ([guid]::NewGuid()).ToString('N').Substring(0, 12)

    # The arguments are serialized here and deserialized by the wrapper on the
    # far side, the same round trip the command path uses.
    $argsXml = [System.Management.Automation.PSSerializer]::Serialize(
        @(if ($null -ne $ArgumentList) { $ArgumentList }))

    $started = Invoke-WinMeshSsh -HostEntry $h -Defaults $Config.Defaults -ArgumentList @(
        $runId, $ScriptBlock.ToString(), $argsXml, $WorkingDirectory, $StdoutPath, $s.Shell
    ) -ScriptBlock {
        param($runId, $bodyText, $argsXml, $workDir, $outPath, $shell)

        $win = $env:OS -eq 'Windows_NT'
        $tmp = [IO.Path]::GetTempPath()
        $base = Join-Path $tmp "winmesh-$runId"

        $userPath = "$base.user.ps1"
        $argsPath = "$base.args.xml"
        $donePath = "$base.done"
        $wrapPath = "$base.wrapper.ps1"
        if (-not $outPath) { $outPath = "$base.out" }

        [IO.File]::WriteAllText($userPath, $bodyText)
        [IO.File]::WriteAllText($argsPath, $argsXml)

        # The wrapper is built from a single-quoted template and the paths are
        # substituted in, so nothing in a path is interpreted as PowerShell.
        $tpl = @'
$ErrorActionPreference = 'Continue'
$u = '__USER__'
$a = '__ARGS__'
$o = '__OUT__'
$d = '__DONE__'
$p = '__PID__'
# First act: say which process this is. On a Unix target the launching shell
# reports the pid of `setsid`, which is only the same process when setsid was
# able to call setsid(2) without forking. This file is the job's own answer.
try { [IO.File]::WriteAllText($p, "$PID") } catch { }
$code = 0
try {
    $sb = [scriptblock]::Create([IO.File]::ReadAllText($u))
    $al = @([System.Management.Automation.PSSerializer]::Deserialize([IO.File]::ReadAllText($a)))
    & $sb @al *> $o
    if ($null -ne $LASTEXITCODE) { $code = $LASTEXITCODE }
} catch {
    ($_ | Out-String) | Add-Content -LiteralPath $o
    $code = 1
}
# Last act, and the only proof of completion the caller has.
[IO.File]::WriteAllText($d, "$code")
'@
        $q = {
            param($p)
            "$p".Replace("'", "''")
        }
        $pidPath = "$base.pid"
        $wrapper = $tpl.Replace('__USER__', (& $q $userPath)).
                        Replace('__ARGS__', (& $q $argsPath)).
                        Replace('__OUT__',  (& $q $outPath)).
                        Replace('__DONE__', (& $q $donePath)).
                        Replace('__PID__',  (& $q $pidPath))

        $procId = 0
        if ($win) {
            # -EncodedCommand rather than -File: no execution policy to satisfy
            # and no quoting of the path on a WMI command line.
            $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($wrapper))
            $cmdLine = "$shell -NoProfile -NonInteractive -EncodedCommand $enc"
            $cimArgs = @{ CommandLine = $cmdLine }
            if ($workDir) { $cimArgs['CurrentDirectory'] = $workDir }
            $r = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments $cimArgs
            if ($r.ReturnValue -ne 0) {
                throw "Win32_Process.Create returned $($r.ReturnValue) (2 = access denied, 3 = insufficient privilege, 9 = path not found, 21 = invalid parameter; a CurrentDirectory on a mapped drive letter shows up here)."
            }
            $procId = [int]$r.ProcessId
        } else {
            [IO.File]::WriteAllText($wrapPath, $wrapper)
            $cd = if ($workDir) { "cd '" + ("$workDir".Replace("'", "'\''")) + "' && " } else { '' }
            # echo of the shell's last background pid, kept out of PowerShell's
            # way by building the string rather than interpolating it.
            $launch = $cd + "setsid nohup '" + $shell + "' -NoProfile -NonInteractive -File '" + $wrapPath + "' </dev/null >/dev/null 2>&1 & echo " + '$!'
            $pidText = & /bin/sh -c $launch
            $procId = [int](@($pidText)[0])
            # Prefer the job's own answer when it arrives: see the note in the
            # wrapper. Short wait, because this is the one moment the two values
            # can be compared at all.
            $waited = 0
            while ($waited -lt 3000 -and -not (Test-Path -LiteralPath $pidPath -PathType Leaf)) {
                Start-Sleep -Milliseconds 100
                $waited += 100
            }
            if (Test-Path -LiteralPath $pidPath -PathType Leaf) {
                $own = 0
                if ([int]::TryParse(([IO.File]::ReadAllText($pidPath)).Trim(), [ref]$own) -and $own -gt 0) {
                    $procId = $own
                }
            }
        }

        # The process's own start time, read right away. Compared later against
        # the live process so a recycled pid is not mistaken for this run.
        $startUtc = $null
        try {
            $p = Get-Process -Id $procId -ErrorAction Stop
            $startUtc = $p.StartTime.ToUniversalTime()
        } catch {
            # Already finished, or not readable. Then the done file is the only
            # evidence, which is what Get-WinMeshProcess falls back to.
        }

        [pscustomobject]@{
            ProcessId    = $procId
            StartUtc     = $startUtc
            StdoutPath   = $outPath
            DonePath     = $donePath
            ScriptPath   = $userPath
            Os           = if ($win) { 'Windows' } else { 'Unix' }
        }
    }

    [pscustomobject]@{
        Host        = $Name
        ProcessId   = $started.ProcessId
        StartUtc    = $started.StartUtc
        StdoutPath  = $started.StdoutPath
        DonePath    = $started.DonePath
        ScriptPath  = $started.ScriptPath
        Os          = $started.Os
    }
}
