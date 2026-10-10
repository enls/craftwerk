<#
.SYNOPSIS
  Registers the portable Craft apps with Windows the way an installer would, for your user only
  (no admin). For each app found in the CraftWerk folder:
    - its file types, so it's offered in Open with for each one
    - its entry in Settings > Apps > Default apps, by name and icon
    - a Start menu shortcut, and Win+R by name (e.g. "photocraft")
  Re-run it after moving the CraftWerk folder or adding an app.

  It never changes which app is the default for a file type; Windows only lets you do that,
  in Settings > Apps > Default apps.

  File types come from each app's own installer and docs (October 2026). Types an app can't open
  (legacy .ppt/.doc/.xls, .indd, .aep, .eps, ...) are deliberately left out.

.EXAMPLE
  .\register-apps.ps1           # register every app that's in the folder
  .\register-apps.ps1 -Remove   # undo everything this added
  .\register-apps.ps1 -Only wordcraft   # touch just this app (works with -Remove too)
#>
param(
    [switch]$Remove,
    [string[]]$Only
)

$ErrorActionPreference = 'Stop'
$Root    = Split-Path $PSScriptRoot -Parent
$Classes = 'HKCU:\Software\Classes'
$CapBase = 'Software\CraftWerk'                     # under HKCU; holds each app's Capabilities
$AppPaths = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\App Paths'
$Programs = [Environment]::GetFolderPath('Programs')

