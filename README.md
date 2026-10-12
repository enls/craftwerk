# CraftWerk

A small Windows manager for the open-source [Craft apps](https://github.com/storytold) (PhotoCraft, VectorCraft, LightCraft, WordCraft and the rest). Pick apps from a list; it downloads each one's latest portable release from GitHub, checks it against the project's published SHA-256 sums, registers its file types, and keeps it updated weekly. Plain PowerShell 5.1 plus Windows Forms: nothing to install first.

## Using it

**Windows:** download `CraftWerk-Manager.zip`, unblock and extract it, and run `CraftWerk Setup.cmd`. The zip's `README.txt` has the end-user steps.

**Linux:** download `craftwerk.sh` and run `bash craftwerk.sh` for a menu, or use commands:

```sh
bash craftwerk.sh list                    # what's installed and what's available
bash craftwerk.sh install photocraft wordcraft
bash craftwerk.sh install photocraft@0.5.0   # a specific version
bash craftwerk.sh update                  # update everything installed
bash craftwerk.sh rollback photocraft
bash craftwerk.sh schedule on             # weekly updates (systemd timer, or cron)
```

It needs only `bash`, `curl`, `tar` and `sha256sum`, and installs to `~/.local` without root (`--system` installs to `/usr/local`). Each release's Linux tarball is a ready-made prefix, so the menu entries, icons and file types come with it. Settings in your home folder are never touched.

## Layout

| Path | What it is |
|---|---|
| `CraftWerk-Manager.ps1` | The window. It only chooses what to run and shows the output. |
| `CraftWerk Setup.cmd` | Launcher; allows the script for that one run on PCs that block `.ps1` by default. |
| `tools/update-craftwerk.ps1` | Install, update, roll back, uninstall and verify apps. Dry run unless given `-Apply`. |
| `tools/register-apps.ps1` | File types, Default apps entries and Start menu shortcuts, per user, no admin. |
| `tools/setup-schedule.ps1` | The weekly scheduled task, and a first update check. |
| `build-package.ps1` | Builds `dist/CraftWerk-Manager.zip`. |
| `linux/craftwerk.sh` | The Linux version: one bash script with the same commands, a menu, and a systemd or cron schedule. |

On install, `tools/` and the window are copied to `<install folder>\_update`, which is where the weekly task runs them from.

## Behavior worth knowing

- A download that fails its checksum is skipped, never installed.
- One previous version of each app is kept for `-Rollback`. A failed install restores it automatically.
- Updates skip an app that is open. Anything in an app's folder that the release didn't put there (settings, your own files) is left alone.
- No internet: one retry two hours later, then the next weekly run.
- Only installed apps are ever checked for updates.
- Setup run from a folder with no Craft apps in it (say, an unzipped download) stops without changing anything, and registering from such a folder leaves alone apps registered elsewhere.

## Testing

There's no test suite yet. The Linux script's download, checksum, unpack, update, rollback and remove logic was exercised against real releases using Git Bash on Windows. Not yet run on a real Linux machine: the systemd/cron schedule, the whiptail menu, desktop-database refresh, the missing-library check and running-app detection.

On Windows: `CraftWerk-Manager.ps1 -SelfTest -SelfTestApps <ids> -SelfTestAction install|remove|rollback` drives the real window's buttons without showing it, against `-Root <scratch folder>`; it leaves file associations and the weekly task alone. `update-craftwerk.ps1` has no side effects without `-Apply`.

## License

MIT OR Apache-2.0, at your option. See `LICENSE-MIT` and `LICENSE-APACHE`.
