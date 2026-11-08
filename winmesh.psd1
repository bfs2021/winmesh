@{
    RootModule        = 'winmesh.psm1'
    ModuleVersion     = '0.3.0'
    GUID              = 'b8f1e6a2-3c4d-4e5f-9a0b-1c2d3e4f5a6b'
    Author            = 'Andrew Moryakov'
    Copyright         = '(c) 2026 Andrew Moryakov. MIT License.'
    Description       = 'A thin opinionated layer for linking machines over WinRM or SSH: name-based addressing from a config, channel checks, file transfer, detached runs, a bootstrap generator. Works over any network with stable addresses — overlay (Tailscale, NetBird, ZeroTier) or plain LAN. Controller and targets on Windows, Linux or macOS: WinRM between Windows machines, SSH everywhere.'
    PowerShellVersion = '5.1'
    CompatiblePSEditions = @('Desktop', 'Core')
    FunctionsToExport = @(
        'Get-WinMeshConfig',
        'Register-WinMeshCredential',
        'Connect-WinMeshHost',
        'Invoke-WinMeshCommand',
        'Copy-WinMeshItem',
        'Start-WinMeshProcess',
        'Get-WinMeshProcess',
        'Test-WinMeshHost',
        'Test-WinMeshFleet',
        'New-WinMeshBootstrap',
        'Get-WinMeshFirewallScope',
        'Set-WinMeshFirewallScope'
    )
    CmdletsToExport   = @()
    AliasesToExport   = @()
    VariablesToExport = @()

    PrivateData = @{
        PSData = @{
            LicenseUri = 'https://github.com/AndrewMoryakov/winmesh/blob/main/LICENSE'
            ProjectUri = 'https://github.com/AndrewMoryakov/winmesh'
            Tags       = @('Windows', 'Linux', 'MacOS', 'PSEdition_Desktop', 'PSEdition_Core', 'WinRM', 'SSH', 'PSRemoting', 'remote-management', 'mesh-vpn', 'Tailscale', 'NetBird', 'ZeroTier', 'LAN')
        }
    }
}
