param(
    [string]$VmName = "EzGentoo",
    [string]$ImageUrl = "http://136.243.8.214:8088/ez-gentoo-base.vhdx",
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA "EzGentoo"),
    [int]$MemoryGB = 4,
    [int]$CpuCount = 4,
    [int]$DiskSizeGB = 40,
    [int]$VncDisplay = 1,
    [int]$VncPort = 5901,
    [switch]$AutoRun
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
        "-InstallDir", "`"$InstallDir`"",
        "-MemoryGB", "$MemoryGB",
        "-CpuCount", "$CpuCount",
        "-DiskSizeGB", "$DiskSizeGB",
        "-VncDisplay", "$VncDisplay",
        "-VncPort", "$VncPort",
        $(if ($AutoRun) { "-AutoRun" })
    )
    exit
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$script:VmName = $VmName
$script:ImageUrl = $ImageUrl
$script:InstallDir = $InstallDir
$script:MemoryGB = $MemoryGB
$script:CpuCount = $CpuCount
$script:DiskSizeGB = $DiskSizeGB
$script:VncDisplay = $VncDisplay
$script:VncPort = $VncPort
$script:AppDir = $InstallDir
$script:VmDir = Join-Path $script:AppDir "vm"
$script:ImagePath = Join-Path $script:AppDir "ez-gentoo-base.vhdx"
$script:LogPath = Join-Path $script:AppDir "ez-gentoo.log"
$ViewerPath = "C:\Program Files\TigerVNC\vncviewer.exe"
$MacAddress = $null
$CurrentIp = $null
$IsBusy = $false

function Set-AppPaths {
    $script:AppDir = $script:InstallDir
    $script:VmDir = Join-Path $script:AppDir "vm"
    $script:ImagePath = Join-Path $script:AppDir "ez-gentoo-base.vhdx"
    $script:LogPath = Join-Path $script:AppDir "ez-gentoo.log"
    New-Item -ItemType Directory -Force -Path $script:AppDir, $script:VmDir | Out-Null
}

Set-AppPaths

function Write-AppLog([string]$Message) {
    $line = "{0:HH:mm:ss}  {1}" -f (Get-Date), $Message
    try { Add-Content -Path $script:LogPath -Value $line -Encoding ASCII } catch { }
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
    if (Test-Path $script:ImagePath) {
        Write-AppLog "Base image already exists."
        Ensure-DiskSize
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
        Write-AppLog "Downloading $script:ImageUrl."
        Invoke-WebRequest -Uri $script:ImageUrl -OutFile $script:ImagePath
        Ensure-DiskSize
        return
    }

    $local = Select-LocalImage
    if (-not $local) { throw "No image selected." }

    if ($local -like "*.vhdx") {
        Write-AppLog "Copying VHDX image."
        Copy-Item -LiteralPath $local -Destination $script:ImagePath -Force
        Ensure-DiskSize
        return
    }

    if ($local -like "*.qcow2") {
        $qemu = Get-QemuImg
        Write-AppLog "Converting QCOW2 to VHDX with qemu-img."
        & $qemu convert -p -O vhdx $local $script:ImagePath
        if ($LASTEXITCODE -ne 0) { throw "qemu-img conversion failed." }
        Ensure-DiskSize
        return
    }

    throw "Unsupported image type: $local"
}

function Ensure-DiskSize {
    if (-not (Test-Path $script:ImagePath)) { return }
    if ($script:DiskSizeGB -le 0) { return }

    $targetBytes = [int64]$script:DiskSizeGB * 1GB
    $vhd = Get-VHD -Path $script:ImagePath -ErrorAction SilentlyContinue
    if ($vhd -and $vhd.Size -lt $targetBytes) {
        Write-AppLog "Resizing virtual disk to $script:DiskSizeGB GB."
        Resize-VHD -Path $script:ImagePath -SizeBytes $targetBytes
    }
}

function Ensure-Vm {
    $vm = Get-VM -Name $script:VmName -ErrorAction SilentlyContinue
    if ($vm) {
        Write-AppLog "VM '$script:VmName' already exists."
        return $vm
    }

    Write-AppLog "Creating VM '$script:VmName'."
    $memoryBytes = [int64]$script:MemoryGB * 1GB
    $minMemoryBytes = [int64]2 * 1GB
    $vm = New-VM -Name $script:VmName -Generation 2 -MemoryStartupBytes $memoryBytes -VHDPath $script:ImagePath -Path $script:VmDir -SwitchName "Default Switch"
    Set-VMProcessor -VMName $script:VmName -Count $script:CpuCount
    Set-VMFirmware -VMName $script:VmName -EnableSecureBoot Off
    Set-VMMemory -VMName $script:VmName -DynamicMemoryEnabled $true -MinimumBytes $minMemoryBytes -StartupBytes $memoryBytes -MaximumBytes $memoryBytes
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

    $adapter = Get-VMNetworkAdapter -VMName $script:VmName -ErrorAction SilentlyContinue
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

            if (Test-TcpPort -Ip $ip -Port $script:VncPort) {
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
    Start-Process -FilePath $ViewerPath -ArgumentList @("-FullScreen", "$Ip`:$script:VncDisplay")
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
        $adapter = Get-VMNetworkAdapter -VMName $script:VmName
        $script:MacAddress = Convert-MacToDashed $adapter.MacAddress
        Write-AppLog "Tracking VM MAC $script:MacAddress."

        if ($vm.State -ne "Running") {
            Set-Status "Starting VM..." 55
            Write-AppLog "Starting VM."
            Start-VM -Name $script:VmName
        }

        $ip = Wait-ForVnc
        Set-Status "Opening TigerVNC at $ip`:$script:VncDisplay" 95
        Write-AppLog "VNC ready at $ip`:$script:VncDisplay."
        Open-Viewer $ip
        Set-Status "Ready: $ip`:$script:VncDisplay" 100
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
        Write-AppLog "Turning off VM '$script:VmName'."
        Stop-VM -Name $script:VmName -TurnOff -Force
        $script:CurrentIp = $null
        Set-Status "VM stopped" 0
    }
    catch {
        Set-Status "Error: $($_.Exception.Message)" 0
        Write-AppLog "ERROR: $($_.Exception.Message)"
    }
    finally { Set-Busy $false }
}

