<#
.SYNOPSIS
  A window for installing, updating, rolling back and removing the Craft apps.

.DESCRIPTION
  Pick apps from the list and click Install / update. Apps come straight from each project's latest
  GitHub release, checked against its published checksums. Everything the window does is done by
  the scripts next to it (update-craftwerk.ps1, register-apps.ps1, setup-schedule.ps1); it only
  chooses what to run and shows the output.

  Run from a package folder (with a tools\ folder beside this file) it installs those scripts, and
  itself, into <install folder>\_update. Run from there, it manages that install.

  -SelfTest builds the window without showing it, loads the list, optionally checks and runs the
  given apps, prints what happened and exits. It's how the window is checked without a person.
#>
param(
    [string]$Root,
    [switch]$SelfTest,
    [string[]]$SelfTestApps,
    [ValidateSet('install', 'remove', 'rollback')][string]$SelfTestAction = 'install',
    [string]$SelfTestScreenshot     # save a picture of the window here
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Here      = $PSScriptRoot
$InInstall = (Split-Path $Here -Leaf) -eq '_update'
$ToolsSrc  = if ($InInstall) { $Here } else { Join-Path $Here 'tools' }
if (-not $Root) { $Root = if ($InInstall) { Split-Path $Here -Parent } else { 'C:\CraftWerk' } }

$Version  = '0.2.0'
$Owner    = 'storytold'
$Headers  = @{ 'User-Agent' = 'craftwerk-manager' }
$TaskName = 'CraftWerk updater'
$Arch     = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
$ArchName = switch ($Arch) { 'ARM64' { 'Windows ARM64' } 'x86' { 'Windows x86' } default { 'Windows x64' } }

# what each app opens, so the list says what it's for
$Catalog = [ordered]@{
    cadcraft    = @{ Name = 'CadCraft';    Desc = 'CAD drawings (.dxf, .dwg)' }
    deckcraft   = @{ Name = 'DeckCraft';   Desc = 'Presentations (.pptx)' }
    designcraft = @{ Name = 'DesignCraft'; Desc = 'Page layout (.idml)' }
    effectcraft = @{ Name = 'EffectCraft'; Desc = 'Motion graphics and animation' }
    filmcraft   = @{ Name = 'FilmCraft';   Desc = 'Video editing' }
    gridcraft   = @{ Name = 'GridCraft';   Desc = 'Spreadsheets (.xlsx, .csv)' }
    lightcraft  = @{ Name = 'LightCraft';  Desc = 'Photo library and camera RAW developing' }
    pdfcraft    = @{ Name = 'PdfCraft';    Desc = 'PDF viewing and editing' }
    photocraft  = @{ Name = 'PhotoCraft';  Desc = 'Image editing (.psd, .png, .jpg)' }
    soundcraft  = @{ Name = 'SoundCraft';  Desc = 'Audio editing (.wav, .mp3, .mid)' }
    vectorcraft = @{ Name = 'VectorCraft'; Desc = 'Vector illustration (.svg, .ai)' }
    wordcraft   = @{ Name = 'WordCraft';   Desc = 'Documents (.docx, .odt, .rtf)' }
}

# one place for everything that changes while the window runs (handlers can't assign script variables)
$State = @{ Root = $Root; Busy = $false; Info = @{}; TaskExists = $false; Proc = $null; LogPath = $null; LogPos = 0; Queue = $null }

# [IO.Path]::Combine, not Join-Path: Join-Path throws on a drive letter that doesn't exist, and a
# mistyped install folder should just show "Not installed"
function Get-AppDir($id)  { [IO.Path]::Combine($State.Root, $id.Substring(0,1).ToUpper() + $id.Substring(1)) }
function Get-Updater      { [IO.Path]::Combine($State.Root, '_update\update-craftwerk.ps1') }

function Get-InstalledVersion($id) {
    $exe = [IO.Path]::Combine((Get-AppDir $id), "$id.exe")
    if (Test-Path $exe) { return (Get-Item $exe).VersionInfo.ProductVersion }
}

function Get-LatestVersion($id) {
    try { return (Invoke-RestMethod "https://api.github.com/repos/$Owner/$id/releases/latest" -Headers $Headers -TimeoutSec 15).tag_name.TrimStart('v') }
    catch { }
    # the API allows 60 lookups an hour per IP address, which a shared network can use up; the plain
    # release page redirects to the latest tag and has no such limit
    try {
        $req = [Net.HttpWebRequest]::Create("https://github.com/$Owner/$id/releases/latest")
        $req.AllowAutoRedirect = $false; $req.UserAgent = $Headers['User-Agent']; $req.Timeout = 15000
        $resp = $req.GetResponse()
        try { return ($resp.Headers['Location'] -split '/')[-1].TrimStart('v') } finally { $resp.Close() }
    } catch { }
    return $null
}

function Test-TaskForThisFolder {
    $t = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    return [bool]($t -and $t.Actions[0].Arguments -like "*$($State.Root)\_update\*")
}

# ---- window ------------------------------------------------------------------------------------
$form = New-Object Windows.Forms.Form
$form.Text = "CraftWerk Manager $Version"
$form.Font = New-Object Drawing.Font('Segoe UI', 9)
$form.StartPosition = 'CenterScreen'
# fit small or scaled-up screens (a 768-pixel-high laptop screen is common)
$room = [Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$form.ClientSize = New-Object Drawing.Size(780, [math]::Min(640, $room.Height - 60))
$form.MinimumSize = New-Object Drawing.Size(680, [math]::Min(560, $room.Height - 60))

$grid = New-Object Windows.Forms.TableLayoutPanel
$grid.Dock = 'Fill'; $grid.ColumnCount = 1; $grid.RowCount = 6; $grid.Padding = New-Object Windows.Forms.Padding(12)
foreach ($h in 'AutoSize', 'Percent:100', 'AutoSize', 'AutoSize', 'Absolute:150', 'AutoSize') {
    $kind, $size = $h -split ':'
    $style = if ($kind -eq 'Percent') { New-Object Windows.Forms.RowStyle('Percent', [single]$size) }
             elseif ($kind -eq 'Absolute') { New-Object Windows.Forms.RowStyle('Absolute', [single]$size) }
             else { New-Object Windows.Forms.RowStyle('AutoSize') }
    $null = $grid.RowStyles.Add($style)
}
$form.Controls.Add($grid)

# row 0: install folder
$rowFolder = New-Object Windows.Forms.FlowLayoutPanel
$rowFolder.AutoSize = $true; $rowFolder.Dock = 'Fill'; $rowFolder.WrapContents = $false
$lblFolder = New-Object Windows.Forms.Label
$lblFolder.Text = 'Install folder:'; $lblFolder.AutoSize = $true; $lblFolder.Margin = New-Object Windows.Forms.Padding(0, 7, 6, 0)
$txtRoot = New-Object Windows.Forms.TextBox
$txtRoot.Width = 440; $txtRoot.Text = $State.Root
$btnBrowse = New-Object Windows.Forms.Button
$btnBrowse.Text = 'Browse...'; $btnBrowse.AutoSize = $true
$lblArch = New-Object Windows.Forms.Label
$lblArch.Text = $ArchName; $lblArch.AutoSize = $true; $lblArch.ForeColor = [Drawing.SystemColors]::GrayText; $lblArch.Margin = New-Object Windows.Forms.Padding(10, 7, 0, 0)
$rowFolder.Controls.AddRange(@($lblFolder, $txtRoot, $btnBrowse, $lblArch))
$grid.Controls.Add($rowFolder, 0, 0)

# row 1: the list
$list = New-Object Windows.Forms.ListView
$list.Dock = 'Fill'; $list.View = 'Details'; $list.CheckBoxes = $true; $list.FullRowSelect = $true; $list.HideSelection = $false
$null = $list.Columns.Add('App', 120)
$null = $list.Columns.Add('Status', 250)
$null = $list.Columns.Add('Opens', 340)
$list.Margin = New-Object Windows.Forms.Padding(0, 8, 0, 8)
$grid.Controls.Add($list, 0, 1)

# row 2: options
$rowOptions = New-Object Windows.Forms.FlowLayoutPanel
$rowOptions.AutoSize = $true; $rowOptions.Dock = 'Fill'
$chkRegister = New-Object Windows.Forms.CheckBox
$chkRegister.Text = 'Set up file types and Start menu shortcuts'; $chkRegister.AutoSize = $true; $chkRegister.Checked = $true
$chkWeekly = New-Object Windows.Forms.CheckBox
$chkWeekly.Text = 'Check for updates every week'; $chkWeekly.AutoSize = $true; $chkWeekly.Checked = $true
$rowOptions.Controls.AddRange(@($chkRegister, $chkWeekly))
$grid.Controls.Add($rowOptions, 0, 2)

# row 3: buttons
$rowButtons = New-Object Windows.Forms.FlowLayoutPanel
$rowButtons.AutoSize = $true; $rowButtons.Dock = 'Fill'
$btnGo       = New-Object Windows.Forms.Button; $btnGo.Text = 'Install / update checked'; $btnGo.AutoSize = $true
$btnRemove   = New-Object Windows.Forms.Button; $btnRemove.Text = 'Remove checked'; $btnRemove.AutoSize = $true
$btnRollback = New-Object Windows.Forms.Button; $btnRollback.Text = 'Roll back checked'; $btnRollback.AutoSize = $true
$btnRefresh  = New-Object Windows.Forms.Button; $btnRefresh.Text = 'Refresh'; $btnRefresh.AutoSize = $true
$rowButtons.Controls.AddRange(@($btnGo, $btnRemove, $btnRollback, $btnRefresh))
$grid.Controls.Add($rowButtons, 0, 3)

# row 4: output, row 5: status line
$txtLog = New-Object Windows.Forms.TextBox
$txtLog.Multiline = $true; $txtLog.ReadOnly = $true; $txtLog.ScrollBars = 'Vertical'; $txtLog.Dock = 'Fill'
$txtLog.Font = New-Object Drawing.Font('Consolas', 9)
$txtLog.Margin = New-Object Windows.Forms.Padding(0, 8, 0, 4)
$grid.Controls.Add($txtLog, 0, 4)
$lblStatus = New-Object Windows.Forms.Label
$lblStatus.AutoSize = $true; $lblStatus.Text = 'Ready.'
$grid.Controls.Add($lblStatus, 0, 5)

function Add-Output([string]$text) {
    if ($text) { $txtLog.AppendText($text) }
}

# A path or name inside single quotes in a generated script. Doubles any ' so a folder like O'Brien
# can't end the string early.
function Q([string]$s) { "'" + $s.Replace("'", "''") + "'" }

# Errors inside a button's handler are hidden, so show them: in the output box and a message.
function Invoke-Safe([scriptblock]$action) {
    try { & $action }
    catch {
        Add-Output "Error: $($_.Exception.Message)`r`n"
        if (-not $SelfTest) { [Windows.Forms.MessageBox]::Show("Something went wrong:`n`n$($_.Exception.Message)", 'CraftWerk Manager', 'OK', 'Error') | Out-Null }
        $running = $State.Proc -and -not $State.Proc.HasExited
        if ($State.Busy -and -not $running) { Set-Busy $false 'Ready.' }
    }
}

function Set-Busy([bool]$busy, [string]$message) {
    $State.Busy = $busy
    foreach ($c in $btnGo, $btnRemove, $btnRollback, $btnRefresh, $btnBrowse, $txtRoot, $chkRegister, $chkWeekly, $list) { $c.Enabled = -not $busy }
    $lblStatus.Text = $message
    [Windows.Forms.Application]::DoEvents()
}

# Rebuilds the list from what's installed. Only installed apps are checked against GitHub.
function Update-List {
    $typed = $txtRoot.Text.Trim()
    if (-not $typed) { $typed = 'C:\CraftWerk'; $txtRoot.Text = $typed }
    if ($typed.Length -gt 3) { $typed = $typed.TrimEnd('\') }     # keep "C:\" whole
    $State.Root = $typed
    $State.Info = @{}
    Set-Busy $true 'Checking installed apps...'
    $message = 'Ready.'
    try {
        $list.Items.Clear()
        foreach ($id in $Catalog.Keys) {
            $item = New-Object Windows.Forms.ListViewItem($Catalog[$id].Name)
            $item.Tag = $id
            $installed = Get-InstalledVersion $id
            $info = @{ Installed = $installed; Latest = $null; Update = $false }
            if (-not $installed) {
                $null = $item.SubItems.Add('Not installed')
            } else {
                $info.Latest = Get-LatestVersion $id
                try { $info.Update = $info.Latest -and ([version]$info.Latest -gt [version]$installed) } catch { }
                $text = if ($info.Update) { "Update available: $installed -> $($info.Latest)" }
                        elseif ($info.Latest) { "Installed $installed (up to date)" }
                        else { "Installed $installed (couldn't check for updates)" }
                $null = $item.SubItems.Add($text)
                $item.Checked = [bool]$info.Update
            }
            $null = $item.SubItems.Add($Catalog[$id].Desc)
            $State.Info[$id] = $info
            $null = $list.Items.Add($item)
            [Windows.Forms.Application]::DoEvents()
        }
        $State.TaskExists = Test-TaskForThisFolder
        $chkWeekly.Checked = $State.TaskExists -or -not (Test-Path ([IO.Path]::Combine($State.Root, '_update')))
        $updates = @($State.Info.Values | Where-Object Update).Count
        if ($updates) { $message = "$updates update(s) available, checked in the list." }
    } finally {
        # whatever happened above, don't leave every button grayed out
        Set-Busy $false $message
    }
}

# Puts the scripts (and this window) in <install folder>\_update, where the weekly task will find them.
function Install-Tools {
    $dest = Join-Path $State.Root '_update'
    $null = New-Item -ItemType Directory -Path $dest -Force
    if ((Resolve-Path $ToolsSrc).Path -ne (Resolve-Path $dest).Path) {
        Get-ChildItem $ToolsSrc -File | Where-Object { $_.Extension -in '.ps1', '.cmd' } | Copy-Item -Destination $dest -Force
        if (-not $InInstall) {
            Copy-Item $PSCommandPath (Join-Path $dest 'CraftWerk-Manager.ps1') -Force
            Copy-Item (Join-Path $Here 'CraftWerk Setup.cmd') (Join-Path $dest 'CraftWerk Manager.cmd') -Force
        }
    }
    Get-ChildItem $dest -File | Unblock-File
}

# Runs the lines in a child PowerShell and shows its output as it arrives.
function Start-Queue([string[]]$lines, [string]$what) {
    $temp = [IO.Path]::GetTempPath()
    $script = Join-Path $temp 'craftwerk-queue.ps1'
    $State.LogPath = Join-Path $temp 'craftwerk-queue.log'
    Set-Content -Path $script -Value $lines -Encoding UTF8
    Set-Content -Path $State.LogPath -Value '' -Encoding ASCII
    $State.LogPos = 0
    $psi = New-Object Diagnostics.ProcessStartInfo('cmd.exe', "/c powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$script`" > `"$($State.LogPath)`" 2>&1")
    $psi.CreateNoWindow = $true; $psi.UseShellExecute = $false
    $State.Queue = $script
    $State.Proc = [Diagnostics.Process]::Start($psi)
    Set-Busy $true $what
    $timer.Start()
}

function Read-NewOutput {
    $fs = [IO.File]::Open($State.LogPath, 'Open', 'Read', 'ReadWrite')
    try {
        $null = $fs.Seek($State.LogPos, 'Begin')
        $sr = New-Object IO.StreamReader($fs, [Text.Encoding]::GetEncoding([Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage))
        $text = $sr.ReadToEnd()
        $State.LogPos = $fs.Position
    } finally { $fs.Dispose() }
    Add-Output $text
}

$timer = New-Object Windows.Forms.Timer
$timer.Interval = 300
$timer.Add_Tick({
    Invoke-Safe {
        Read-NewOutput
        if ($State.Proc.HasExited) {
            $timer.Stop()
            Read-NewOutput
            Add-Output "`r`nDone.`r`n"
            Remove-Item $State.Queue, $State.LogPath -ErrorAction SilentlyContinue
            Update-List
        }
    }
})

function Get-Checked { @($list.CheckedItems | ForEach-Object { $_.Tag }) }

function Confirm-Remove([string]$names) {
    if ($SelfTest) { return 'Yes' }
    [Windows.Forms.MessageBox]::Show("Remove $names?`n`nYes: remove the app but keep my settings and files`nNo: delete the app's whole folder`nCancel: do nothing", 'Remove', 'YesNoCancel', 'Question').ToString()
}

$btnBrowse.Add_Click({
    Invoke-Safe {
        $dlg = New-Object Windows.Forms.FolderBrowserDialog
        $dlg.Description = 'Choose the folder the apps live in (or should be installed to)'
        $dlg.SelectedPath = $txtRoot.Text
        if ($dlg.ShowDialog() -eq 'OK') { $txtRoot.Text = $dlg.SelectedPath; Update-List }
    }
})
$btnRefresh.Add_Click({ Invoke-Safe { Update-List } })

$btnGo.Add_Click({
    Invoke-Safe {
        $updater = Q (Get-Updater)
        $toolsDir = Join-Path $State.Root '_update'
        $installs = @(); $updates = @()
        foreach ($id in Get-Checked) {
            if (-not $State.Info[$id].Installed) { $installs += $id } elseif ($State.Info[$id].Update) { $updates += $id }
        }
        $weeklyChange = $chkWeekly.Checked -ne $State.TaskExists
        if (-not ($installs -or $updates -or $weeklyChange)) {
            if (-not $SelfTest) { [Windows.Forms.MessageBox]::Show('Nothing to do. Check an app that is not installed or has an update.', 'CraftWerk Manager') | Out-Null }
            Add-Output "Nothing to do.`r`n"
            return
        }
        Install-Tools
        $lines = @("`$ErrorActionPreference = 'Continue'")
        foreach ($id in $installs) {
            $lines += "Write-Host 'Installing $($Catalog[$id].Name)...'"
            $lines += "& $updater -Install '$id' -NoRegister"
        }
        if ($updates) {
            $lines += "Write-Host 'Updating...'"
            $lines += "& $updater -Apply -Only '$($updates -join "','")'"
        }
        if ($chkRegister.Checked) {
            $lines += "Write-Host 'Setting up file types and shortcuts...'"
            $lines += "& $(Q "$toolsDir\register-apps.ps1")"
            if (-not $SelfTest) { $lines += "`$s = (New-Object -ComObject WScript.Shell).CreateShortcut((Join-Path ([Environment]::GetFolderPath('Programs')) 'CraftWerk Manager.lnk')); `$s.TargetPath = $(Q "$toolsDir\CraftWerk Manager.cmd"); `$s.WorkingDirectory = $(Q $toolsDir); `$s.Save()" }
        }
        if ($weeklyChange) {
            $lines += "Write-Host 'Weekly updates...'"
            $lines += "& $(Q "$toolsDir\setup-schedule.ps1") -SkipUpdate -NoRegister" + $(if (-not $chkWeekly.Checked) { ' -Remove' })
        }
        Start-Queue $lines 'Working... this can take a few minutes while apps download.'
    }
})

$btnRemove.Add_Click({
    Invoke-Safe {
        $ids = @(Get-Checked | Where-Object { $State.Info[$_].Installed })
        if (-not $ids) { if (-not $SelfTest) { [Windows.Forms.MessageBox]::Show('Check the installed apps you want to remove.', 'CraftWerk Manager') | Out-Null }; return }
        $answer = Confirm-Remove (($ids | ForEach-Object { $Catalog[$_].Name }) -join ', ')
        if ($answer -eq 'Cancel') { return }
        $keep = if ($answer -eq 'Yes') { ' -KeepData' } else { '' }
        $reg = if ($chkRegister.Checked) { '' } else { ' -NoRegister' }
        Install-Tools     # run the scripts that came with this window, not an older installed copy
        $lines = @("`$ErrorActionPreference = 'Continue'")
        foreach ($id in $ids) { $lines += "& $(Q (Get-Updater)) -Uninstall '$id'$keep$reg" }
        Start-Queue $lines 'Removing...'
    }
})

$btnRollback.Add_Click({
    Invoke-Safe {
        $ids = @(Get-Checked | Where-Object { $State.Info[$_].Installed })
        $withBackup = @($ids | Where-Object { Test-Path (Join-Path $State.Root "_update\previous\$_") })
        if (-not $withBackup) {
            $msg = 'None of the checked apps has an older version saved. A version is saved each time an app is updated.'
            if (-not $SelfTest) { [Windows.Forms.MessageBox]::Show($msg, 'CraftWerk Manager') | Out-Null }
            Add-Output "$msg`r`n"
            return
        }
        Install-Tools
        $lines = @("`$ErrorActionPreference = 'Continue'")
        foreach ($id in $withBackup) { $lines += "& $(Q (Get-Updater)) -Rollback '$id'" }
        Start-Queue $lines 'Rolling back...'
    }
})

$form.Add_FormClosing({
    if ($State.Busy -and -not $SelfTest) {
        if ([Windows.Forms.MessageBox]::Show('Still working. Closing now can leave an app half installed. Close anyway?', 'CraftWerk Manager', 'YesNo', 'Warning') -ne 'Yes') { $_.Cancel = $true }
    }
})

# ---- run ----------------------------------------------------------------------------------------
try {
    if ($SelfTest) {
        $form.Opacity = 0; $form.ShowInTaskbar = $false
        $form.Show()
        Invoke-Safe { Update-List }
        # a self-test must not touch the real file associations or the real weekly task
        $chkRegister.Checked = $false
        $chkWeekly.Checked = $false
        if ($SelfTestApps) {
            $SelfTestApps = @($SelfTestApps -split ',')     # -File passes "a,b" as one string
            foreach ($it in $list.Items) { $it.Checked = $it.Tag -in $SelfTestApps }
            switch ($SelfTestAction) { 'remove' { $btnRemove.PerformClick() } 'rollback' { $btnRollback.PerformClick() } default { $btnGo.PerformClick() } }
            $deadline = (Get-Date).AddMinutes(8)
            while ($State.Busy -and (Get-Date) -lt $deadline) { [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 100 }
            if ($State.Busy) { Write-Host 'SELFTEST: timed out' }
        }
        if ($SelfTestScreenshot) {
            $bmp = New-Object Drawing.Bitmap($form.Width, $form.Height)
            $form.DrawToBitmap($bmp, (New-Object Drawing.Rectangle(0, 0, $form.Width, $form.Height)))
            $bmp.Save($SelfTestScreenshot, [Drawing.Imaging.ImageFormat]::Png)
            $bmp.Dispose()
        }
        Write-Host '--- output shown in the window:'
        Write-Host $txtLog.Text
        Write-Host '--- list:'
        foreach ($it in $list.Items) { Write-Host ("{0,-12} | {1}" -f $it.Text, $it.SubItems[1].Text) }
        $form.Close()
    } else {
        $form.Add_Shown({ Invoke-Safe { Update-List } })
        [void]$form.ShowDialog()
    }
} catch {
    if ($SelfTest) { throw }
    [Windows.Forms.MessageBox]::Show("Something went wrong:`n`n$($_.Exception.Message)", 'CraftWerk Manager', 'OK', 'Error') | Out-Null
}
