<#
.SYNOPSIS
    SSH transport internals — not exported.
.DESCRIPTION
    Runs a scriptblock on a target over `ssh` and brings real objects back,
    keeping the same contract as the WinRM path (Invoke-Command returns objects,
    not text).

    Three problems have to be solved to make text-only SSH behave like remoting;
    each is handled below, and each is a gotcha in its own right:

      1. Quoting. The remote shell behind Windows OpenSSH is cmd.exe by default,
         but may be PowerShell if DefaultShell was changed. Nothing that survives
         both reliably can be written by hand. So the payload travels as a single
         base64 token in `powershell -EncodedCommand`, which both shells pass
         through untouched. The same holds for sh/bash/zsh on a Linux or macOS
         target (`pwsh -EncodedCommand`): base64 has no character they treat
         specially.
      2. Encoding. -EncodedCommand expects base64 of UTF-16LE, not UTF-8. Encode
         the payload as UTF-8 and PowerShell reads garbage or refuses to parse.
      3. Objects. The channel carries text, so the result is serialized on the
         far side with PSSerializer (the CliXml engine remoting itself uses) and
         rehydrated here. ConvertTo-CliXml does not exist in Windows PowerShell
         5.1 — PSSerializer does, in both 5.1 and 7.

    Arguments and the scriptblock body are themselves base64 inside the payload,
    so no quoting of user content is ever needed.

      4. Exit codes. A scriptblock whose native command fails still returns
         normally: PowerShell does not turn a non-zero exit into a terminating
         error, and the code does not cross the channel. So the payload reads
         `$LASTEXITCODE` right after the call and sends it on its own marker line;
         -ThrowOnNativeExit turns a non-zero value into a local exception.
#>

# Marker lines the remote payload prints. Anything else the remote writes
# (Write-Host, native command output) is passed through to the caller's host.
$script:WinMeshSshOk  = '@@WINMESH-OK@@'
$script:WinMeshSshErr = '@@WINMESH-ERR@@'
# Carries $LASTEXITCODE of the scriptblock back to the controller. A separate
# line, not a field in the result, so the serialized result stays byte-for-byte
# what it was before this existed. Emitted on the success path only: after a
# terminating error $LASTEXITCODE belongs to whatever ran before the throw.
$script:WinMeshSshXc  = '@@WINMESH-XC@@'

function ConvertTo-WinMeshB64 {
    param([Parameter(Mandatory)] [AllowEmptyString()] [string]$Text)
    [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Text))
}

function ConvertFrom-WinMeshB64 {
    param([Parameter(Mandatory)] [string]$B64)
    [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($B64))
}

