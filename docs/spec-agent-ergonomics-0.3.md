# Spec — winmesh 0.3: the non-interactive caller

**Status:** P1, P2 and P4 are implemented in `0.3.0`. P3 and P5 are still
proposals; nothing in those sections exists.
**Audience:** whoever implements the rest, and anyone asking why the implemented
parts behave the way they do. The owner's two decisions are recorded in
*What the owner decided*, at the end.

## The diagnosis in one sentence

winmesh is built for a human at a PowerShell console, and its central feature —
typed objects instead of text — is invisible to a caller that drives it from a
non-PowerShell shell and reads the terminal; meanwhile the four things such a
caller needs most are absent.

That is not a design flaw. It is a stated audience. This spec asks for the
smallest additions that serve a second audience — a script, a cron job, a CI
step, an LLM agent — without changing what the console user already has.

## Evidence

One agent session, 2026-11-08, one controller (Linux, `pwsh` 7, 2 vCPU) against
four targets. Every remote action of that session, classified from the
transcript:

| Path taken | Calls |
|---|---|
| `Invoke-WinMeshCommand` / `Test-WinMeshHost` | 303 |
| hand-built `scp` (half of them: write a `.ps1` locally, copy it, run it with `-File`) | 146 |
| raw `ssh` to an alias in `~/.ssh/config` | 47 |

**About 40% of remote work (193 of 496) went around the module.** Not because
the module failed — because it has no file transfer, no way to accept a script
file, no detached execution, and no exit-code signal. Each bypass is explained
by one of the items below. Treat the ratio as one session's measurement, not a
general rate.

Four facts below were measured against a Windows target on the ssh transport,
not assumed. They are marked **measured**.

## Scope check

`CONTRIBUTING.md` puts in scope: making the existing flow more robust, *new
helper commands that fit the "name a host, act on it" model*, keeping the two
transports interchangeable, and documentation. Items P1–P4 are helper commands
or parameters in that model. Nothing here adds a dependency, stores a secret,
generates a key, or duplicates `~/.ssh/config`.

Out of scope and deliberately not proposed: a resident daemon or connection
broker, parallel fan-out, a job registry, a separate CLI entry point in another
language, any configuration management.

## Priority

| | Item | Why first | Size |
|---|---|---|---|
| **P1** | native exit code reaches the caller | the only failure class that is currently *silent* | small |
| **P2** | `Copy-WinMeshItem` | removes 146 hand-built commands | small |
| **P3** | `-ScriptFile` on `Invoke-WinMeshCommand` | removes a whole layer of quoting | trivial |
| **P4** | `Start-WinMeshProcess` / `Get-WinMeshProcess` | the only item that changes the module's size class | medium, needs a prototype |
| **P5** | delegate to `~/.ssh/config`; read one host's registry section | **needs no code** — config comment and three lines of docs | docs only |

---

## P1 — A native command's exit code must reach the caller

### Problem

A scriptblock whose native command fails returns **successfully**. There is no
exception and the caller's `$LASTEXITCODE` is `0`, so a failed build, a rejected
push or a failing test looks like a pass to anything that does not read the text.

### Evidence (measured)

```powershell
Invoke-WinMeshCommand workstation-01 { cmd /c "echo native-ran & exit 3"; "LASTEXITCODE=$LASTEXITCODE" }
#   native-ran
#   LASTEXITCODE=3        <- correct on the far side
# caller's $LASTEXITCODE after the call: 0        <- lost on the wire, no throw
```

In the session that produced this spec the mechanism cost a wrong conclusion: a
build was verified as fresh while the build tool had in fact refused to run
("no work to do"), so a stale binary was measured.

For contrast, a *PowerShell* error does arrive correctly and with the address in
the message (**measured**):

```
winmesh(ssh) <address>: Cannot find drive. A drive with the name 'Q' does not exist.
```

So the error channel works. Only the native exit code is dropped.

### Proposed surface

```powershell
Invoke-WinMeshCommand workstation-01 { ninja -C build } -ThrowOnNativeExit
```

An opt-in switch. When set, the remote payload captures `$LASTEXITCODE`
immediately after running the scriptblock and, if it is a non-zero number, the
controller throws:

```
winmesh(ssh) workstation-01: the remote command exited with code 3
```

This rides the error channel that already works, and makes `pwsh -c '...'` exit
non-zero — which is the signal a non-PowerShell caller can actually see.

### Contract, stated honestly

`$LASTEXITCODE` in a fresh `-EncodedCommand` session is a **tri-state**, and all
three states were measured:

| Observed | Meaning |
|---|---|
| `$null` | no native command ran at all |
| `0` | the **last** native command succeeded |
| non-zero | the **last** native command failed |

