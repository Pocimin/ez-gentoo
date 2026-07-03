$ErrorActionPreference = "Stop"

$repo = Resolve-Path (Join-Path $PSScriptRoot "..")
$project = Join-Path $repo "src\EzGentoo.Bootstrapper\EzGentoo.Bootstrapper.csproj"
$publish = Join-Path $repo "dist\publish"
$app = Join-Path $repo "dist\ez-gentoo-windows-x64"

if (Test-Path $publish) { Remove-Item -Recurse -Force $publish }
if (Test-Path $app) { Remove-Item -Recurse -Force $app }

dotnet publish $project `
    -c Release `
    -r win-x64 `
    --self-contained true `
    -p:PublishSingleFile=true `
    -p:IncludeNativeLibrariesForSelfExtract=true `
    -p:EnableCompressionInSingleFile=true `
    -o $publish

New-Item -ItemType Directory -Force -Path $app | Out-Null

Copy-Item (Join-Path $publish "EzGentooBootstrapper.exe") (Join-Path $app "EzGentooInstaller.exe")
Copy-Item (Join-Path $publish "EzGentooBootstrapper.exe") (Join-Path $app "EzGentooLauncher.exe")
Copy-Item (Join-Path $repo "README.md") $app
Copy-Item (Join-Path $repo "LICENSE") $app

$zip = Join-Path $repo "dist\ez-gentoo-windows-x64.zip"
if (Test-Path $zip) { Remove-Item -Force $zip }
Compress-Archive -Path (Join-Path $app "*") -DestinationPath $zip

Write-Host "Built $app"
Write-Host "Built $zip"
