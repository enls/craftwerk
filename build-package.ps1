<#
.SYNOPSIS
  Builds dist\CraftWerk-Manager.zip from this repo: the zip people download and run.
#>
$ErrorActionPreference = 'Stop'
$Src   = $PSScriptRoot
$Out   = Join-Path $Src 'dist'
$Stage = Join-Path $Out 'CraftWerk-Manager'
$Zip   = Join-Path $Out 'CraftWerk-Manager.zip'

if (Test-Path $Out) { Remove-Item $Out -Recurse -Force }
$null = New-Item -ItemType Directory (Join-Path $Stage 'tools') -Force

# the window and its launcher sit at the top; everything it runs goes in tools\
Copy-Item (Join-Path $Src 'CraftWerk-Manager.ps1') $Stage
Copy-Item (Join-Path $Src 'CraftWerk Setup.cmd') $Stage
Copy-Item (Join-Path $Src 'tools\*') (Join-Path $Stage 'tools')
Copy-Item (Join-Path $Src 'package\README.txt') $Stage

# Compress-Archive in Windows PowerShell 5.1 writes backslashes in entry names, which other unzip tools reject
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$archive = [IO.Compression.ZipFile]::Open($Zip, 'Create')
try {
    foreach ($f in Get-ChildItem $Stage -Recurse -File) {
        $name = 'CraftWerk-Manager/' + $f.FullName.Substring($Stage.Length + 1).Replace('\', '/')
        $null = [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $f.FullName, $name, 'Optimal')
    }
} finally { $archive.Dispose() }

Get-ChildItem $Stage -Recurse -File | ForEach-Object { '{0,-40} {1,8:N0} bytes' -f $_.FullName.Substring($Stage.Length + 1), $_.Length }
'{0}  ({1:N0} KB)' -f $Zip, ((Get-Item $Zip).Length / 1KB)