It is the *last* native command's code, not "did anything fail". Measured:
`cmd /c "exit 7"; cmd /c "exit 0"` leaves `0`. The documentation must say this in
those words, or the switch will be read as a guarantee it cannot give. A caller
who needs per-command strictness writes that into the scriptblock itself
(`if ($LASTEXITCODE) { throw }` after each command).

### P1b (optional, same payload change)

```powershell
$r = Invoke-WinMeshCommand workstation-01 { ninja -C build } -ResultEnvelope
# $r.Output         — what the scriptblock returned (today's return value)
# $r.NativeExitCode — the tri-state above
# $r.Host           — the host name
```

Useful for a caller that wants to branch rather than catch. Not mutually
exclusive with `-ThrowOnNativeExit`; both may be set.

### Back-compat

Without the switch nothing changes: same return value, same exceptions. The
payload gains two lines whether or not the switch is set, so the serialized
result must stay exactly as it is today when the switch is absent.

### 5.1 and cross-platform

`$PSNativeCommandUseErrorActionPreference` does **not** exist in Windows
PowerShell 5.1 and must not be used. Capturing `$LASTEXITCODE` after the call
works in 5.1, 7, and on Linux/macOS targets. No new cmdlets.

### Owner decision — WinRM parity

`CONTRIBUTING.md` requires the two transports to behave the same. Today the
WinRM path hands the caller's scriptblock straight to `Invoke-Command`, which is
why `$using:` works there. Capturing `$LASTEXITCODE` on WinRM needs the same
wrapper the ssh path uses (recreate the block from its text) — **and that
removes `$using:` support from the WinRM path**. The ssh path never had it.

Two acceptable answers, both need writing down:

- **(a)** the switch is ssh-only; using it on a WinRM host throws a clear
  "not supported on the WinRM transport" — asymmetry documented in the commands
  table and in `README` → *Status and known limits*;
- **(b)** both transports get the wrapper, `$using:` stops working on WinRM, and
  that becomes a breaking note in `0.3.0`.

Recommendation: **(a)**. It is additive, and nobody loses a feature.

### Acceptance check

In the repo's own shadow-`ssh` idiom (`CONTRIBUTING.md` → Testing), no second
machine needed:

```powershell
function global:ssh { $ErrorActionPreference = 'Continue'; bash -c $args[-1] }
# host entry: Transport = 'ssh'; SshShell = 'pwsh'
Invoke-WinMeshCommand h { & 'false' } -ThrowOnNativeExit   # must throw, message must name the code
Invoke-WinMeshCommand h { & 'true'  } -ThrowOnNativeExit   # must not throw
Invoke-WinMeshCommand h { 1 + 1 }     -ThrowOnNativeExit   # must not throw (null state)
Invoke-WinMeshCommand h { & 'false' }                      # must behave exactly as in 0.2.1
```

---

## P2 — `Copy-WinMeshItem`: file transfer under the same host name

### Problem

The module resolves a host name to an address, port, user and key for *running a
command*, and offers nothing for *copying a file*. The README does document
transfer, but only through `Copy-Item -ToSession`, which needs a `PSSession` —
i.e. the WinRM transport. On an all-ssh fleet, or from a Linux controller, that
route does not exist, so the caller rebuilds `scp -P <port> -i <key>
<user>@<address>:<path>` by hand every time. That was 146 commands in one
session, and it is exactly the lookup the module exists to remove.

### Proposed surface

```powershell
Copy-WinMeshItem -Name workstation-01 -Path .\report.csv -Destination 'C:/Temp/'   # to the host
Copy-WinMeshItem -Name workstation-01 -Path 'C:/Temp/log.txt' -Destination .\ -FromHost
```

- ssh transport → `scp` with the same port, user, key and `SshOptions` the host
  entry already carries (`-P` for the port, not `-p`);
- WinRM transport → `New-PSSession` + `Copy-Item -ToSession`/`-FromSession`, i.e.
  exactly the README recipe, so both transports accept the same call;
- `-Recurse` maps to `scp -r` / `Copy-Item -Recurse`;
- returns an object: `Host`, `Direction`, `Path`, `Destination`, `Bytes`, `Ok`.

### Contract

**Verify by artifact, not by exit code.** After the copy, stat the destination
and return the size; when the source size is known and differs, throw. Two
transfer traps are already recorded in `README` → *Gotchas* and both argue for
this: a large file that arrived truncated, and a `.ps1` carrying non-ASCII that
arrived mangled.

Two further constraints to document:

- **The target needs an scp/sftp-capable server.** An overlay VPN's embedded SSH
  server may answer on port 22 and serve shell sessions only. `Test-WinMeshHost`
  prints the server banner for exactly this reason — it is how you tell which
  server answered.