# Builds the script that will run on the target.
function New-WinMeshSshPayload {
    param(
        [Parameter(Mandatory)] [scriptblock]$ScriptBlock,
        [object[]]$ArgumentList
    )

    $sbB64   = ConvertTo-WinMeshB64 -Text $ScriptBlock.ToString()
    # No args must mean no positional argument, not an explicit $null (that would
    # override a scriptblock's defaulted parameter). Normalise null to an empty list.
    # The outer @() matters: an `if` expression unrolls its output, so a single
    # argument would arrive as a bare string — and splatting a string on the far
    # side passes its first character only.
    $argList = @(if ($null -ne $ArgumentList) { $ArgumentList })
    $argsB64 = ConvertTo-WinMeshB64 -Text ([System.Management.Automation.PSSerializer]::Serialize($argList))

    @"
`$ErrorActionPreference = 'Stop'
try {
    `$__args = [System.Management.Automation.PSSerializer]::Deserialize(
        [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$argsB64')))
    `$__sb = [scriptblock]::Create(
        [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$sbB64')))
    `$__r = & `$__sb @__args
    # Read it on the very next line: any command run in between overwrites it.
    `$__xc = `$LASTEXITCODE
    `$__x = [System.Management.Automation.PSSerializer]::Serialize(`$__r)
    [Console]::Out.WriteLine('$($script:WinMeshSshXc)' + "`$__xc")
    [Console]::Out.WriteLine('$($script:WinMeshSshOk)' +
        [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(`$__x)))
} catch {
    `$__x = [System.Management.Automation.PSSerializer]::Serialize(`$_.ToString())
    [Console]::Out.WriteLine('$($script:WinMeshSshErr)' +
        [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(`$__x)))
}
"@
}

# Resolves one host's ssh settings against the defaults. Shared by the ssh and
# scp argument builders so the two can never drift apart: a file copied to a host
# must go over the same port, as the same user, with the same options as a
# command run on it.
function Get-WinMeshSshSetting {
    param(
        [Parameter(Mandatory)] $HostEntry,
        [Parameter(Mandatory)] $Defaults
    )

    $port    = if ($HostEntry.SshPort)    { $HostEntry.SshPort }    else { $Defaults.SshPort }
    $user    = if ($HostEntry.SshUser)    { $HostEntry.SshUser }    else { $Defaults.SshUser }
    $shell   = if ($HostEntry.SshShell)   { $HostEntry.SshShell }   else { $Defaults.SshShell }
    $timeout = if ($HostEntry.SshTimeout) { $HostEntry.SshTimeout } else { $Defaults.SshTimeout }
    # A host's SshOptions replace the defaults rather than add to them, which is
    # why a host with its own key lists IdentityFile itself. An empty list is a
    # deliberate "inject nothing", so test for $null, not for emptiness.
    $extra   = @(if ($null -ne $HostEntry.SshOptions) { $HostEntry.SshOptions } else { $Defaults.SshOptions })

    [pscustomobject]@{
        Port    = $port
        User    = $user
        Shell   = $shell
        Timeout = $timeout
        Options = $extra
        # With no user the target is the bare address, so an entry whose Address
        # is a Host block in ~/.ssh/config keeps that block's own User.
        Target  = if ($user) { "$user@$($HostEntry.Address)" } else { "$($HostEntry.Address)" }
    }
}

# Assembles the ssh argument vector for one host entry.
function New-WinMeshSshArgs {
    param(
        [Parameter(Mandatory)] $HostEntry,
        [Parameter(Mandatory)] $Defaults,
        [Parameter(Mandatory)] [string]$RemoteCommand
    )

    $s = Get-WinMeshSshSetting -HostEntry $HostEntry -Defaults $Defaults

    $a = @('-o', 'BatchMode=yes', '-o', "ConnectTimeout=$($s.Timeout)")
    if ($s.Port -and $s.Port -ne 22) { $a += @('-p', "$($s.Port)") }
    foreach ($o in $s.Options) { if ($o) { $a += @('-o', "$o") } }
    $a += $s.Target
    $a += "$($s.Shell) -NoProfile -NonInteractive -EncodedCommand $RemoteCommand"
    , $a
}

# Assembles the scp argument vector. Same settings, different flag for the port:
# scp spells it -P, ssh spells it -p. They are not interchangeable and the
# mistake is silent until the connection is refused.
function New-WinMeshScpArgs {
    param(
        [Parameter(Mandatory)] $HostEntry,
        [Parameter(Mandatory)] $Defaults,
        [Parameter(Mandatory)] [string]$Source,
        [Parameter(Mandatory)] [string]$Destination,
        [switch]$Recurse
    )

    $s = Get-WinMeshSshSetting -HostEntry $HostEntry -Defaults $Defaults

    $a = @('-o', 'BatchMode=yes', '-o', "ConnectTimeout=$($s.Timeout)")
    if ($s.Port -and $s.Port -ne 22) { $a += @('-P', "$($s.Port)") }
    foreach ($o in $s.Options) { if ($o) { $a += @('-o', "$o") } }
    if ($Recurse) { $a += '-r' }
    $a += @($Source, $Destination)
    , $a
}

# Runs a scriptblock on a host over ssh and returns the deserialized result.
function Invoke-WinMeshSsh {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $HostEntry,
        [Parameter(Mandatory)] $Defaults,
        [Parameter(Mandatory)] [scriptblock]$ScriptBlock,
        [object[]]$ArgumentList,
        [switch]$ThrowOnNativeExit
    )

    $payload = New-WinMeshSshPayload -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList
    # -EncodedCommand takes base64 of UTF-16LE. This is the step that is easy to get wrong.
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($payload))
    $sshArgs = New-WinMeshSshArgs -HostEntry $HostEntry -Defaults $Defaults -RemoteCommand $encoded

    Write-Verbose "ssh $($sshArgs -join ' ')"

    # A native command writing to stderr must not become a terminating error here —
    # ssh uses stderr for ordinary notices, and we need its exit code instead.
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $raw = & ssh @sshArgs 2>&1
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prevEap
    }

    $marker   = $null
    $exitText = $null
    $noise    = New-Object System.Collections.Generic.List[string]
    foreach ($line in @($raw)) {
        $text = "$line"
        if ($text.StartsWith($script:WinMeshSshOk) -or $text.StartsWith($script:WinMeshSshErr)) {
            $marker = $text
        } elseif ($text.StartsWith($script:WinMeshSshXc)) {
            # Empty when no native command ran: $LASTEXITCODE was $null there.
            $exitText = $text.Substring($script:WinMeshSshXc.Length).Trim()
        } elseif ($text.Trim()) {
            $noise.Add($text)
        }
    }

    if (-not $marker) {
        $detail = if ($noise.Count) { ($noise -join '; ') } else { "ssh exited with code $code" }
        # The remote shell could not start PowerShell at all: 127 is "command not
        # found" in sh/bash/zsh, 9009 in cmd.exe. Name the fix — the default
        # SshShell 'powershell' does not exist on Linux/macOS, and a non-interactive
        # ssh session skips login profiles, so its PATH can miss a pwsh that an
        # interactive terminal finds (macOS in particular).
        if ($code -in @(127, 9009) -or $detail -match 'command not found|is not recognized') {
            $detail += " — PowerShell was not found on the target. Set SshShell for this host: 'pwsh' on Linux/macOS, or its full path (run 'command -v pwsh' on the target) if the ssh session's PATH misses it."
        }
        throw "winmesh(ssh) $($HostEntry.Address): no response from the target — $detail"
    }

    # Remote output that was not the result (Write-Host, native stdout) is not
    # swallowed: it goes to the host stream, as it would under WinRM.
    foreach ($n in $noise) { Write-Host $n }

    if ($marker.StartsWith($script:WinMeshSshErr)) {
        $msg = [System.Management.Automation.PSSerializer]::Deserialize(
            (ConvertFrom-WinMeshB64 -B64 $marker.Substring($script:WinMeshSshErr.Length)))
        throw "winmesh(ssh) $($HostEntry.Address): $msg"
    }

    # The exit code of the *last* native command in the scriptblock, and only
    # that: `cmd /c "exit 7"` followed by `cmd /c "exit 0"` leaves 0. A caller
    # that needs per-command strictness writes the check into its own block.
    $nativeExit = $null
    if ($exitText) {
        $parsed = 0
        if ([int]::TryParse($exitText, [ref]$parsed)) { $nativeExit = $parsed }
    }
    if ($ThrowOnNativeExit -and $null -ne $nativeExit -and $nativeExit -ne 0) {
        throw "winmesh(ssh) $($HostEntry.Address): the last native command in the scriptblock exited with code $nativeExit."
    }

    [System.Management.Automation.PSSerializer]::Deserialize(
        (ConvertFrom-WinMeshB64 -B64 $marker.Substring($script:WinMeshSshOk.Length)))
}

