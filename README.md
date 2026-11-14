# RACS v0.4.2

RACS is a standalone Radiological Access Control System for OpenComputers on
Minecraft 1.12.2. It does **not** control doors and does not integrate with the
separate airlock project.

The program combines the v0.1-v0.4 roadmap in one installable release:

- v0.1: Transposer-backed Geiger issue/return and chest validation.
- v0.2: persistent personnel, loans, accountability, and self-reported readings.
- v0.3: administrative lockdown, alerts, recovery, and an append-only event log.
- v0.4: a versioned, read-only wireless dashboard protocol and client.
- v0.4.1: admin-protected personnel registration and individual personnel PINs.
- v0.4.2: safe personnel deactivation/reactivation and cache-safe updates.

## Important safety boundary

RACS is an accountability and inventory aid. It does not measure radiation,
verify what a player types, make exposure decisions, or operate a physical
barrier. A self-reported reading is stored as text exactly as entered. Use the
modpack's instruments and your server's safety procedure for actual decisions.

Transfers start in a fail-closed, **uncommissioned** state. Before live use, an
operator must inspect the actual public chest through RACS and confirm:

1. the Geiger stack reports `name = hbm:geiger_counter`; and
2. the configured public/stock sides match the faces of that specific
   Transposer.

The identifier is not a guess. It is the default because the exact official
NTM Extended 2.0.2 JAR contains mod ID `hbm`, constructs the item as
`geiger_counter`, and refers to it as `hbm:geiger_counter` in its bundled
advancement. See `docs/EVIDENCE.md`. The in-world check is still required
because server scripts, forks, and pack changes can alter what OpenComputers
sees.

## Hardware

Required:

- one OpenComputers computer with OpenOS, HDD, enough RAM, GPU, screen, and keyboard;
- one OpenComputers Transposer connected to the computer's component network;
- one player-accessible **public exchange chest** directly adjacent to the Transposer;
- one access-controlled **secure stock chest** directly adjacent to a different Transposer face;
- OpenComputers cable between the computer and Transposer.

Optional:

- a wireless network card in the RACS computer;
- a second OpenComputers computer with a wireless card for `racs-dashboard`.

Do not connect hoppers, pipes, or other automation to either chest. The secure
stock chest must not be publicly accessible. Side names are relative to the
Transposer block, so verify them in game instead of relying on a diagram.

## Installation

1. Unzip this project and copy the complete folder onto an OpenComputers disk,
   floppy, or mounted filesystem.
2. In OpenOS, change into the copied folder and run:

       install.lua

3. Edit `/etc/racs.cfg`:

       edit /etc/racs.cfg

4. Set `publicSide` and `stockSide`, choose a new `adminPin`, and keep
   `sidesConfirmed = false` and `equipment.confirmed = false` for the first run.
5. Start RACS:

       racs

6. Open **Diagnostics**, list adjacent inventories, then place exactly one
   known Geiger counter in the otherwise empty public chest and inspect it.
7. Remove the item. If the displayed name and both chest sides are correct,
   stop RACS, set both confirmation fields to `true`, and restart.

The installer preserves an existing `/etc/racs.cfg` and existing data.

## Optional Pastebin + private Gitea installation

`gitea-bootstrap.lua` is designed to be the small, stable file placed on
Pastebin. The application files and `racs-manifest.cfg` stay in an anonymously
readable distribution repository. The bootstrap prompts for the Gitea URL,
owner, repository, immutable release tag, and repository folder. It downloads
everything into `/tmp` before replacing installed program files, and preserves
existing configuration.

The bootstrap deliberately accepts no passwords or tokens. OpenOS may include
a failed request URL in terminal errors, proxies commonly log URLs, and a running
OpenComputers process can be persisted with the Minecraft world. If the main
Gitea installation requires sign-in even for public repositories, publish only
the RACS release payload through a separate anonymous static HTTPS path or a
separate public distribution repository. Keep private development repositories
behind the normal login.

Upload `gitea-bootstrap.lua` to Pastebin, then run it with the ID Pastebin gives
you:

    pastebin run PASTE_ID

