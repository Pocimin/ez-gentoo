param(
    [string]$VmName = "EzGentoo",
    [string]$ImageUrl = "https://github.com/Pocimin/ez-gentoo/releases/latest/download/ez-gentoo-base.vhdx",
    [int]$MemoryGB = 4,
    [int]$CpuCount = 4,
    [int]$VncDisplay = 1,
    [int]$VncPort = 5901
)

$ErrorActionPreference = "Stop"

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdmin)) {
    Start-Process -FilePath "powershell.exe" -Verb RunAs -ArgumentList @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", "`"$PSCommandPath`"",
        "-VmName", "`"$VmName`"",
        "-ImageUrl", "`"$ImageUrl`"",
        "-MemoryGB", "$MemoryGB",
        "-CpuCount", "$CpuCount",
        "-VncDisplay", "$VncDisplay",
        "-VncPort", "$VncPort"
    )
    exit
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$AppDir = Join-Path $env:LOCALAPPDATA "EzGentoo"
$VmDir = Join-Path $AppDir "vm"
$ImagePath = Join-Path $AppDir "ez-gentoo-base.vhdx"
$LogPath = Join-Path $AppDir "ez-gentoo.log"
$ViewerPath = "C:\Program Files\TigerVNC\vncviewer.exe"
$MacAddress = $null
$CurrentIp = $null
$IsBusy = $false

New-Item -ItemType Directory -Force -Path $AppDir, $VmDir | Out-Null

function Write-AppLog([string]$Message) {
    $line = "{0:HH:mm:ss}  {1}" -f (Get-Date), $Message
    try { Add-Content -Path $LogPath -Value $line -Encoding ASCII } catch { }
    if ($script:LogBox) {
        $script:LogBox.AppendText($line + [Environment]::NewLine)
    }
}

function Set-Status([string]$Message, [int]$Percent = -1) {
    $script:StatusLabel.Text = $Message
    if ($Percent -ge 0) {
        $script:Progress.Value = [Math]::Max(0, [Math]::Min(100, $Percent))
    }
    [Windows.Forms.Application]::DoEvents()
}

function Set-Busy([bool]$Busy) {
    $script:IsBusy = $Busy
    $script:InstallButton.Enabled = -not $Busy
    $script:StartButton.Enabled = -not $Busy
    $script:StopButton.Enabled = -not $Busy
    $script:ViewerButton.Enabled = ((-not $Busy) -and $script:CurrentIp)
}

function Convert-MacToDashed([string]$Mac) {
    if ([string]::IsNullOrWhiteSpace($Mac)) { return $null }
    return (($Mac -replace '[^0-9A-Fa-f]', '').ToUpper() -replace '(.{2})(?!$)', '$1-')
}

function Install-WithWinget([string]$Id) {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        throw "winget is missing. Install $Id manually, then rerun ez gentoo."
    }
    Write-AppLog "Installing $Id with winget."
    winget install --id $Id --exact --accept-source-agreements --accept-package-agreements | Out-Null
}

function Ensure-Tooling {
    if (-not (Get-Command Get-VM -ErrorAction SilentlyContinue)) {
        throw "Hyper-V PowerShell tools are missing. Enable Hyper-V first."
    }

    if (-not (Test-Path $ViewerPath)) {
        Install-WithWinget "TigerVNC.TigerVNC"
    }
}

function Get-QemuImg {
    $cmd = Get-Command qemu-img -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    Install-WithWinget "cloudbase.qemu-img"
    $cmd = Get-Command qemu-img -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    $wingetPath = Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages" -Recurse -Filter qemu-img.exe -ErrorAction SilentlyContinue |
        Select-Object -First 1 -ExpandProperty FullName
    if ($wingetPath) { return $wingetPath }

    throw "qemu-img was not found after install."
}

function Select-LocalImage {
    $dialog = New-Object Windows.Forms.OpenFileDialog
    $dialog.Title = "Select ez gentoo base image"
    $dialog.Filter = "VM images (*.vhdx;*.qcow2)|*.vhdx;*.qcow2|All files (*.*)|*.*"
    if ($dialog.ShowDialog() -eq "OK") { return $dialog.FileName }
    return $null
}

function Ensure-BaseImage {
    if (Test-Path $ImagePath) {
        Write-AppLog "Base image already exists."
        return
    }

    $choice = [Windows.Forms.MessageBox]::Show(
        "Download the release image now? Choose No to select a local .vhdx or .qcow2.",
        "ez gentoo",
        "YesNoCancel",
        "Question"
    )

    if ($choice -eq "Cancel") { throw "Install cancelled." }

    if ($choice -eq "Yes") {
        Write-AppLog "Downloading $ImageUrl."
        Invoke-WebRequest -Uri $ImageUrl -OutFile $ImagePath
        return
    }

    $local = Select-LocalImage
    if (-not $local) { throw "No image selected." }

    if ($local -like "*.vhdx") {
        Write-AppLog "Copying VHDX image."
        Copy-Item -LiteralPath $local -Destination $ImagePath -Force
        return
    }

    if ($local -like "*.qcow2") {
        $qemu = Get-QemuImg
        Write-AppLog "Converting QCOW2 to VHDX with qemu-img."
        & $qemu convert -p -O vhdx $local $ImagePath
        if ($LASTEXITCODE -ne 0) { throw "qemu-img conversion failed." }
        return
    }

    throw "Unsupported image type: $local"
}

