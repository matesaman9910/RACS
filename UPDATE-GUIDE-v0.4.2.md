# RACS v0.4.2 update guide

## What changes

- Administrators can deactivate or reactivate personnel.
- Deactivated personnel cannot check in.
- Deactivation is refused while the person is inside, has an active loan, has a
  pending transaction, or is referenced by an active loan record.
- Personnel records, PINs, readings, loans, and event history are preserved.
- The GitHub installer now resolves `main` to an exact commit before downloading
  the manifest, preventing stale cached manifests from installing an older release.

## 1. Publish to GitHub

1. Extract `RACS-v0.4.2.zip` on the real computer.
2. Upload the contents of the extracted `RACS-v0.4.2` directory to the root of
   `matesaman9910/RACS`, replacing the existing files while retaining the
   `payload` directory structure.
3. Commit the upload to `main`.
4. Open GitHub Releases and create a release targeting that new `main` commit.
5. Use the exact tag `racs-v0.4.2` and title `RACS v0.4.2`.
6. Publish the release. Do not run the in-game updater before the tag exists.

## 2. Back up the main OpenComputers node

Exit RACS normally with `Q`, then run:

    cp /var/lib/racs/state.db /home/racs-state-before-042.db
    cp /etc/racs.cfg /home/racs-config-before-042.cfg

Do not update during an equipment issue/return or while a pending transaction is
displayed.

## 3. Download and run the updater

On the main RACS computer:

    wget -f https://raw.githubusercontent.com/matesaman9910/RACS/racs-v0.4.2/github-bootstrap.lua /tmp/racs-update.lua
    /tmp/racs-update.lua

The final message must say:

    RACS 0.4.2 installed.
    Release: racs-v0.4.2

The updater preserves `/etc/racs.cfg`, `/etc/racs-dashboard.cfg`, personnel data,
loans, logs, and the existing network token.

## 4. Restart and verify

Run:

    reboot

After the computer starts:

    racs

Verify the title shows `RACS 0.4.2`. Open Administration with option `7`, enter
the administrator PIN, and confirm option `4` is
`Deactivate/reactivate personnel`.

The wireless dashboard protocol did not change, so existing v0.4.1 dashboards
remain compatible and do not require an update.

## 5. Test deactivation safely

Use a test person who is outside and has no active loan:

1. Administration > `4` > enter the test username.
2. Type `DEACTIVATE` exactly.
3. Attempt check-in and verify RACS reports `Personnel record is deactivated.`
   No item should move.
4. Administration > `4` > enter the same username.
5. Type `REACTIVATE` exactly.
6. Verify the person's existing PIN works again.

## Recovery

If v0.4.2 cannot start, do not move chest items. Restore the previous program
file created automatically by the updater:

    cp /usr/lib/racs/app.lua.racs-backup /usr/lib/racs/app.lua
    reboot

If the personnel state itself needs restoration, preserve the current files for
inspection before copying `/home/racs-state-before-042.db` back to
`/var/lib/racs/state.db`.