# TCP reachability without Test-NetConnection (Windows-only) — and it reads the
# banner, which tells you *which* SSH server answered. On an overlay network that
# matters: NetBird ships its own SSH server and it may be the one on port 22,
# not the Windows OpenSSH service you think you configured.
function Test-WinMeshSshPort {
    param(
        [Parameter(Mandatory)] [string]$Address,
        [int]$Port = 22,
        [int]$TimeoutMs = 5000
    )

    $result = [pscustomobject]@{ Ok = $false; Banner = ''; Detail = '' }
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        if (-not $client.ConnectAsync($Address, $Port).Wait($TimeoutMs)) {
            $result.Detail = 'no connection'
            return $result
        }
        $result.Ok = $true
        $stream = $client.GetStream()
        $stream.ReadTimeout = $TimeoutMs
        $buffer = New-Object byte[] 255
        $read = $stream.Read($buffer, 0, $buffer.Length)
        if ($read -gt 0) {
            $result.Banner = ([Text.Encoding]::ASCII.GetString($buffer, 0, $read)).Trim()
        }
        $result.Detail = if ($result.Banner) { $result.Banner } else { "${Address}:$Port" }
    } catch {
        $result.Detail = ($_.Exception.Message -split "`n")[0]
    } finally {
        $client.Dispose()
    }
    $result
}
