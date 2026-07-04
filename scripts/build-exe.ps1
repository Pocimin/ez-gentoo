$ErrorActionPreference = "Stop"

$repo = Resolve-Path (Join-Path $PSScriptRoot "..")
$build = Join-Path $repo "dist\build"
$app = Join-Path $repo "dist\ez-gentoo-windows-x64"

if (Test-Path $build) { Remove-Item -Recurse -Force $build }
if (Test-Path $app) { Remove-Item -Recurse -Force $app }
New-Item -ItemType Directory -Force -Path $build, $app | Out-Null

$vcvars = Get-ChildItem "C:\Program Files\Microsoft Visual Studio" -Recurse -Filter vcvars64.bat -ErrorAction SilentlyContinue |
    Select-Object -First 1 -ExpandProperty FullName

if (-not $vcvars) {
    throw "Visual Studio C++ build tools were not found. Install 'Desktop development with C++'."
}

$source = "`"$repo\src\EzGentoo.Native\main.cpp`""
$compile = "/nologo /std:c++20 /EHsc /O2 /DUNICODE /D_UNICODE /Fo`"$build\\`" /Fd`"$build\\ezgentoo.pdb`" $source"
$link = "/link /SUBSYSTEM:WINDOWS /MANIFESTUAC:`"level='requireAdministrator' uiAccess='false'`" urlmon.lib crypt32.lib ws2_32.lib shell32.lib ole32.lib comdlg32.lib user32.lib gdi32.lib advapi32.lib comctl32.lib"

cmd /c "`"$vcvars`" && cl $compile /Fe:`"$app\EzGentooInstaller.exe`" $link"
cmd /c "`"$vcvars`" && cl $compile /Fe:`"$app\EzGentooLauncher.exe`" $link"

Copy-Item (Join-Path $repo "README.md") $app
Copy-Item (Join-Path $repo "LICENSE") $app
if (Test-Path (Join-Path $repo "assets")) {
    Copy-Item (Join-Path $repo "assets") $app -Recurse
}

$zip = Join-Path $repo "dist\ez-gentoo-windows-x64.zip"
if (Test-Path $zip) { Remove-Item -Force $zip }
Compress-Archive -Path (Join-Path $app "*") -DestinationPath $zip

Write-Host "Built $app"
Write-Host "Built $zip"