- **Non-ASCII content in a transferred `.ps1` is a known hazard** (see Gotchas);
  the cmdlet does not transcode, it copies bytes.

### Out of scope for this cmdlet

No sync, no mirroring, no deletion, no resume, no progress bar.

### 5.1 and cross-platform

Build every path with one `Join-Path` per segment; a backslash is a legal
filename character off Windows. A Windows destination is written `C:/path`.

### Acceptance check

Shadow-`ssh` does not help here — `scp` is a different binary. This item needs a
real target: copy a file both ways, then a file with a space in its name, then a
~1 GB file and compare sizes.

---

## P3 — `-ScriptFile` on `Invoke-WinMeshCommand`

### Problem

The remote quoting problem is solved completely (base64 payload). The *local*
one is untouched. A caller in another shell writes

```bash
pwsh -NoProfile -c 'Invoke-WinMeshCommand workstation-01 { ... }'
```

— three nested quoting contexts, and a single apostrophe anywhere in the script
breaks the outermost one. In the session that produced this spec that is why 98
of the 146 `scp` calls existed: write the script to a file, copy it, run it with
`-File`. The module can accept that file directly.

### Proposed surface

```powershell
Invoke-WinMeshCommand workstation-01 -ScriptFile ./do-the-thing.ps1 -ArgumentList 'C:/Windows'
```

Read the file, use its text as the scriptblock body, send it through the payload
that already exists. `-ScriptFile` and `-ScriptBlock` are mutually exclusive
parameter sets, so `-ScriptBlock` stays mandatory in its own set.

### Contract

Read with `Get-Content -Raw -Encoding UTF8` explicitly: 5.1's default encoding
differs from 7's, and this is a file written by another tool. A missing file
throws before any network call. The file is never copied to the target — it
travels inside the payload, same as a scriptblock.

### Why this removes the need for a separate CLI

Once the quoted string is `Invoke-WinMeshCommand workstation-01 -ScriptFile ./x.ps1`
there is nothing left to quote, so a wrapper executable in another language would
buy nothing and would add a file type this repo does not have.

### Acceptance check

Shadow-`ssh`, no remote machine:

```powershell
'param($p) "got:$p"' | Set-Content ./t.ps1 -Encoding UTF8
Invoke-WinMeshCommand h -ScriptFile ./t.ps1 -ArgumentList 'a b "c" ; d \ % ^ &'   # arrives whole
Invoke-WinMeshCommand h -ScriptFile ./missing.ps1                                # throws, no ssh call
```

---

## P4 — Detached execution: `Start-WinMeshProcess` / `Get-WinMeshProcess`

### Problem

`Invoke-WinMeshCommand` is one shot: the command lives and dies with the ssh
connection, and nothing comes back until it ends. A 40-minute build or a
multi-hour measurement therefore cannot be run through the module at all. The
workaround is rebuilt by hand each time, slightly differently: create a remote
process through WMI, have it write a sentinel file when finished, poll.

**This is the item that changes the module's size class.** It introduces remote
state the module did not have before. It should be judged on that, not only on
usefulness.

### Proposed surface

```powershell
$p = Start-WinMeshProcess workstation-01 -ScriptFile ./build.ps1 -WorkingDirectory 'C:/src' `
        -StdoutPath 'C:/temp/build.log'
# -> Host, ProcessId, StdoutPath, DonePath, StartedUtc

Get-WinMeshProcess workstation-01 -ProcessId $p.ProcessId
# -> Alive, ExitCode (when the sentinel exists), StdoutBytes, LastWriteUtc