function Apply-UiSettings {
    $script:VmName = $script:VmNameText.Text.Trim()
    $script:ImageUrl = $script:ImageUrlText.Text.Trim()
    $script:InstallDir = $script:InstallDirText.Text.Trim()
    $script:MemoryGB = [int]$script:MemoryInput.Value
    $script:CpuCount = [int]$script:CpuInput.Value
    $script:DiskSizeGB = [int]$script:DiskInput.Value

    if ([string]::IsNullOrWhiteSpace($script:VmName)) { throw "VM name is required." }
    if ([string]::IsNullOrWhiteSpace($script:InstallDir)) { throw "Install folder is required." }
    if ([string]::IsNullOrWhiteSpace($script:ImageUrl)) { throw "Image URL is required." }

    Set-AppPaths
}

$form = New-Object Windows.Forms.Form
$form.Text = "ez gentoo"
$form.StartPosition = "CenterScreen"
$form.Size = New-Object Drawing.Size(700, 610)
$form.MinimumSize = New-Object Drawing.Size(660, 560)
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

$vmNameLabel = New-Object Windows.Forms.Label
$vmNameLabel.Text = "VM name"
$vmNameLabel.Location = New-Object Drawing.Point(24, 148)
$vmNameLabel.Size = New-Object Drawing.Size(90, 22)
$form.Controls.Add($vmNameLabel)

$script:VmNameText = New-Object Windows.Forms.TextBox
$script:VmNameText.Text = $script:VmName
$script:VmNameText.Location = New-Object Drawing.Point(120, 145)
$script:VmNameText.Size = New-Object Drawing.Size(180, 24)
$form.Controls.Add($script:VmNameText)

$installLabel = New-Object Windows.Forms.Label
$installLabel.Text = "Install folder"
$installLabel.Location = New-Object Drawing.Point(24, 182)
$installLabel.Size = New-Object Drawing.Size(90, 22)
$form.Controls.Add($installLabel)

$script:InstallDirText = New-Object Windows.Forms.TextBox
$script:InstallDirText.Text = $script:InstallDir
$script:InstallDirText.Location = New-Object Drawing.Point(120, 179)
$script:InstallDirText.Size = New-Object Drawing.Size(438, 24)
$form.Controls.Add($script:InstallDirText)

$browseButton = New-Object Windows.Forms.Button
$browseButton.Text = "Browse"
$browseButton.Location = New-Object Drawing.Point(568, 178)
$browseButton.Size = New-Object Drawing.Size(82, 28)
$form.Controls.Add($browseButton)

$imageLabel = New-Object Windows.Forms.Label
$imageLabel.Text = "Image URL"
$imageLabel.Location = New-Object Drawing.Point(24, 216)
$imageLabel.Size = New-Object Drawing.Size(90, 22)
$form.Controls.Add($imageLabel)

$script:ImageUrlText = New-Object Windows.Forms.TextBox
$script:ImageUrlText.Text = $script:ImageUrl
$script:ImageUrlText.Location = New-Object Drawing.Point(120, 213)
$script:ImageUrlText.Size = New-Object Drawing.Size(530, 24)
$form.Controls.Add($script:ImageUrlText)

$ramLabel = New-Object Windows.Forms.Label
$ramLabel.Text = "RAM GB"
$ramLabel.Location = New-Object Drawing.Point(24, 250)
$ramLabel.Size = New-Object Drawing.Size(90, 22)
$form.Controls.Add($ramLabel)

