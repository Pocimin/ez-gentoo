$ErrorActionPreference = "Stop"

$repo = Resolve-Path (Join-Path $PSScriptRoot "..")
$work = Join-Path $repo "image-work"
$key = Join-Path $repo "ssh\gentoo_nopass_ed25519"
$sourceVm = "GentooReady"
$prepVm = "EzGentooImagePrep"
$image = Join-Path $work "ez-gentoo-base.vhdx"
$vps = "root@136.243.8.214"
$remotePartial = "/srv/ez-gentoo/ez-gentoo-base.vhdx.partial"
$remoteFinal = "/srv/ez-gentoo/ez-gentoo-base.vhdx"
$remoteSha = "/srv/ez-gentoo/ez-gentoo-base.vhdx.sha256"
$log = Join-Path $work "publish.log"

New-Item -ItemType Directory -Force -Path $work | Out-Null
Start-Transcript -Path $log -Force | Out-Null

function Say($message) {
    $stamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "$stamp  $message"
}

function Wait-Port($ip, $port, $minutes) {
    $deadline = (Get-Date).AddMinutes($minutes)
    while ((Get-Date) -lt $deadline) {
        if (Test-NetConnection -ComputerName $ip -Port $port -InformationLevel Quiet -WarningAction SilentlyContinue) {
            return $true
        }
        Start-Sleep -Seconds 3
    }
    return $false
}

function Find-VMIPv4($vmName, $minutes) {
    $deadline = (Get-Date).AddMinutes($minutes)
    while ((Get-Date) -lt $deadline) {
        $adapter = Get-VMNetworkAdapter -VMName $vmName
        $mac = (($adapter.MacAddress -replace '[^0-9A-Fa-f]', '').ToUpper() -replace '(.{2})(?!$)', '$1-')
        $ips = @($adapter.IPAddresses | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' })
        $ips += @(Get-NetNeighbor -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.LinkLayerAddress -eq $mac -and $_.State -notin @("Unreachable", "Incomplete") } |
            Select-Object -ExpandProperty IPAddress)

        foreach ($ip in ($ips | Select-Object -Unique)) {
            if (Wait-Port $ip 22 0.05) { return $ip }
        }
        Start-Sleep -Seconds 4
    }
    throw "Could not find SSH on $vmName."
}

$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { throw "Run this script as Administrator." }
if (-not (Test-Path $key)) { throw "Missing SSH key: $key" }

Say "Preparing VPS web folder."
ssh -i $key -o BatchMode=yes $vps "mkdir -p /srv/ez-gentoo && systemctl is-active --quiet ez-gentoo-files.service"

$source = (Get-VMHardDiskDrive -VMName $sourceVm).Path
$sourceState = (Get-VM -Name $sourceVm).State
if ($sourceState -ne "Off") { throw "$sourceVm must be Off before imaging. Current state: $sourceState" }

Say "Merging $sourceVm checkpoint chain into $image."
if (Test-Path $image) { Remove-Item -Force $image }
Convert-VHD -Path $source -DestinationPath $image -VHDType Dynamic

if (Get-VM -Name $prepVm -ErrorAction SilentlyContinue) {
    if ((Get-VM -Name $prepVm).State -ne "Off") { Stop-VM -Name $prepVm -TurnOff -Force }
    Remove-VM -Name $prepVm -Force
}

Say "Creating prep VM."
$prepPath = Join-Path $work "vm"
New-VM -Name $prepVm -Generation 2 -MemoryStartupBytes 4GB -VHDPath $image -Path $prepPath -SwitchName "Default Switch" | Out-Null
Set-VMFirmware -VMName $prepVm -EnableSecureBoot Off
Set-VMProcessor -VMName $prepVm -Count 4
Set-VMMemory -VMName $prepVm -DynamicMemoryEnabled $true -MinimumBytes 2GB -StartupBytes 4GB -MaximumBytes 4GB

Say "Booting prep VM."
Start-VM -Name $prepVm
$ip = Find-VMIPv4 $prepVm 5
Say "Prep VM SSH is at $ip."