function Ensure-Vm {
    $vm = Get-VM -Name $VmName -ErrorAction SilentlyContinue
    if ($vm) {
        Write-AppLog "VM '$VmName' already exists."
        return $vm
    }

    Write-AppLog "Creating VM '$VmName'."
    $memoryBytes = [int64]$MemoryGB * 1GB
    $minMemoryBytes = [int64]2 * 1GB
    $vm = New-VM -Name $VmName -Generation 2 -MemoryStartupBytes $memoryBytes -VHDPath $ImagePath -Path $VmDir -SwitchName "Default Switch"
    Set-VMProcessor -VMName $VmName -Count $CpuCount
    Set-VMFirmware -VMName $VmName -EnableSecureBoot Off
    Set-VMMemory -VMName $VmName -DynamicMemoryEnabled $true -MinimumBytes $minMemoryBytes -StartupBytes $memoryBytes -MaximumBytes $memoryBytes
    return $vm
}

function Test-TcpPort([string]$Ip, [int]$Port, [int]$TimeoutMs = 900) {
    $client = New-Object Net.Sockets.TcpClient
    try {
        $async = $client.BeginConnect($Ip, $Port, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) {
            $client.Close()
            return $false
        }
        $client.EndConnect($async)
        return $true
    }
    catch { return $false }
    finally { $client.Close() }
}

function Get-CandidateIps {
    $ips = New-Object System.Collections.Generic.List[string]

    $adapter = Get-VMNetworkAdapter -VMName $VmName -ErrorAction SilentlyContinue
    if ($adapter) {
        if (-not $script:MacAddress) {
            $script:MacAddress = Convert-MacToDashed $adapter.MacAddress
        }
        foreach ($ip in @($adapter.IPAddresses)) {
            if ($ip -match '^\d+\.\d+\.\d+\.\d+$' -and -not $ips.Contains($ip)) {
                $ips.Add($ip)
            }
        }
    }

    if ($script:MacAddress) {
        $neighbors = Get-NetNeighbor -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object {
                $_.LinkLayerAddress -eq $script:MacAddress -and
                $_.State -notin @("Unreachable", "Incomplete")
            }

        foreach ($neighbor in $neighbors) {
            if ($neighbor.IPAddress -match '^\d+\.\d+\.\d+\.\d+$' -and -not $ips.Contains($neighbor.IPAddress)) {
                $ips.Add($neighbor.IPAddress)
            }
        }
    }

    return @($ips)
}

function Wait-ForVnc {
    $deadline = (Get-Date).AddSeconds(150)
    $seen = @{}

    while ((Get-Date) -lt $deadline) {
        $ips = @(Get-CandidateIps)
        foreach ($ip in $ips) {
            if (-not $seen.ContainsKey($ip)) {
                $seen[$ip] = $true
                Write-AppLog "Found candidate IP $ip."
            }

            if (Test-TcpPort -Ip $ip -Port $VncPort) {
                $script:CurrentIp = $ip
                return $ip
            }
        }

        Set-Status "Waiting for Gentoo networking and VNC..." 70
        Start-Sleep -Seconds 2
        [Windows.Forms.Application]::DoEvents()
    }

    throw "VNC did not answer within 150 seconds."
}

function Open-Viewer([string]$Ip) {
    if (-not (Test-Path $ViewerPath)) { throw "TigerVNC viewer not found." }
    Start-Process -FilePath $ViewerPath -ArgumentList @("-FullScreen", "$Ip`:$VncDisplay")
}

function Install-Start-Connect {
    if ($script:IsBusy) { return }
    Set-Busy $true
    try {
        Set-Status "Checking requirements..." 5
        Ensure-Tooling

        Set-Status "Preparing image..." 20
        Ensure-BaseImage

        Set-Status "Creating VM..." 40
        $vm = Ensure-Vm
        $adapter = Get-VMNetworkAdapter -VMName $VmName
        $script:MacAddress = Convert-MacToDashed $adapter.MacAddress
        Write-AppLog "Tracking VM MAC $script:MacAddress."

        if ($vm.State -ne "Running") {
            Set-Status "Starting VM..." 55
            Write-AppLog "Starting VM."
            Start-VM -Name $VmName
        }

        $ip = Wait-ForVnc
        Set-Status "Opening TigerVNC at $ip`:$VncDisplay" 95
        Write-AppLog "VNC ready at $ip`:$VncDisplay."
        Open-Viewer $ip
        Set-Status "Ready: $ip`:$VncDisplay" 100
    }
    catch {
        Set-Status "Error: $($_.Exception.Message)" 0
        Write-AppLog "ERROR: $($_.Exception.Message)"
        [Windows.Forms.MessageBox]::Show($_.Exception.Message, "ez gentoo", "OK", "Error") | Out-Null
    }
    finally {
        Set-Busy $false
    }
}

