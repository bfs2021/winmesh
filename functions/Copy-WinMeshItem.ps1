<#
.SYNOPSIS
    Copies a file to or from a fleet machine by its config name.
.DESCRIPTION
    The module resolves a host name to an address, port, user and key for running
    a command; this does the same for moving a file, so the caller never rebuilds
    `scp -P <port> -i <key> <user>@<address>:<path>` by hand.

    Over ssh the copy is `scp` with the same settings the command path uses
    (shared through Get-WinMeshSshSetting). Over WinRM it is a PSSession plus
    Copy-Item -ToSession/-FromSession, so the same call works on both transports.

    The copy is verified by reading the size back from the destination, not by
    trusting the exit code: a transfer that dies in the middle leaves a partial
    file behind, and scp has been seen to report success on one (see Gotchas in
    README.md). A size mismatch is an error, not a warning.
.PARAMETER Name
    Machine name from the config.
.PARAMETER Path
    The source. A local path when copying to the host, a path on the host when
    copying from it.
.PARAMETER Destination
    The destination, local or remote in the same way. A directory is accepted:
    the leaf name of Path is appended, as every copy tool does.
.PARAMETER FromHost
    Copy from the machine to here instead of to it.
.PARAMETER Recurse
    Copy a directory. The size check is skipped: it compares one file's length,
    and comparing a tree is a different job with different failure modes.
.EXAMPLE
    Copy-WinMeshItem workstation-01 .\report.csv 'C:/Temp/'
.EXAMPLE
    Copy-WinMeshItem workstation-01 'C:/Temp/log.txt' .\ -FromHost
