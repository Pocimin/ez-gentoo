param(
    [string]$RepoDir = (Resolve-Path ".").Path
)

$desktop = [Environment]::GetFolderPath("Desktop")
$target = Join-Path $desktop "ez gentoo.bat"
$script = Join-Path $RepoDir "ez-gentoo.ps1"

if (-not (Test-Path $script)) {
    throw "Cannot find ez-gentoo.ps1 in $RepoDir"
}

@"
@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$script"
"@ | Set-Content -Path $target -Encoding ASCII

Write-Host "Created $target"