# Name: display name and Start menu shortcut. Types: ProgId = description, extensions.
# ProgIds match the apps' own .msi installers where they have one.
$Apps = [ordered]@{
    cadcraft = @{ Name = 'CadCraft'; Desc = 'Open-source CAD for DXF and DWG drawings'; Types = @(
        @{ ProgId = 'CADCraft.Drawing';         Desc = 'CAD Drawing';           Ext = 'dxf dwg' }) }
    deckcraft = @{ Name = 'DeckCraft'; Desc = 'Open-source presentation editor'; Types = @(
        @{ ProgId = 'DeckCraft.Presentation';   Desc = 'DeckCraft Presentation'; Ext = 'deckcraft pptx' }) }
    designcraft = @{ Name = 'DesignCraft'; Desc = 'Open-source page layout'; Types = @(
        @{ ProgId = 'DesignCraft.Document';     Desc = 'DesignCraft Document';   Ext = 'designcraft' }
        @{ ProgId = 'DesignCraft.Idml';         Desc = 'InDesign Markup (IDML)'; Ext = 'idml' }) }
    effectcraft = @{ Name = 'EffectCraft'; Desc = 'Open-source motion graphics'; Types = @(
        @{ ProgId = 'EffectCraft.Project';      Desc = 'EffectCraft Project';    Ext = 'ecproj' }) }
    filmcraft = @{ Name = 'FilmCraft'; Desc = 'Open-source video editor'; Types = @(
        @{ ProgId = 'FilmCraft.Project';        Desc = 'FilmCraft Project';      Ext = 'fcproj' }) }
    gridcraft = @{ Name = 'GridCraft'; Desc = 'Open-source spreadsheet for .xlsx, CSV and TSV files'; Types = @(
        @{ ProgId = 'GridCraft.Workbook';       Desc = 'GridCraft Workbook';     Ext = 'xlsx xlsm' }
        @{ ProgId = 'GridCraft.TextData';       Desc = 'GridCraft Text Data';    Ext = 'csv tsv' }) }
    lightcraft = @{ Name = 'LightCraft'; Desc = 'Open-source photo library and raw developer'; Types = @(
        @{ ProgId = 'LightCraft.Raw';           Desc = 'Camera Raw Image';       Ext = 'dng cr2 cr3 arw nef nrw raf rw2 rwl raw pef orf srw' }
        @{ ProgId = 'LightCraft.Image';         Desc = 'Image';                  Ext = 'jpg jpeg png tif tiff webp jxl psd' }) }
    pdfcraft = @{ Name = 'PdfCraft'; Desc = 'Open-source PDF workbench'; Types = @(
        @{ ProgId = 'PdfCraft.Document';        Desc = 'PDF Document';           Ext = 'pdf' }) }
    photocraft = @{ Name = 'PhotoCraft'; Desc = 'Open-source image editor'; Types = @(
        @{ ProgId = 'Photocraft.Document';      Desc = 'PhotoCraft Document';    Ext = 'pcraft' }
        @{ ProgId = 'Photocraft.PhotoshopDocument'; Desc = 'PSD Document';       Ext = 'psd psb' }
        @{ ProgId = 'Photocraft.Affinity';      Desc = 'Affinity Document';      Ext = 'af afdesign afphoto afpub' }
        @{ ProgId = 'Photocraft.Image';         Desc = 'Image';                  Ext = 'png jpg jpeg tif tiff webp gif bmp tga ico qoi pnm pbm pgm ppm exr hdr heic svg pdn' }) }
    soundcraft = @{ Name = 'SoundCraft'; Desc = 'Open-source audio editor'; Types = @(
        @{ ProgId = 'SoundCraft.Session';       Desc = 'SoundCraft Session';     Ext = 'scraft' }
        @{ ProgId = 'SoundCraft.Audio';         Desc = 'Audio File';             Ext = 'wav bwf rf64 aif aiff aifc flac mp3 ogg m4a aac caf' }
        @{ ProgId = 'SoundCraft.Midi';          Desc = 'MIDI File';              Ext = 'mid midi' }) }
    vectorcraft = @{ Name = 'VectorCraft'; Desc = 'Open-source vector illustration'; Types = @(
        @{ ProgId = 'VectorCraft.Document';     Desc = 'VectorCraft Document';   Ext = 'vectorcraft' }
        @{ ProgId = 'VectorCraft.Illustrator';  Desc = 'Illustrator Document';   Ext = 'ai' }
        @{ ProgId = 'VectorCraft.Affinity';     Desc = 'Affinity Document';      Ext = 'af afdesign afpub' }
        @{ ProgId = 'VectorCraft.Vector';       Desc = 'Vector Image';           Ext = 'svg svgz pdf emf wmf' }) }
    wordcraft = @{ Name = 'WordCraft'; Desc = 'Open-source word processor'; Types = @(
        @{ ProgId = 'WordCraft.Document';       Desc = 'Word Document';          Ext = 'docx' }
        @{ ProgId = 'WordCraft.OpenDocument';   Desc = 'OpenDocument Text';      Ext = 'odt' }
        @{ ProgId = 'WordCraft.Text';           Desc = 'Text Document';          Ext = 'rtf md html txt' }) }
}

# tells Explorer associations changed, so Open with and icons refresh without signing out
Add-Type -Namespace Win32 -Name Shell -MemberDefinition '[DllImport("shell32.dll")] public static extern void SHChangeNotify(int e, uint f, System.IntPtr a, System.IntPtr b);'

# Creates the key only if it's missing. Never use New-Item -Force on a key that may exist:
# in the registry it deletes everything already in it, including other apps' entries.
function Add-Key($path) {
    if (-not (Test-Path $path)) { New-Item -Path $path -Force | Out-Null }
}

function Set-Default($path, $value) {
    Add-Key $path
    Set-ItemProperty -Path $path -Name '(default)' -Value $value
}

function Get-AppExe($id) {
    $exe = Join-Path $Root ("{0}\{1}.exe" -f ($id.Substring(0,1).ToUpper() + $id.Substring(1)), $id)
    if (Test-Path $exe) { return $exe }
}