function Stop-EzGentoo {
    if ($script:IsBusy) { return }
    Set-Busy $true
    try {
        Write-AppLog "Turning off VM '$VmName'."
        Stop-VM -Name $VmName -TurnOff -Force
        $script:CurrentIp = $null
        Set-Status "VM stopped" 0
    }
    catch {
        Set-Status "Error: $($_.Exception.Message)" 0
        Write-AppLog "ERROR: $($_.Exception.Message)"
    }
    finally { Set-Busy $false }
}

$form = New-Object Windows.Forms.Form
$form.Text = "ez gentoo"
$form.StartPosition = "CenterScreen"
$form.Size = New-Object Drawing.Size(590, 430)
$form.MinimumSize = New-Object Drawing.Size(540, 370)
$form.Font = New-Object Drawing.Font("Segoe UI", 9)

$title = New-Object Windows.Forms.Label
$title.Text = "ez gentoo"
$title.Font = New-Object Drawing.Font("Segoe UI", 18, [Drawing.FontStyle]::Bold)
$title.AutoSize = $true
$title.Location = New-Object Drawing.Point(18, 14)
$form.Controls.Add($title)

$subtitle = New-Object Windows.Forms.Label
$subtitle.Text = "One-click Gentoo VM installer and launcher"
$subtitle.AutoSize = $true
$subtitle.Location = New-Object Drawing.Point(22, 52)
$form.Controls.Add($subtitle)

$script:StatusLabel = New-Object Windows.Forms.Label
$script:StatusLabel.Text = "Ready"
$script:StatusLabel.AutoSize = $false
$script:StatusLabel.Size = New-Object Drawing.Size(520, 24)
$script:StatusLabel.Location = New-Object Drawing.Point(22, 84)
$form.Controls.Add($script:StatusLabel)

$script:Progress = New-Object Windows.Forms.ProgressBar
$script:Progress.Location = New-Object Drawing.Point(24, 112)
$script:Progress.Size = New-Object Drawing.Size(520, 18)
$script:Progress.Minimum = 0
$script:Progress.Maximum = 100
$form.Controls.Add($script:Progress)

$script:InstallButton = New-Object Windows.Forms.Button
$script:InstallButton.Text = "Install / Start"
$script:InstallButton.Location = New-Object Drawing.Point(24, 148)
$script:InstallButton.Size = New-Object Drawing.Size(115, 34)
$form.Controls.Add($script:InstallButton)

$script:StartButton = New-Object Windows.Forms.Button
$script:StartButton.Text = "Start Only"
$script:StartButton.Location = New-Object Drawing.Point(150, 148)
$script:StartButton.Size = New-Object Drawing.Size(95, 34)
$form.Controls.Add($script:StartButton)

$script:ViewerButton = New-Object Windows.Forms.Button
$script:ViewerButton.Text = "Open Viewer"
$script:ViewerButton.Location = New-Object Drawing.Point(256, 148)
$script:ViewerButton.Size = New-Object Drawing.Size(105, 34)
$script:ViewerButton.Enabled = $false
$form.Controls.Add($script:ViewerButton)

$script:StopButton = New-Object Windows.Forms.Button
$script:StopButton.Text = "Stop VM"
$script:StopButton.Location = New-Object Drawing.Point(372, 148)
$script:StopButton.Size = New-Object Drawing.Size(84, 34)
$form.Controls.Add($script:StopButton)

$quitButton = New-Object Windows.Forms.Button
$quitButton.Text = "Quit"
$quitButton.Location = New-Object Drawing.Point(466, 148)
$quitButton.Size = New-Object Drawing.Size(76, 34)
$form.Controls.Add($quitButton)

$script:LogBox = New-Object Windows.Forms.TextBox
$script:LogBox.Location = New-Object Drawing.Point(24, 200)
$script:LogBox.Size = New-Object Drawing.Size(520, 150)
$script:LogBox.Multiline = $true
$script:LogBox.ReadOnly = $true
$script:LogBox.ScrollBars = "Vertical"
$script:LogBox.Anchor = "Top,Bottom,Left,Right"
$form.Controls.Add($script:LogBox)

$script:InstallButton.Add_Click({ Install-Start-Connect })
$script:StartButton.Add_Click({ Install-Start-Connect })
$script:ViewerButton.Add_Click({ if ($script:CurrentIp) { Open-Viewer $script:CurrentIp } })
$script:StopButton.Add_Click({ Stop-EzGentoo })
$quitButton.Add_Click({ $form.Close() })

[void]$form.ShowDialog()
