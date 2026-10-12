<#
.SYNOPSIS
  Turns on (or off) the weekly CraftWerk update on this PC. Run once after copying the folder over.

.EXAMPLE
  .\setup-schedule.ps1            # weekly, Sunday 10am
  .\setup-schedule.ps1 -Day Wednesday -At 7pm
  .\setup-schedule.ps1 -Remove    # turn it off
  .\setup-schedule.ps1 -SkipUpdate   # set up without checking for updates now
  .\setup-schedule.ps1 -NoRegister   # just the weekly task; leave file types and shortcuts alone

  Setup also does one update check at the end, so a copied folder starts out current. Close the
  Craft apps first; any that are open are skipped until the next run.
#>
param(
    [System.DayOfWeek]$Day = 'Sunday',
    [string]$At = '10am',
    [switch]$Remove,
    [switch]$SkipUpdate,
    [switch]$NoRegister
)

$ErrorActionPreference = 'Stop'
$TaskName = 'CraftWerk updater'
$Updater  = Join-Path $PSScriptRoot 'update-craftwerk.ps1'

$Register = Join-Path $PSScriptRoot 'register-apps.ps1'

if ($Remove) {
    # either task may not exist (never set up, or no retry pending); that's fine
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName "$TaskName (retry)" -Confirm:$false -ErrorAction SilentlyContinue
    if (-not $NoRegister) { & $Register -Remove }
    Write-Host "Removed '$TaskName'."
    return
}

if (-not (Test-Path $Updater)) { throw "Can't find $Updater. Keep this script in the same folder as update-craftwerk.ps1." }

# The task updates the apps next to this script's folder. With none there (say, run from an unzipped
# download instead of the install folder), it would point the weekly update at nothing and replace
# the task that was updating the real install, so stop before changing anything.
$Root = Split-Path $PSScriptRoot -Parent
$hasApps = Get-ChildItem $Root -Directory | Where-Object {
    $_.Name -ne '_update' -and (Test-Path (Join-Path $_.FullName "$($_.Name.ToLower()).exe"))
}
if (-not $hasApps) {
    throw "No Craft apps found in $Root, so nothing was changed. Run this from the _update folder inside your CraftWerk folder, or use CraftWerk Setup.cmd to install apps."
}

# files copied from a download or a zip are marked "from the internet"; clear that so they run
Get-ChildItem $Root -Recurse -File | Unblock-File

$action   = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Updater`" -Apply -Scheduled"
$trigger  = New-ScheduledTaskTrigger -Weekly -DaysOfWeek $Day -At $At
# StartWhenAvailable: if the PC was off or asleep at the scheduled time, run soon after the next login.
# The battery switches: Windows' defaults skip the run on a laptop that isn't plugged in.
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

# -Force replaces an existing task of the same name (e.g. after moving the folder)
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Force | Out-Null
Write-Host "'$TaskName' will run every $Day at $At, updating the apps in $Root."
Write-Host "Log: $(Join-Path $Root '_update\update.log')"

# register the apps with Windows: file types, Default apps, Start menu
if (-not $NoRegister) { & $Register }

# bring a copied folder up to date now instead of waiting for the first weekly run.
# Offline or a failed check doesn't undo the setup above; it's logged and the weekly run tries again.
if (-not $SkipUpdate) {
    Write-Host ''
    Write-Host 'Checking for updates...'
    try { & $Updater -Apply } catch { Write-Host "Update check failed: $($_.Exception.Message)" }
}
