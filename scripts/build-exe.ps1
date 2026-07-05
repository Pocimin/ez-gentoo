$ErrorActionPreference = "Stop"

$repo = Resolve-Path (Join-Path $PSScriptRoot "..")
$imgui = Join-Path $repo "external\imgui"
$build = Join-Path $repo "dist\build"
$app = Join-Path $repo "dist\ez-gentoo-windows-x64"

if (-not (Test-Path $imgui)) {
    New-Item -ItemType Directory -Force -Path (Join-Path $repo "external") | Out-Null
    git clone --depth 1 https://github.com/ocornut/imgui.git $imgui
}

if (Test-Path $build) { Remove-Item -Recurse -Force $build }
if (Test-Path $app) { Remove-Item -Recurse -Force $app }
New-Item -ItemType Directory -Force -Path $build, $app | Out-Null

$vcvars = Get-ChildItem "C:\Program Files\Microsoft Visual Studio" -Recurse -Filter vcvars64.bat -ErrorAction SilentlyContinue |
    Select-Object -First 1 -ExpandProperty FullName

if (-not $vcvars) {
    throw "Visual Studio C++ build tools were not found. Install 'Desktop development with C++'."
}

$sources = @(
    "`"$repo\src\EzGentoo.Native\main.cpp`"",
    "`"$imgui\imgui.cpp`"",
    "`"$imgui\imgui_demo.cpp`"",
    "`"$imgui\imgui_draw.cpp`"",
    "`"$imgui\imgui_tables.cpp`"",
    "`"$imgui\imgui_widgets.cpp`"",
    "`"$imgui\backends\imgui_impl_win32.cpp`"",
    "`"$imgui\backends\imgui_impl_dx11.cpp`""
) -join " "

$compile = "/nologo /std:c++20 /EHsc /O2 /DUNICODE /D_UNICODE /Fo`"$build\\`" /Fd`"$build\\ezgentoo.pdb`" /I`"$imgui`" /I`"$imgui\backends`" $sources"
$link = "/link /SUBSYSTEM:WINDOWS /MANIFESTUAC:`"level='requireAdministrator' uiAccess='false'`" d3d11.lib dxgi.lib urlmon.lib crypt32.lib ws2_32.lib shell32.lib ole32.lib comdlg32.lib user32.lib gdi32.lib advapi32.lib"

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