$script:MemoryInput = New-Object Windows.Forms.NumericUpDown
$script:MemoryInput.Minimum = 2
$script:MemoryInput.Maximum = 64
$script:MemoryInput.Value = $script:MemoryGB
$script:MemoryInput.Location = New-Object Drawing.Point(120, 247)
$script:MemoryInput.Size = New-Object Drawing.Size(70, 24)
$form.Controls.Add($script:MemoryInput)

$cpuLabel = New-Object Windows.Forms.Label
$cpuLabel.Text = "CPUs"
$cpuLabel.Location = New-Object Drawing.Point(214, 250)
$cpuLabel.Size = New-Object Drawing.Size(45, 22)
$form.Controls.Add($cpuLabel)

$script:CpuInput = New-Object Windows.Forms.NumericUpDown
$script:CpuInput.Minimum = 1
$script:CpuInput.Maximum = 32
$script:CpuInput.Value = $script:CpuCount
$script:CpuInput.Location = New-Object Drawing.Point(264, 247)
$script:CpuInput.Size = New-Object Drawing.Size(70, 24)
$form.Controls.Add($script:CpuInput)

$diskLabel = New-Object Windows.Forms.Label
$diskLabel.Text = "Disk GB"
$diskLabel.Location = New-Object Drawing.Point(360, 250)
$diskLabel.Size = New-Object Drawing.Size(60, 22)
$form.Controls.Add($diskLabel)

$script:DiskInput = New-Object Windows.Forms.NumericUpDown
$script:DiskInput.Minimum = 20
$script:DiskInput.Maximum = 512
$script:DiskInput.Value = $script:DiskSizeGB
$script:DiskInput.Location = New-Object Drawing.Point(426, 247)
$script:DiskInput.Size = New-Object Drawing.Size(80, 24)
$form.Controls.Add($script:DiskInput)

$script:InstallButton = New-Object Windows.Forms.Button
$script:InstallButton.Text = "Install / Start"
$script:InstallButton.Location = New-Object Drawing.Point(24, 292)
$script:InstallButton.Size = New-Object Drawing.Size(115, 34)
$form.Controls.Add($script:InstallButton)

$script:StartButton = New-Object Windows.Forms.Button
$script:StartButton.Text = "Start Only"
$script:StartButton.Location = New-Object Drawing.Point(150, 292)
$script:StartButton.Size = New-Object Drawing.Size(95, 34)
$form.Controls.Add($script:StartButton)

$script:ViewerButton = New-Object Windows.Forms.Button
$script:ViewerButton.Text = "Open Viewer"
$script:ViewerButton.Location = New-Object Drawing.Point(256, 292)
$script:ViewerButton.Size = New-Object Drawing.Size(105, 34)
$script:ViewerButton.Enabled = $false
$form.Controls.Add($script:ViewerButton)

$script:StopButton = New-Object Windows.Forms.Button
$script:StopButton.Text = "Stop VM"
$script:StopButton.Location = New-Object Drawing.Point(372, 292)
$script:StopButton.Size = New-Object Drawing.Size(84, 34)
$form.Controls.Add($script:StopButton)

$quitButton = New-Object Windows.Forms.Button
$quitButton.Text = "Quit"
$quitButton.Location = New-Object Drawing.Point(466, 292)
$quitButton.Size = New-Object Drawing.Size(76, 34)
$form.Controls.Add($quitButton)

$script:LogBox = New-Object Windows.Forms.TextBox
$script:LogBox.Location = New-Object Drawing.Point(24, 346)
$script:LogBox.Size = New-Object Drawing.Size(626, 170)
$script:LogBox.Multiline = $true
$script:LogBox.ReadOnly = $true
$script:LogBox.ScrollBars = "Vertical"
$script:LogBox.Anchor = "Top,Bottom,Left,Right"
$form.Controls.Add($script:LogBox)

$browseButton.Add_Click({
    $dialog = New-Object Windows.Forms.FolderBrowserDialog
    $dialog.SelectedPath = $script:InstallDirText.Text
    if ($dialog.ShowDialog() -eq "OK") {
        $script:InstallDirText.Text = $dialog.SelectedPath
    }
})
$script:InstallButton.Add_Click({ Apply-UiSettings; Install-Start-Connect })
$script:StartButton.Add_Click({ Apply-UiSettings; Install-Start-Connect })
$script:ViewerButton.Add_Click({ if ($script:CurrentIp) { Open-Viewer $script:CurrentIp } })
$script:StopButton.Add_Click({ Stop-EzGentoo })
$quitButton.Add_Click({ $form.Close() })

if ($AutoRun) {
    $form.Add_Shown({ Apply-UiSettings; Install-Start-Connect })
}

[void]$form.ShowDialog()
