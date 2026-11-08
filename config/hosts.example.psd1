@{
    # Defaults for every host. Any of these can be overridden per host.
    Defaults = @{
        Transport       = 'winrm'                       # 'winrm' or 'ssh'

        CredentialStore = '~\.winmesh\creds'            # where encrypted credentials are stored

        # Subnets allowed to reach the WinRM port (the bootstrap narrows the
        # firewall to these). Choose the value that matches how your machines
        # are linked:
        #   Tailscale / NetBird  -> '100.64.0.0/10'  (CGNAT range, the default)
        #   ZeroTier             -> your network subnet, e.g. '10.147.17.0/24'
        #   plain LAN            -> e.g. '192.168.1.0/24'
        #   several at once      -> @('192.168.1.0/24','100.64.0.0/10')
        #   do not narrow (trusted LAN) -> @()
        AllowedSubnets  = @('100.64.0.0/10')

        # --- ssh transport only (Transport = 'ssh') ---
        # There is no Credential over ssh: the ssh client authenticates on its
        # own, and on an overlay network it may need nothing at all.
        SshUser         = ''                            # remote account; empty = let ssh decide
        SshPort         = 22
        SshShell        = 'powershell'                  # 'powershell' (5.1) or 'pwsh'; Linux/macOS targets need 'pwsh'
        SshTimeout      = 15                            # seconds (ConnectTimeout)
        SshOptions      = @()                           # extra -o options, e.g. @('StrictHostKeyChecking=accept-new')
    }

    # Your fleet. The key is a short name you will use to refer to the machine.
    # Address is its address on your network (overlay IP, LAN address, or DNS name).
    Hosts = @{
        'workstation-01' = @{
            Address    = '100.100.10.11'                # address or DNS name
            Credential = 'admin@workstation-01'         # id of the stored credential
            Note       = 'example: a workstation'       # optional free-text note
        }

        # 'nas-zt' = @{
        #     Address        = '10.147.17.20'   # e.g. a ZeroTier address
        #     Credential     = 'admin@nas-zt'
        #     AllowedSubnets = @('10.147.17.0/24')   # per-host; overrides Defaults.AllowedSubnets
        # }

        # 'nas-lan' = @{
        #     Address    = '192.168.1.50'               # example: a machine on the LAN
        #     Credential = 'admin@nas-lan'
        # }

        # Same machine over ssh. Note what is absent: no Credential.
        # 'workstation-02' = @{
        #     Address   = 'workstation-02'              # overlay name resolved by the VPN client
        #     Transport = 'ssh'
        #     SshUser   = 'Administrator'
        #     Note      = 'reached over NetBird; auth is by peer identity'
        # }

        # A Linux or macOS machine: ssh only, with PowerShell 7 installed there.
        # 'linux-01' = @{
        #     Address   = '100.100.10.21'
        #     Transport = 'ssh'
        #     SshUser   = 'admin'
        #     SshShell  = 'pwsh'                          # or a full path, e.g. '/usr/local/bin/pwsh'
        # }
    }
}
