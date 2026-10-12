<#
.SYNOPSIS
  Keeps the portable Craft apps in the folder above this one (e.g. C:\CraftWerk) on their latest GitHub release.

.DESCRIPTION
  For each app folder (one whose name matches <folder>.exe inside it):
    1. Reads the installed version from the .exe's file properties.
    2. Asks GitHub for storytold/<app>'s latest release.
    3. If newer: downloads <app>-<ver>-windows-x64-portable.zip and SHA256SUMS.txt,
       and stops for that app if the checksum does not match.
    4. Saves the files it is about to replace to _update\previous\<app>\ (one version back,
       replacing whatever was there before).
    5. Copies the new files over the old. Anything not in the zip (your data) is left alone.
  Also reports updates for apps installed from an .msi (it can't update those itself).

  Without -Apply it only reports. Nothing is downloaded or changed.

  -Scheduled is what the weekly task passes. It adds two things:
    - If you logged in less than 10 minutes ago, it waits until you've been logged in for 10.
    - If GitHub can't be reached, it schedules one retry two hours later and stops. If the retry
      can't reach it either, it gives up until the next weekly run.

.EXAMPLE
  .\update-craftwerk.ps1                  # dry run: what would update
  .\update-craftwerk.ps1 -Apply           # do it
  .\update-craftwerk.ps1 -Apply -Force    # reinstall every app from its latest release, even if current
  .\update-craftwerk.ps1 -Verify          # re-check installed .exes against the release checksums
  .\update-craftwerk.ps1 -Rollback wordcraft   # swap wordcraft's current and previous versions
  .\update-craftwerk.ps1 -Install pdfcraft     # add an app that isn't in the folder yet
  .\update-craftwerk.ps1 -Apply -Only wordcraft,photocraft   # update just these
  .\update-craftwerk.ps1 -Uninstall wordcraft [-KeepData]    # remove an app; -KeepData leaves anything the release didn't put there
#>
[CmdletBinding(DefaultParameterSetName = 'Update')]
param(
    [Parameter(ParameterSetName = 'Update')] [switch]$Apply,
    [Parameter(ParameterSetName = 'Update')] [switch]$Force,   # reinstall the latest even if already on it
    [Parameter(ParameterSetName = 'Update')] [switch]$Scheduled,  # run by Task Scheduler: login delay + retry
    [Parameter(ParameterSetName = 'Update')] [switch]$IsRetry,    # this is the two-hour retry run
    [Parameter(ParameterSetName = 'Verify')] [switch]$Verify,
    [Parameter(ParameterSetName = 'Rollback')] [string]$Rollback,
    [Parameter(ParameterSetName = 'Update')] [string[]]$Only,     # just these apps, e.g. -Only wordcraft,photocraft
    [Parameter(ParameterSetName = 'Install')] [string]$Install,   # add a new app, e.g. -Install pdfcraft
    [Parameter(ParameterSetName = 'Install')]
    [Parameter(ParameterSetName = 'Uninstall')] [switch]$NoRegister,   # leave file types and shortcuts alone
    [Parameter(ParameterSetName = 'Uninstall')] [string]$Uninstall,
    [Parameter(ParameterSetName = 'Uninstall')] [switch]$KeepData,
    [string]$Root   # defaults to the folder above _update, wherever it lives
)

# set here, not as the param default: PowerShell 5.1 leaves $PSScriptRoot empty in defaults under -File
if (-not $Root) { $Root = Split-Path $PSScriptRoot -Parent }

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # Invoke-WebRequest is very slow with the progress bar on
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Owner    = 'storytold'
# the build that matches this PC (a 32-bit PowerShell on 64-bit Windows reports the real CPU in ARCHITEW6432)
$Arch     = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
$Platform = switch ($Arch) { 'ARM64' { 'windows-arm64-portable' } 'x86' { 'windows-x86-portable' } default { 'windows-x64-portable' } }
$MsiApps  = @()                            # apps installed from .msi: report only (e.g. 'pdfcraft')
$Work     = Join-Path $Root '_update'
$Staging  = Join-Path $Work 'staging'
$Previous = Join-Path $Work 'previous'
$LogFile  = Join-Path $Work 'update.log'
$Headers  = @{ 'User-Agent' = 'craftwerk-updater' }
$LoginDelay    = New-TimeSpan -Minutes 10
$RetryAfter    = New-TimeSpan -Hours 2
$RetryTaskName = 'CraftWerk updater (retry)'
$CheckUrl      = 'https://api.github.com'

function Log([string]$msg) {
    $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
    Write-Host $line
    Add-Content -Path $LogFile -Value $line -Encoding utf8
}

function Get-Latest([string]$app) {
    try {
        if ($env:CRAFTWERK_FORCE_FALLBACK) { throw 'fallback forced (test hook)' }
        return Invoke-RestMethod "https://api.github.com/repos/$Owner/$app/releases/latest" -Headers $Headers
    } catch {
        # The API allows 60 lookups an hour per IP address, which a shared network can use up. The plain
        # release page redirects to the latest tag and has no such limit; the files in a release are named
        # <app>-<version>-<platform>.zip and SHA256SUMS.txt, so their addresses follow from the tag.
        # (Invoke-WebRequest throws on the redirect without exposing its headers; HttpWebRequest returns it.)
        $req = [Net.HttpWebRequest]::Create("https://github.com/$Owner/$app/releases/latest")
        $req.AllowAutoRedirect = $false; $req.UserAgent = $Headers['User-Agent']; $req.Timeout = 20000
        $resp = $req.GetResponse()
        try { $tag = ($resp.Headers['Location'] -split '/')[-1] } finally { $resp.Close() }
        if (-not $tag) { throw }
        $ver = $tag.TrimStart('v')
        $base = "https://github.com/$Owner/$app/releases/download/$tag"
        Log "${app}: GitHub's API is unavailable, using the release page instead"
        return [pscustomobject]@{
            tag_name = $tag
            assets   = @(
                [pscustomobject]@{ name = "$app-$ver-$Platform.zip"; browser_download_url = "$base/$app-$ver-$Platform.zip" }
                [pscustomobject]@{ name = 'SHA256SUMS.txt';          browser_download_url = "$base/SHA256SUMS.txt" })
        }
    }
}

function Get-Release([string]$app, [string]$ver) {
    Invoke-RestMethod "https://api.github.com/repos/$Owner/$app/releases/tags/v$ver" -Headers $Headers
}

function Get-InstalledApps {
    Get-ChildItem $Root -Directory | Where-Object { $_.Name -ne '_update' } | ForEach-Object {
        $name = $_.Name.ToLower()
        $exe = Join-Path $_.FullName "$name.exe"
        if (Test-Path $exe) {
            [pscustomobject]@{ Name = $name; Dir = $_.FullName; Version = (Get-Item $exe).VersionInfo.ProductVersion }
        }
    }
}

# Downloads the portable zip for $app/$release, checks it against SHA256SUMS.txt,
# and returns the folder the zip was extracted to (or $null on any failure).
function Get-VerifiedPackage($app, $release) {
    $ver = $release.tag_name.TrimStart('v')
    $zipName = "$app-$ver-$Platform.zip"
    $zipAsset = $release.assets | Where-Object name -eq $zipName
    $sumAsset = $release.assets | Where-Object name -eq 'SHA256SUMS.txt'
    if (-not $zipAsset) { Log "$app ${ver}: no $zipName in this release. Skipped."; return $null }
    if (-not $sumAsset) { Log "$app ${ver}: release has no SHA256SUMS.txt. Skipped (won't install unverified)."; return $null }

    $dir = Join-Path $Staging "$app-$ver"
    if (Test-Path $dir) { Remove-Item $dir -Recurse -Force }
    New-Item -ItemType Directory -Path $dir | Out-Null
    $zip = Join-Path $dir $zipName
    $sums = Join-Path $dir 'SHA256SUMS.txt'

    Invoke-WebRequest $zipAsset.browser_download_url -OutFile $zip -UseBasicParsing -Headers $Headers
    Invoke-WebRequest $sumAsset.browser_download_url -OutFile $sums -UseBasicParsing -Headers $Headers

    # lines look like "<hash>  <file>" (sometimes "<hash> *<file>")
    $expected = Get-Content $sums | ForEach-Object {
        $parts = $_.Trim() -split '\s+', 2
        if ($parts.Count -eq 2 -and $parts[1].TrimStart('*') -eq $zipName) { $parts[0].ToLower() }
    } | Select-Object -First 1
    $actual = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower()
    if (-not $expected) { Log "$app ${ver}: $zipName not listed in SHA256SUMS.txt. Skipped."; return $null }
    if ($expected -ne $actual) { Log "$app ${ver}: CHECKSUM MISMATCH (expected $expected, got $actual). Skipped."; return $null }
    Log "$app ${ver}: checksum OK"

    $out = Join-Path $dir 'extracted'
    Expand-Archive $zip -DestinationPath $out
    # some zips wrap everything in one top-level folder; step into it
    $items = Get-ChildItem $out
    if ($items.Count -eq 1 -and $items[0].PSIsContainer) { $out = $items[0].FullName }
    return $out
}

# Explorer starts when you log in, so its start time in this session is the login time.
function Wait-AfterLogin {
    $session = (Get-Process -Id $PID).SessionId
    $explorer = Get-Process explorer -ErrorAction SilentlyContinue | Where-Object SessionId -eq $session |
        Sort-Object StartTime | Select-Object -First 1
    if (-not $explorer) { return }
    $wait = $LoginDelay - ((Get-Date) - $explorer.StartTime)
    if ($wait -gt [TimeSpan]::Zero) {
        Log ('logged in recently, waiting {0:N0} min before checking for updates' -f [math]::Ceiling($wait.TotalMinutes))
        Start-Sleep -Seconds ([int][math]::Ceiling($wait.TotalSeconds))
    }
}

# True if GitHub answers at all. An HTTP error (like a rate limit) still means we're online.
function Test-Online {
    try { Invoke-WebRequest $CheckUrl -UseBasicParsing -TimeoutSec 20 -Headers $Headers | Out-Null; return $true }
    catch { return [bool]$_.Exception.Response }
}

function Register-Retry {
    $action   = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" -Apply -Scheduled -IsRetry"
    $trigger  = New-ScheduledTaskTrigger -Once -At ((Get-Date) + $RetryAfter)
    $trigger.EndBoundary = ((Get-Date) + $RetryAfter + (New-TimeSpan -Days 2)).ToString('s')
    # same missed-run and battery behavior as the weekly task; Windows deletes it once it's expired
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -DeleteExpiredTaskAfter (New-TimeSpan -Hours 1)
    Register-ScheduledTask -TaskName $RetryTaskName -Action $action -Trigger $trigger -Settings $settings -Force | Out-Null
}

# Is this copy of the app running? Matches on the folder the program runs from, so a copy of the same
# app running somewhere else doesn't block this one.
function Test-Running($app, $dir) {
    $p = Get-Process -Name $app, "$app-cli" -ErrorAction SilentlyContinue | Where-Object {
        $path = try { $_.Path } catch { $null }
        $path -and $path.StartsWith($dir.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)
    }
    if ($p) { Log "${app}: running, close it and run again. Skipped."; return $true }
    return $false
}

# Copies every file under $from into $to, keeping relative paths.
function Copy-Tree($from, $to, [string[]]$only) {
    Get-ChildItem $from -Recurse -File | ForEach-Object {
        $rel = $_.FullName.Substring($from.Length).TrimStart('\')
        if ($only -and $rel -notin $only) { return }
        $dest = Join-Path $to $rel
        New-Item -ItemType Directory -Path (Split-Path $dest) -Force | Out-Null
        Copy-Item $_.FullName $dest -Force
    }
}

New-Item -ItemType Directory -Path $Work, $Staging, $Previous -Force | Out-Null

# ---- Rollback: swap current and previous for one app -----------------------------------------
if ($PSCmdlet.ParameterSetName -eq 'Rollback') {
    $app = $Rollback.ToLower()
    $cur = Get-InstalledApps | Where-Object Name -eq $app
    $prev = Join-Path $Previous $app
    if (-not $cur) { Log "rollback ${app}: not found in $Root"; exit 1 }
    if (-not (Test-Path $prev)) { Log "rollback ${app}: no previous version saved"; exit 1 }
    if (Test-Running $app $cur.Dir) { exit 1 }
    $prevFiles =Get-ChildItem $prev -Recurse -File | ForEach-Object { $_.FullName.Substring($prev.Length).TrimStart('\') }
    $swap = Join-Path $Staging "$app-swap"
    if (Test-Path $swap) { Remove-Item $swap -Recurse -Force }
    Copy-Tree $cur.Dir $swap $prevFiles     # current copies of the files we're about to restore
    Copy-Tree $prev $cur.Dir
    Remove-Item $prev -Recurse -Force
    Move-Item $swap $prev
    $now = (Get-Item (Join-Path $cur.Dir "$app.exe")).VersionInfo.ProductVersion
    Log "rollback ${app}: $($cur.Version) -> $now (the $($cur.Version) files are now in previous\)"
    exit 0
}

# ---- Install: add a new app folder from its latest release ------------------------------------
if ($PSCmdlet.ParameterSetName -eq 'Install') {
    $app = $Install.ToLower()
    if (Get-InstalledApps | Where-Object Name -eq $app) { Log "install ${app}: already in $Root. Use -Apply to update it."; exit 1 }
    $pkg = Get-VerifiedPackage $app (Get-Latest $app)
    if (-not $pkg) { exit 1 }
    $dir = Join-Path $Root ($app.Substring(0,1).ToUpper() + $app.Substring(1))   # Pdfcraft, like the others
    Copy-Tree $pkg $dir
    Log "install ${app}: $((Get-Item (Join-Path $dir "$app.exe")).VersionInfo.ProductVersion) installed in $dir"
    Remove-Item $Staging\* -Recurse -Force -ErrorAction SilentlyContinue
    # file types, Default apps and Start menu (only knows the apps listed in register-apps.ps1)
    if (-not $NoRegister) { & (Join-Path $PSScriptRoot 'register-apps.ps1') -Only $app }
    exit 0
}

# ---- Uninstall: remove an app -------------------------------------------------------------------
if ($PSCmdlet.ParameterSetName -eq 'Uninstall') {
    $app = $Uninstall.ToLower()
    $cur = Get-InstalledApps | Where-Object Name -eq $app
    if (-not $cur) { Log "uninstall ${app}: not found in $Root"; exit 1 }
    if (Test-Running $app $cur.Dir) { exit 1 }
    if ($KeepData) {
        # remove only what a release puts in the folder; settings, data folders and your own files stay
        Get-ChildItem $cur.Dir -File -Force | Where-Object { $_.Name -match '(?i)^(.+\.(exe|dll)|LICENSE-.+|NOTICE|OFL-.+\.txt|README\.md|ATTRIBUTION.*|portable\.txt)$' } | Remove-Item -Force
        Remove-Item (Join-Path $cur.Dir 'models') -Recurse -Force -ErrorAction SilentlyContinue
        $left = @(Get-ChildItem $cur.Dir -Force)
        if ($left) { Log "uninstall ${app}: removed. Kept in $($cur.Dir): $($left.Name -join ', ')" }
        else { Remove-Item $cur.Dir -Force; Log "uninstall ${app}: removed" }
    } else {
        Remove-Item $cur.Dir -Recurse -Force
        Log "uninstall ${app}: folder deleted"
    }
    Remove-Item (Join-Path $Previous $app) -Recurse -Force -ErrorAction SilentlyContinue
    # the .exe is gone, so this clears just this app's file types, Default apps entry and shortcut
    if (-not $NoRegister) { & (Join-Path $PSScriptRoot 'register-apps.ps1') -Only $app }
    exit 0
}

# ---- Verify: compare installed .exes against the release they claim to be ---------------------
if ($Verify) {
    Log '--- verify run ---'
    foreach ($a in Get-InstalledApps) {
        try {
            $pkg = Get-VerifiedPackage $a.Name (Get-Release $a.Name $a.Version)
            if (-not $pkg) { continue }
            $bad = Get-ChildItem $pkg -Filter *.exe -Recurse | Where-Object {
                $local = Join-Path $a.Dir $_.Name
                -not (Test-Path $local) -or (Get-FileHash $local).Hash -ne (Get-FileHash $_.FullName).Hash
            }
            if ($bad) { Log "$($a.Name) $($a.Version): DIFFERS from the official release: $($bad.Name -join ', ')" }
            else { Log "$($a.Name) $($a.Version): matches the official release" }
        } catch { Log "$($a.Name): verify failed: $($_.Exception.Message)" }
        finally { Remove-Item $Staging\* -Recurse -Force -ErrorAction SilentlyContinue }
    }
    Remove-Item $Staging\* -Recurse -Force -ErrorAction SilentlyContinue
    exit 0
}

# ---- Update ---------------------------------------------------------------------------------
Log ('--- {0}{1} ---' -f $(if ($Apply) { 'update run' } else { 'dry run (add -Apply to install)' }), $(if ($IsRetry) { ' (retry)' } elseif ($Scheduled) { ' (scheduled)' }))

$installed = @(Get-InstalledApps)
if (-not $installed) {
    # most likely run from the wrong folder (e.g. an unzipped download), not the install folder
    Log "no Craft apps found in $Root. Nothing checked."
    exit 1
}

if ($Scheduled) {
    # a weekly run replaces any retry still pending from last time
    if (-not $IsRetry) { Unregister-ScheduledTask -TaskName $RetryTaskName -Confirm:$false -ErrorAction SilentlyContinue }
    Wait-AfterLogin
}

if (-not (Test-Online)) {
    if ($Scheduled -and -not $IsRetry) {
        Register-Retry
        Log ("can't reach GitHub (no internet?). Trying again at {0:h:mm tt}." -f ((Get-Date) + $RetryAfter))
    } elseif ($IsRetry) {
        Log "still can't reach GitHub. Skipping until the next weekly run."
    } else {
        Log "can't reach GitHub (no internet?). Nothing checked."
    }
    exit 1
}

foreach ($a in $installed) {
    if ($Only -and $a.Name -notin $Only) { continue }
    try {
        $latest = Get-Latest $a.Name
        $new = $latest.tag_name.TrimStart('v')
        if ([version]$new -le [version]$a.Version -and -not $Force) { Log "$($a.Name) $($a.Version): up to date"; continue }
        if (-not $Apply) { Log "$($a.Name): $($a.Version) -> $new available"; continue }
        if (Test-Running $a.Name $a.Dir) { continue }

        $pkg = Get-VerifiedPackage $a.Name $latest
        if (-not $pkg) { continue }

        # back up just the files the new version replaces; your data isn't in the zip so isn't touched.
        # A forced reinstall of the same version keeps the existing backup, which is the real older version.
        $same = [version]$new -eq [version]$a.Version
        $prev = Join-Path $Previous $a.Name
        if (-not $same) {
            $incoming = Get-ChildItem $pkg -Recurse -File | ForEach-Object { $_.FullName.Substring($pkg.Length).TrimStart('\') }
            if (Test-Path $prev) { Remove-Item $prev -Recurse -Force }
            Copy-Tree $a.Dir $prev $incoming
        }
        try { Copy-Tree $pkg $a.Dir }
        catch {
            # half old and half new is worse than not updated: put back what was just saved
            $why = $_.Exception.Message
            if (-not $same) {
                Copy-Tree $prev $a.Dir
                Log "$($a.Name): install failed ($why). Restored $($a.Version)."
                continue
            }
            throw
        }

        $now = (Get-Item (Join-Path $a.Dir "$($a.Name).exe")).VersionInfo.ProductVersion
        if ($same) { Log "$($a.Name): $now reinstalled (previous\ left as it was)" }
        else { Log "$($a.Name): $($a.Version) -> $now installed ($($a.Version) kept in previous\)" }
    } catch {
        Log "$($a.Name): failed: $($_.Exception.Message)"
    } finally {
        # one app's download at a time, not all twelve
        Remove-Item $Staging\* -Recurse -Force -ErrorAction SilentlyContinue
    }
}

foreach ($m in $MsiApps) {
    try {
        # -match ignores case, so "PdfCraft" matches "pdfcraft"
        $reg = Get-ItemProperty HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*, HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\* -ErrorAction SilentlyContinue |
            Where-Object DisplayName -match "^$m$" | Select-Object -First 1
        if (-not $reg) { Log "${m}: .msi install not found"; continue }
        $new = (Get-Latest $m).tag_name.TrimStart('v')
        if ([version]$new -gt [version]$reg.DisplayVersion) {
            Log "${m} (.msi): $($reg.DisplayVersion) -> $new available. Download $m-$new-windows-x64.msi and install it by hand."
        } else { Log "${m} (.msi) $($reg.DisplayVersion): up to date" }
    } catch { Log "${m}: check failed: $($_.Exception.Message)" }
}

Remove-Item $Staging\* -Recurse -Force -ErrorAction SilentlyContinue