$sanitize = @'
set -eu
printf 'ez-gentoo\n' > /etc/hostname
printf 'reina:LarpGentoo42!\n' | chpasswd
passwd -l root >/dev/null 2>&1 || true
rm -f /root/.ssh/authorized_keys /root/.ssh/known_hosts
rm -f /home/*/.ssh/authorized_keys /home/*/.ssh/known_hosts 2>/dev/null || true
find /root /home -maxdepth 3 -type f \( -name '.bash_history' -o -name '.zsh_history' -o -name '.lesshst' -o -name '.wget-hsts' -o -name 'history' \) -delete 2>/dev/null || true
find /tmp /var/tmp -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
find /var/log -type f -exec truncate -s 0 {} + 2>/dev/null || true
rm -rf /var/log/journal/* 2>/dev/null || true
rm -f /etc/ssh/ssh_host_*
systemctl disable sshd.service 2>/dev/null || true
cat > /etc/systemd/system/ez-gentoo-firstboot.service <<'EOF'
[Unit]
Description=ez gentoo first boot setup
Before=sshd.service
ConditionPathExists=!/var/lib/ez-gentoo-firstboot.done

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'ssh-keygen -A 2>/dev/null || true; systemd-machine-id-setup 2>/dev/null || true; mkdir -p /var/lib; touch /var/lib/ez-gentoo-firstboot.done; systemctl disable ez-gentoo-firstboot.service 2>/dev/null || true'

[Install]
WantedBy=multi-user.target
EOF
systemctl enable ez-gentoo-firstboot.service
: > /etc/machine-id
rm -f /var/lib/dbus/machine-id 2>/dev/null || true
ln -sf /etc/machine-id /var/lib/dbus/machine-id 2>/dev/null || true
sync
'@

$sanitizePath = Join-Path $work "sanitize-guest.sh"
[IO.File]::WriteAllText($sanitizePath, $sanitize, [Text.UTF8Encoding]::new($false))

Say "Sanitizing prep VM."
scp -i $key -o StrictHostKeyChecking=no -o UserKnownHostsFile=NUL $sanitizePath "root@${ip}:/tmp/sanitize-guest.sh"
ssh -i $key -o StrictHostKeyChecking=no -o UserKnownHostsFile=NUL "root@$ip" "sh /tmp/sanitize-guest.sh && rm -f /tmp/sanitize-guest.sh"

Say "Turning off prep VM."
Stop-VM -Name $prepVm -TurnOff -Force
$deadline = (Get-Date).AddMinutes(2)
while ((Get-Date) -lt $deadline -and (Get-VM -Name $prepVm).State -ne "Off") {
    Start-Sleep -Seconds 2
}
if ((Get-VM -Name $prepVm).State -ne "Off") {
    throw "$prepVm did not turn off cleanly."
}
Remove-VM -Name $prepVm -Force

Say "Compacting image."
Optimize-VHD -Path $image -Mode Full
$hash = (Get-FileHash $image -Algorithm SHA256).Hash.ToLowerInvariant()
$size = (Get-Item $image).Length
Set-Content -Path (Join-Path $work "ez-gentoo-base.vhdx.sha256") -Value "$hash  ez-gentoo-base.vhdx"
Say "Local image size: $size bytes"
Say "Local sha256: $hash"

Say "Uploading image to VPS."
scp -i $key -o BatchMode=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=20 $image "${vps}:$remotePartial"
ssh -i $key -o BatchMode=yes $vps "sha256sum $remotePartial > $remoteSha.tmp && mv $remotePartial $remoteFinal && sed 's/ez-gentoo-base.vhdx.partial/ez-gentoo-base.vhdx/' $remoteSha.tmp > $remoteSha && rm -f $remoteSha.tmp && ls -lh $remoteFinal $remoteSha && cat $remoteSha"

Say "Done: http://136.243.8.214:8088/ez-gentoo-base.vhdx"
Stop-Transcript | Out-Null
