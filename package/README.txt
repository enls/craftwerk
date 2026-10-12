CraftWerk Manager
=================

Installs and keeps up to date the open-source "Craft" apps (PhotoCraft, VectorCraft, LightCraft,
WordCraft, GridCraft, DeckCraft, DesignCraft, EffectCraft, FilmCraft, SoundCraft, CadCraft, PdfCraft).

TO INSTALL
  1. Right-click the zip you downloaded > Properties > check "Unblock" > OK. (This skips a Windows
     security warning. If you didn't, just click through it.)
  2. Right-click the zip > Extract All. Put the folder anywhere that isn't OneDrive or Desktop.
  3. Double-click "CraftWerk Setup.cmd".
  4. Check the apps you want and click "Install / update checked".

The apps are downloaded straight from each project's own GitHub page, and each download is checked
against the checksum the project publishes. If a check fails, that app is skipped.

Leave the two boxes checked unless you know you don't want them:
  - "Set up file types and Start menu shortcuts" lets you open files in the apps (double-click, or
    right-click > Open with) and finds them from the Start menu.
  - "Check for updates every week" updates the apps by itself on Sundays at 10am.

AFTER INSTALLING
  - Open "CraftWerk Manager" from the Start menu to add apps, update, roll back or remove.
  - To make an app the default for a file type: Settings > Apps > Default apps, then search for the
    file type (for example .psd) and pick the app. Windows only lets you make that choice yourself.
  - Close an app before updating it. An open app is skipped until the next update.

IF SOMETHING GOES WRONG
  The log is in the install folder: _update\update.log

Needs Windows 10 or 11. Works on Intel/AMD (x64) and ARM PCs.
