param(
    [string]$VmName = "GentooReady",
    [string]$OutDir = ".\dist",
    [string]$OutName = "ez-gentoo-base.vhdx",
    [switch]$Zip
)

$ErrorActionPreference = "Stop"

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdmin)) {
    throw "Run this from an Administrator PowerShell."
}

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$vm = Get-VM -Name $VmName
if ($vm.State -ne "Off") {
    throw "Shut down '$VmName' first. Inside Gentoo, run: sudo poweroff"
}

$disk = Get-VMHardDiskDrive -VMName $VmName | Select-Object -First 1
if (-not $disk) {
    throw "No VM disk found for '$VmName'."
}

$destination = Join-Path (Resolve-Path $OutDir) $OutName
if (Test-Path $destination) {
    Remove-Item -LiteralPath $destination -Force
}

Write-Host "Exporting $($disk.Path)"
Write-Host "To        $destination"

Convert-VHD -Path $disk.Path -DestinationPath $destination -VHDType Dynamic

try {
    Optimize-VHD -Path $destination -Mode Full
}
catch {
    Write-Warning "Optimize-VHD skipped: $($_.Exception.Message)"
}

$hash = Get-FileHash -Algorithm SHA256 -Path $destination
$hashLine = "$($hash.Hash.ToLower())  $OutName"
Set-Content -Path "$destination.sha256" -Value $hashLine -Encoding ASCII

if ($Zip) {
    $zipPath = Join-Path (Resolve-Path $OutDir) "ez-gentoo-base.zip"
    if (Test-Path $zipPath) {
        Remove-Item -LiteralPath $zipPath -Force
    }
    Compress-Archive -Path $destination, "$destination.sha256" -DestinationPath $zipPath
    Write-Host "Created $zipPath"
}

Write-Host "Created $destination"
Write-Host "SHA256  $($hash.Hash.ToLower())"