function Unregister-App($id, $app) {
    foreach ($t in $app.Types) {
        Remove-Item "$Classes\$($t.ProgId)" -Recurse -Force -ErrorAction SilentlyContinue
        foreach ($e in $t.Ext -split ' ') {
            Remove-ItemProperty "$Classes\.$e\OpenWithProgids" -Name $t.ProgId -ErrorAction SilentlyContinue
        }
    }
    Remove-Item "$Classes\Applications\$id.exe" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item "$AppPaths\$id.exe" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-ItemProperty 'HKCU:\Software\RegisteredApplications' -Name $app.Name -ErrorAction SilentlyContinue
    Remove-Item "HKCU:\$CapBase\$($app.Name)" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $Programs "$($app.Name).lnk") -Force -ErrorAction SilentlyContinue
}

$Ids = @($Apps.Keys | Where-Object { -not $Only -or $_ -in $Only })

if ($Remove) {
    foreach ($id in $Ids) { Unregister-App $id $Apps[$id] }
    if (-not $Only) {
        Remove-Item "HKCU:\$CapBase" -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item (Join-Path $Programs 'CraftWerk Manager.lnk') -Force -ErrorAction SilentlyContinue   # made by the window
    }
    [Win32.Shell]::SHChangeNotify(0x08000000, 0, [IntPtr]::Zero, [IntPtr]::Zero)
    Write-Host 'All Craft apps unregistered.'
    return
}

$shell = New-Object -ComObject WScript.Shell
foreach ($id in $Ids) {
    $app = $Apps[$id]
    $exe = Get-AppExe $id
    if (-not $exe) {
        # not in the folder (any more): clear anything left from an earlier registration
        Unregister-App $id $app
        continue
    }
    $open = "`"$exe`" `"%1`""
    $cap  = "HKCU:\$CapBase\$($app.Name)\Capabilities"
    Add-Key "$cap\FileAssociations"
    Set-ItemProperty $cap -Name ApplicationName -Value $app.Name
    Set-ItemProperty $cap -Name ApplicationDescription -Value $app.Desc
    Set-ItemProperty $cap -Name ApplicationIcon -Value "$exe,0"

    # how Windows names and launches the .exe itself (Open with list, Win+R)
    $appKey = "$Classes\Applications\$id.exe"
    Add-Key $appKey
    Set-ItemProperty $appKey -Name FriendlyAppName -Value $app.Name
    Set-Default "$appKey\shell\open\command" $open
    Add-Key "$appKey\SupportedTypes"
    Set-Default "$AppPaths\$id.exe" $exe
    Set-ItemProperty "$AppPaths\$id.exe" -Name Path -Value (Split-Path $exe)

    $count = 0
    foreach ($t in $app.Types) {
        Set-Default "$Classes\$($t.ProgId)" $t.Desc
        Set-Default "$Classes\$($t.ProgId)\DefaultIcon" "$exe,0"
        Set-Default "$Classes\$($t.ProgId)\shell\open\command" $open
        foreach ($e in $t.Ext -split ' ') {
            Add-Key "$Classes\.$e\OpenWithProgids"
            New-ItemProperty "$Classes\.$e\OpenWithProgids" -Name $t.ProgId -PropertyType None -Value ([byte[]]@()) -Force | Out-Null
            Set-ItemProperty "$cap\FileAssociations" -Name ".$e" -Value $t.ProgId
            New-ItemProperty "$appKey\SupportedTypes" -Name ".$e" -Value '' -Force | Out-Null
            $count++
        }
    }

    Add-Key 'HKCU:\Software\RegisteredApplications'
    Set-ItemProperty 'HKCU:\Software\RegisteredApplications' -Name $app.Name -Value "$CapBase\$($app.Name)\Capabilities"

    $lnk = $shell.CreateShortcut((Join-Path $Programs "$($app.Name).lnk"))
    $lnk.TargetPath = $exe
    $lnk.WorkingDirectory = Split-Path $exe
    $lnk.Save()

    Write-Host ("{0,-12} {1,2} file types" -f $app.Name, $count)
}

[Win32.Shell]::SHChangeNotify(0x08000000, 0, [IntPtr]::Zero, [IntPtr]::Zero)
Write-Host 'Done. Pick defaults in Settings > Apps > Default apps.'