Get-WinMeshProcess workstation-01 -ProcessId $p.ProcessId -Tail 40
# -> the last 40 lines of StdoutPath
```

No job registry, no background state on the controller: the caller holds the
PID and polls. That keeps the module stateless and the feature small.

### Contract

- The process must **outlive the ssh session**. On a Windows target the
  mechanism known to work is creating the process through WMI
  (`Win32_Process.Create`); `Start-Process` from within the ssh session is not a
  substitute. On Linux/macOS the counterpart is `setsid`/`nohup` with input
  closed and both streams redirected. Both need a real smoke test; neither is
  assumed working.
- **Completion is proven by artifact, never by elapsed time.** The launcher
  writes a sentinel file containing the exit code as its last act; `Alive` comes
  from the process list, `ExitCode` from the sentinel. A caller that sees
  `Alive = $false` with no sentinel knows the process died rather than finished —
  a state the current one-shot path cannot even express.
- `-Tail` reads the remote file on demand. This is deliberately *instead of* a
  streaming channel: it gives the same answer ("where is it now?") without a
  long-lived connection or a second output protocol.

### Out of scope

No scheduling, no restart, no log rotation, no cancellation beyond "the caller
can run `Stop-Process` through `Invoke-WinMeshCommand`".

### Acceptance check

Needs a real target on each OS family: start a 90-second sleep, confirm the
controller's call returns immediately, drop the network/close the session,
confirm the process is still alive, confirm the sentinel appears with the right
exit code, confirm a non-zero exit is reported as non-zero.

---

## P5 — Two problems that need no code

### 5a. A host entry can already delegate everything to `~/.ssh/config`

`CONTRIBUTING.md` says per-host ssh detail belongs in `~/.ssh/config` and that
the module does not duplicate it. It already supports that, and it is not
documented. **Measured** with a scratch config: an entry whose `Address` is an
ssh-config alias, with `SshOptions = @()`, `SshPort = 22` and no `SshUser` at
either level, produced a working round trip: an empty host-level `SshOptions`
suppresses the defaults' `-o` injection, port 22 suppresses the `-p` flag, and
with no user the target is the bare alias, leaving `ssh <alias>` for the client
to resolve.

```powershell
'workstation-01' = @{
    Address    = 'workstation-01-alias'   # a Host block in ~/.ssh/config
    Transport  = 'ssh'
    SshPort    = 22                       # 22 = do not pass -p
    SshOptions = @()                      # empty = do not inject the defaults' -o options
    # and no SshUser, here or in Defaults: a user at either level makes the
    # target 'user@alias', which overrides the alias's own User directive.
}
```

Action: add that block as a commented example in `config/hosts.example.psd1`,
and one line in `README` → *Config reference*. No code.

This matters to a non-interactive caller for a specific reason: a host reachable
through an ssh alias but absent from `hosts.psd1` does not exist as far as the
module is concerned, and the caller falls back to raw `ssh` — 47 times in the
measured session.

### 5b. The connection registry is read whole to answer one question

`AGENTS.md` requires reading `connections.local.md` before connecting. In the
measured setup that file is ~99 KB for 7 machines, and it is read in full to
recover one port or one key path. For an agent that is a direct context cost,
every session.

The file already uses one `##` heading per machine, and those headings match the
config names. So the fix is a convention, not a feature: **read your machine's
section, not the file.** Three lines in `AGENTS.md`, nothing in the module.

---

## Deliberately not in this spec

- **Performance.** Measured on the controller used here: a trivial round trip
  took 5–12 s against 3.6–5.6 s for raw `ssh`, but a bare local `pwsh` start on
  that 2-vCPU machine took **4–23 s** on its own. The spread is larger than the
  difference, so no claim about the module's speed is supported, and no change is
  proposed. A caller who wants to amortise the ssh half can add
  `ControlMaster=auto` to `SshOptions` today.
- **A resident daemon or connection broker.** Out of scope, and a long-lived
  listener is a thing to register and autostart, not a dependency to add to a
  dependency-free module.
- **Output encoding.** Suspected, then checked: the Windows target measured here
  reports code page 65001 (UTF-8), so the mojibake seen elsewhere in that
  session was not produced by the module. One host is not the fleet; if a target
  with a legacy code page shows mangled native output, that is a separate
  investigation with its own evidence.
- **Parallel fan-out.** Already named as a non-goal in the README.

## Documentation changes this spec requires

1. `README` → *What's inside* currently states that the repository labels
   nothing as planned. That sentence must change when this file lands: it is the
   one forward-looking document.
2. A row in `README` → *Documentation map* pointing here.
3. On implementation: the commands table, the parameters table, *Status and known
   limits*, and `CONTRIBUTING.md`'s ssh-transport conventions all gain entries —
   including the tri-state exit code in P1 and the transport asymmetry the owner
   chooses there.

## What the owner decided

Both questions were answered on 2026-11-08, and the answers are what `0.3.0`
implements:

1. **P1 WinRM parity** — the switch is **ssh-only**. Using `-ThrowOnNativeExit`
   on a WinRM host raises an error naming the reason, so `$using:` keeps working
   there and nobody loses a feature.
2. **P4** — **wanted**, and built: `Start-WinMeshProcess` and
   `Get-WinMeshProcess`.
3. Later the same day, the question P4 left open (#19): a detached job is
   stopped with `Stop-WinMeshProcess` rather than by a hand-written
   `Stop-Process`, because the hand-written one gets a recycled pid and a Unix
   process group silently wrong.

What is still open from this document: **P3** (`-ScriptFile`) is issue #13, and
**P5**'s two documentation changes are issues #14 and #15. Work this release
added rather than closed — a test suite, a run timeout, job-file cleanup, the
unverified WinRM copy path, macOS — is listed in issue #23, which is the place
to look first.
