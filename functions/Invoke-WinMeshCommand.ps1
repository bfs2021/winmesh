<#
.SYNOPSIS
    Runs a command on a fleet machine by its config name.
.DESCRIPTION
    Resolves the address and credentials from the config and calls Invoke-Command.
    Replaces the manual "import cred + remember the IP" with "name the machine".

    Hosts with Transport = 'ssh' go through the ssh transport instead. Either way
    the return value is real objects, not text.
.PARAMETER Name
    Machine name from the config.
.PARAMETER ScriptBlock
    What to run on the other side.
.PARAMETER ArgumentList
    Arguments passed into the ScriptBlock (via param in the block).
.PARAMETER ThrowOnNativeExit
    Throw locally when the last native command in the ScriptBlock exited with a
    non-zero code. Without it such a failure is silent: PowerShell does not turn
    a non-zero exit into a terminating error, so a failed build or push returns
    like a success. ssh transport only — see the note in the code below.

    It is the exit code of the *last* native command, not "did anything fail":
    `cmd /c "exit 7"; cmd /c "exit 0"` leaves 0. A block that ran no native
    command at all never throws.
.EXAMPLE
    Invoke-WinMeshCommand workstation-01 { hostname; whoami }
.EXAMPLE
    Invoke-WinMeshCommand workstation-01 { param($p) Test-Path $p } -ArgumentList 'C:\Windows'
.EXAMPLE
    Invoke-WinMeshCommand workstation-01 { ninja -C build } -ThrowOnNativeExit
#>
function Invoke-WinMeshCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)] [string]$Name,
        [Parameter(Mandatory, Position = 1)] [scriptblock]$ScriptBlock,
        [object[]]$ArgumentList,
        [object]$Config,
        [switch]$ThrowOnNativeExit
    )

    if (-not $Config) { $Config = Get-WinMeshConfig }
    $h = $Config.Hosts[$Name]
    if (-not $h) { throw "Host '$Name' is not in config $($Config.Path)." }

    if ($h.Transport -eq 'ssh') {
        return Invoke-WinMeshSsh -HostEntry $h -Defaults $Config.Defaults `
            -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList `
            -ThrowOnNativeExit:$ThrowOnNativeExit
    }

    # Deliberately ssh-only. The ssh transport already recreates the scriptblock
    # from its text on the far side, so reading $LASTEXITCODE after the call costs
    # nothing. The WinRM path hands the caller's scriptblock straight to
    # Invoke-Command, which is what makes $using: work there; wrapping it to read
    # the exit code would take $using: away. Refusing is better than a switch
    # that silently does nothing.
    if ($ThrowOnNativeExit) {
        throw "Host '$Name' uses the WinRM transport, where -ThrowOnNativeExit is not supported (it would remove `$using: support). Check the exit code inside the scriptblock instead: if (`$LASTEXITCODE) { throw }."
    }

    Assert-WinMeshWinRMController -What "Host '$Name' uses WinRM, which"
    $cred = Get-WinMeshCredential -Id $h.Credential -Store $Config.Defaults.CredentialStore

    $params = @{
        ComputerName = $h.Address
        Credential   = $cred
        ScriptBlock  = $ScriptBlock
        ErrorAction  = 'Stop'
    }
    if ($ArgumentList) { $params.ArgumentList = $ArgumentList }

    Invoke-Command @params
}
