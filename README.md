# CraftWerk

A small Windows manager for the open-source [Craft apps](https://github.com/storytold) (PhotoCraft,
VectorCraft, LightCraft, WordCraft and the rest). Pick apps from a list; it downloads each one's
latest portable release from GitHub, checks it against the project's published SHA-256 sums,
registers its file types, and keeps it updated weekly. Plain PowerShell 5.1 plus Windows Forms:
nothing to install first.

## Using it

Download `CraftWerk-Manager.zip`, unblock and extract it, and run `CraftWerk Setup.cmd`.
The zip's `README.txt` has the end-user steps.

## Layout

| Path | What it is |
|---|---|
| `CraftWerk-Manager.ps1` | The window. It only chooses what to run and shows the output. |
| `CraftWerk Setup.cmd` | Launcher; allows the script for that one run on PCs that block `.ps1` by default. |
| `tools/update-craftwerk.ps1` | Install, update, roll back, uninstall and verify apps. Dry run unless given `-Apply`. |
| `tools/register-apps.ps1` | File types, Default apps entries and Start menu shortcuts, per user, no admin. |
| `tools/setup-schedule.ps1` | The weekly scheduled task, and a first update check. |
| `build-package.ps1` | Builds `dist/CraftWerk-Manager.zip`. |

On install, `tools/` and the window are copied to `<install folder>\_update`, which is where the
weekly task runs them from.

## Behavior worth knowing

- A download that fails its checksum is skipped, never installed.
- One previous version of each app is kept for `-Rollback`. A failed install restores it automatically.
- Updates skip an app that is open. Anything in an app's folder that the release didn't put there
  (settings, your own files) is left alone.
- No internet: one retry two hours later, then the next weekly run.
- Only installed apps are ever checked for updates.

## Testing

There's no test suite yet. `CraftWerk-Manager.ps1 -SelfTest -SelfTestApps <ids> -SelfTestAction install|remove|rollback`
drives the real window's buttons without showing it, against `-Root <scratch folder>`; it leaves file
associations and the weekly task alone. `update-craftwerk.ps1` has no side effects without `-Apply`.

## Licence

MIT OR Apache-2.0, at your option. See `LICENSE-MIT` and `LICENSE-APACHE`.