If `pastebin` is unavailable, download and run that same stable bootstrap:

    wget -f https://pastebin.com/raw/PASTE_ID /tmp/racs-bootstrap.lua
    /tmp/racs-bootstrap.lua

If the Gitea host is behind a VPN, firewall, IP allowlist, or a separate
browser-login proxy, the Minecraft server host must be allowed to reach the
narrow anonymous HTTPS release route. Internet Card HTTP requests originate
from the Minecraft server process (or the local Java process in single-player),
not from a separate in-game IP. Do not put a token in Pastebin, a URL, a command
line, or an OpenOS configuration file.

## Recommended Pastebin + public GitHub installation

`github-bootstrap.lua` is the recommended network installer. It contains the
public repository name `matesaman9910/RACS`, resolves the `main` branch to its
exact commit through the GitHub API, downloads `racs-manifest.cfg` from that
immutable commit, then obtains application files from the immutable release tag
named by the manifest. Resolving the commit prevents stale raw-file caching from
silently selecting an older release. It accepts and stores no credentials.

Upload `github-bootstrap.lua` to Pastebin once, then install with:

    pastebin run PASTE_ID

The GitHub repository must contain the contents of this release directory at
its root. Create the manifest's `racs-v0.4.2` tag only after all files have been
uploaded and verified. Future releases update the manifest on `main` to point to
a new immutable tag; the Pastebin bootstrap does not change.

## Normal operation

### Register

Registration requires the administrator PIN. The administrator registers a
Minecraft username and assigns a 4-12 digit personnel PIN. Usernames are matched
case-insensitively while the originally entered spelling is retained. Existing
personnel records created before v0.4.1 are preserved, but an administrator must
use **Administration > Set/reset personnel PIN** before those people can check
in or out.

Personnel PINs are entered with masked characters and are not written to the
event log or stored directly. RACS stores a small dependency-free verifier. This
is suitable for preventing casual console use, but it is not cryptographic
security: a short numeric PIN can be brute-forced by anyone who can copy the
computer disk. Keep the computer and disk physically secured.

### Deactivate or reactivate personnel

Administration option **Deactivate/reactivate personnel** disables future
check-ins without deleting the person's loans, readings, PIN verifier, or audit
history. Deactivation is refused while the person is recorded inside, has an
active loan, has a pending transaction, or is referenced by an active loan
record. The administrator must type `DEACTIVATE` or `REACTIVATE` to confirm the
change. A reactivated person keeps their previous PIN unless an administrator
resets it separately.

### Check in / issue equipment

RACS refuses the operation unless the public chest is empty, the person is
outside with no active loan, stock contains a configured Geiger, there is no
unresolved transaction, commissioning is complete, and lockdown is off.
The registered person must enter their personnel PIN before equipment moves.

After one item is moved into the public chest, the person and quantity-based
loan are recorded immediately. RACS then waits for the item to be collected.
Geiger counters in this pack do not expose a trustworthy unique serial number,
so RACS does not pretend to track individual instruments.

### Check out / return equipment

The operator enters the username and a free-form, self-reported radiation
reading. RACS waits for exactly one configured Geiger and no other item in the
public chest, transfers it to secure stock, closes the loan, stores the reading,
and marks the person outside. The registered person must authenticate with their
personnel PIN first. Check-out remains available during lockdown.

### Equipment-only return

Recovered equipment can be returned without changing personnel accountability.
This is also available during lockdown. It is logged as an unassigned return.

### Lockdown

Administrative lockdown blocks new check-ins only. Admin-authorized registration,
accountability views, PIN-authenticated check-outs, and both assigned and
equipment-only returns remain available.

## Persistence, alerts, and recovery

- State: `/var/lib/racs/state.db`
- Previous state backup: `/var/lib/racs/state.db.bak`
- Human-readable event log: `/var/log/racs/events.log`