#>
function Copy-WinMeshItem {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory, Position = 0)] [string]$Name,
        [Parameter(Mandatory, Position = 1)] [string]$Path,
        [Parameter(Mandatory, Position = 2)] [string]$Destination,
        [switch]$FromHost,
        [switch]$Recurse,
        [object]$Config
    )

    if (-not $Config) { $Config = Get-WinMeshConfig }
    $h = $Config.Hosts[$Name]
    if (-not $h) { throw "Host '$Name' is not in config $($Config.Path)." }

    $direction = if ($FromHost) { 'FromHost' } else { 'ToHost' }
    $action    = if ($FromHost) { "copy '$Path' from the host to '$Destination'" }
                 else           { "copy '$Path' to the host at '$Destination'" }
    if (-not $PSCmdlet.ShouldProcess($Name, $action)) { return }

    # The leaf name is needed on the far side to resolve "destination is a
    # directory". Split both ways: the local separator is not the remote one when
    # a Linux controller writes a Windows path.
    $leaf = ($Path -split '[\\/]')[-1]

    $result = [pscustomobject]@{
        Host        = $Name
        Direction   = $direction
        Path        = $Path
        Destination = $Destination
        Bytes       = $null
        Ok          = $false
    }

    if ($h.Transport -eq 'ssh') {
        if (-not (Get-Command scp -ErrorAction SilentlyContinue)) {
            throw "scp was not found on this controller. It ships with the OpenSSH client; winmesh does not bundle one."
        }

        $s      = Get-WinMeshSshSetting -HostEntry $h -Defaults $Config.Defaults
        $remote = if ($FromHost) { "$($s.Target):$Path" } else { "$($s.Target):$Destination" }
        $src    = if ($FromHost) { $remote } else { $Path }
        $dst    = if ($FromHost) { $Destination } else { $remote }

        # Source size first: it also proves the source exists before any transfer.
        $sourceBytes = $null
        if (-not $Recurse) {
            if ($FromHost) {
                $sourceBytes = Invoke-WinMeshSsh -HostEntry $h -Defaults $Config.Defaults -ArgumentList @($Path) -ScriptBlock {
                    param($p)
                    if (Test-Path -LiteralPath $p -PathType Leaf) { (Get-Item -LiteralPath $p).Length } else { $null }
                }
                if ($null -eq $sourceBytes) { throw "winmesh(scp) $($h.Address): '$Path' is not a file on the host." }
            } else {
                if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
                    throw "'$Path' is not a file on this controller. Use -Recurse for a directory."
                }
                $sourceBytes = (Get-Item -LiteralPath $Path).Length
            }
        }

        $scpArgs = New-WinMeshScpArgs -HostEntry $h -Defaults $Config.Defaults `
            -Source $src -Destination $dst -Recurse:$Recurse

        Write-Verbose "scp $($scpArgs -join ' ')"

        # scp writes ordinary notices to stderr; read the exit code, not the stream.
        $prevEap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $out  = & scp @scpArgs 2>&1
            $code = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $prevEap
        }
        if ($code -ne 0) {
            $detail = if ($out) { (@($out) -join '; ') } else { "scp exited with code $code" }
            throw "winmesh(scp) $($h.Address): $detail"
        }

        if ($Recurse) {
            $result.Ok = $true
            return $result
        }

        # Read the size back from the destination. This is the check that catches
        # a truncated transfer; the exit code above does not.
        if ($FromHost) {
            $final = if (Test-Path -LiteralPath $Destination -PathType Container) {
                Join-Path $Destination $leaf
            } else { $Destination }
            if (-not (Test-Path -LiteralPath $final -PathType Leaf)) {
                throw "winmesh(scp) $($h.Address): scp reported success but '$final' does not exist here."
            }
            $result.Bytes = (Get-Item -LiteralPath $final).Length
        } else {
            $result.Bytes = Invoke-WinMeshSsh -HostEntry $h -Defaults $Config.Defaults -ArgumentList @($Destination, $leaf) -ScriptBlock {
                param($d, $l)
                $p = if (Test-Path -LiteralPath $d -PathType Container) { Join-Path $d $l } else { $d }
                if (Test-Path -LiteralPath $p -PathType Leaf) { (Get-Item -LiteralPath $p).Length } else { $null }
            }
            if ($null -eq $result.Bytes) {
                throw "winmesh(scp) $($h.Address): scp reported success but no file is at '$Destination' on the host."
            }
        }

        if ($result.Bytes -ne $sourceBytes) {
            throw "winmesh(scp) $($h.Address): the destination is $($result.Bytes) bytes, the source is $sourceBytes. The copy is incomplete; the partial file was left in place."
        }
        $result.Ok = $true
        return $result
    }

    # --- WinRM ---
    Assert-WinMeshWinRMController -What "Host '$Name' uses WinRM, which"
    $cred = Get-WinMeshCredential -Id $h.Credential -Store $Config.Defaults.CredentialStore
    $session = New-PSSession -ComputerName $h.Address -Credential $cred -ErrorAction Stop
    try {
        $sourceBytes = $null
        if (-not $Recurse) {
            if ($FromHost) {
                $sourceBytes = Invoke-Command -Session $session -ArgumentList $Path -ScriptBlock {
                    param($p)
                    if (Test-Path -LiteralPath $p -PathType Leaf) { (Get-Item -LiteralPath $p).Length } else { $null }
                }
                if ($null -eq $sourceBytes) { throw "winmesh(winrm) $($h.Address): '$Path' is not a file on the host." }
            } else {
                if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
                    throw "'$Path' is not a file on this controller. Use -Recurse for a directory."
                }
                $sourceBytes = (Get-Item -LiteralPath $Path).Length
            }
        }

        $copy = @{ Path = $Path; Destination = $Destination; ErrorAction = 'Stop' }
        if ($Recurse) { $copy.Recurse = $true }
        if ($FromHost) { $copy.FromSession = $session } else { $copy.ToSession = $session }
        Copy-Item @copy

        if ($Recurse) {
            $result.Ok = $true
            return $result
        }

        if ($FromHost) {
            $final = if (Test-Path -LiteralPath $Destination -PathType Container) {
                Join-Path $Destination $leaf
            } else { $Destination }
            if (-not (Test-Path -LiteralPath $final -PathType Leaf)) {
                throw "winmesh(winrm) $($h.Address): the copy reported success but '$final' does not exist here."
            }
            $result.Bytes = (Get-Item -LiteralPath $final).Length
        } else {
            $result.Bytes = Invoke-Command -Session $session -ArgumentList $Destination, $leaf -ScriptBlock {
                param($d, $l)
                $p = if (Test-Path -LiteralPath $d -PathType Container) { Join-Path $d $l } else { $d }
                if (Test-Path -LiteralPath $p -PathType Leaf) { (Get-Item -LiteralPath $p).Length } else { $null }
            }
            if ($null -eq $result.Bytes) {
                throw "winmesh(winrm) $($h.Address): the copy reported success but no file is at '$Destination' on the host."
            }
        }

        if ($result.Bytes -ne $sourceBytes) {
            throw "winmesh(winrm) $($h.Address): the destination is $($result.Bytes) bytes, the source is $sourceBytes. The copy is incomplete."
        }
        $result.Ok = $true
        return $result
    } finally {
        Remove-PSSession $session -ErrorAction SilentlyContinue
    }
}
