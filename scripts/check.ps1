$ErrorActionPreference = "Stop"

$scripts = @(
    "ez-gentoo.ps1",
    "scripts/build-exe.ps1",
    "scripts/export-current-vm.ps1",
    "scripts/install-desktop-shortcut.ps1",
    "launcher/GentooLauncher.ps1"
)

foreach ($script in $scripts) {
    if (-not (Test-Path $script)) {
        throw "Missing $script"
    }

    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $script), [ref]$tokens, [ref]$errors) | Out-Null

    if ($errors) {
        Write-Host "FAILED $script"
        $errors | Format-List *
        exit 1
    }

    Write-Host "OK $script"
}

Write-Host "All checks passed."

if (Test-Path "src/EzGentoo.Bootstrapper/EzGentoo.Bootstrapper.csproj") {
    dotnet build "src/EzGentoo.Bootstrapper/EzGentoo.Bootstrapper.csproj" -c Release --nologo
}