State is written to a temporary file, backed up, and renamed into place. A
transaction intent is saved before moving an item. On restart, RACS compares
the saved secure-stock count and public chest contents to reconcile a transfer.
If evidence is ambiguous, it raises `RECOVERY_REQUIRED` and blocks new item
transactions until an administrator inspects and resolves it. RACS never moves
an unexpected item automatically.

The public chest must be empty while idle. Any item found there outside an
expected issue/return raises a persistent alert and pauses new transactions.
Clearing the chest clears the live alert but does not erase the audit record.

OpenComputers `os.time()` is world time, not real-world wall-clock time. Log
timestamps are therefore labeled `worldTime`.

Keep backups of `/etc/racs.cfg`, `/var/lib/racs`, and `/var/log/racs` before
upgrading or replacing the computer's disk.

## Wireless protocol

Networking is optional and read-only. Set `network.enabled = true`, configure a
non-default `readToken`, and install a wireless card. The server opens the
configured port and accepts serialized single-string packets:

    {protocol="RACS", version=1, type="request", id="...", action="STATUS", token="..."}

Supported actions are `DISCOVER`, `STATUS`, `ACCOUNTABILITY`, and `EVENTS`.
There are deliberately no remote lockdown, personnel, or transfer commands.
The included client can discover a server and display status:

    racs-dashboard

The token is access control against accidental viewing, not cryptographic
security. OpenComputers wireless traffic is not encrypted. Use limited radio
range and a physically controlled network for sensitive deployments.

## Staged in-game test plan

Do not skip stages. Use expendable test data and back up the disk first.

### Stage 1: component and side discovery

1. Start with both chests empty and confirmations false.
2. Open Diagnostics and verify exactly one Transposer is detected.
3. List all six adjacent faces and identify the public and stock inventory sizes.
4. Put a harmless item in one chest at a time to prove the mapping.
5. Confirm that no transfer action is available while uncommissioned.

### Stage 2: item identity

1. Put exactly one known NTM Extended 2.0.2 Geiger in the public chest.
2. Inspect the public chest and record `name`, label, damage, tag flag, and slot.
3. Confirm `name` is `hbm:geiger_counter`. If it differs, use the observed name
   in the config; do not guess.
4. Empty the public chest, set the two confirmation fields true, and restart.

### Stage 3: clean issue

1. Put at least two confirmed Geigers in secure stock.
2. Register a test player with the admin PIN, assign a test personnel PIN, and
   check them in using that personnel PIN.
3. Verify one item moves to public, the player collects it, accountability shows
   the player inside, and one active loan exists.
4. Restart RACS and confirm the record persists.
5. Try an incorrect personnel PIN and verify no item moves and the failed attempt
   appears in the event log.
6. Deactivate the test player, verify check-in is blocked, reactivate them, and
   verify their existing PIN works again.

### Stage 4: clean return

1. Check the test player out and enter a recognizable test reading such as
   `TEST ONLY - ambient 0`.
2. Deposit exactly one Geiger when prompted.
3. Verify it moves to secure stock, the player becomes outside, the loan closes,
   and the reading appears in personnel history.

### Stage 5: faults and lockdown

1. Put a non-Geiger item in the idle public chest; verify an alert and blocked
   transactions. Remove it and verify the live alert clears.
2. Try a mixed Geiger + foreign item return; verify nothing moves.
3. Fill secure stock so a return cannot fit; verify the player remains inside
   and the item stays public.
4. Enable lockdown; verify check-in is blocked while check-out and equipment-only
   return still work.
5. Interrupt power once after an issue and once during a return. Restart and
   follow the displayed recovery result. Confirm counts and records manually.

### Stage 6: wireless read-only dashboard

1. Use a new non-default read token and short wireless strength.
2. Start `racs-dashboard` on a second computer.
3. Confirm status/accountability updates and a wrong token is rejected.
4. Confirm the client exposes no state-changing action.

## Removal

Stop RACS, back up any records you need, then remove:

    /usr/bin/racs.lua
    /usr/bin/racs-dashboard.lua
    /usr/lib/racs

Configuration and records are intentionally not removed automatically.

