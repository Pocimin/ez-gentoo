param(
    [string]$VmName = "GentooReady",
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
        "-VncDisplay", "$VncDisplay",
        "-VncPort", "$VncPort"
    )
    exit
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$ViewerPath = "C:\Program Files\TigerVNC\vncviewer.exe"
$LogPath = Join-Path $env:TEMP "GentooLauncher.log"
$MacAddress = $null
$CurrentIp = $null
$IsBusy = $false

function Convert-MacToDashed([string]$Mac) {
    if ([string]::IsNullOrWhiteSpace($Mac)) { return $null }
    return (($Mac -replace '[^0-9A-Fa-f]', '').ToUpper() -replace '(.{2})(?!$)', '$1-')
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
    catch {
        return $false
    }
    finally {
        $client.Close()
    }
}

function Get-CandidateIps {
    $ips = New-Object System.Collections.Generic.List[string]

    try {
        $adapter = Get-VMNetworkAdapter -VMName $VmName
        if (-not $script:MacAddress) {
            $script:MacAddress = Convert-MacToDashed $adapter.MacAddress
        }

        foreach ($ip in @($adapter.IPAddresses)) {
            if ($ip -match '^\d+\.\d+\.\d+\.\d+$' -and -not $ips.Contains($ip)) {
                $ips.Add($ip)
            }
        }
    }
    catch { }

    if ($script:MacAddress) {
        try {
            $neighbors = Get-NetNeighbor -AddressFamily IPv4 |
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
        catch { }
    }

    return @($ips)
}

function Start-VncViewer([string]$Ip) {
    if (-not (Test-Path $ViewerPath)) {
        throw "TigerVNC viewer was not found at $ViewerPath"
    }

    $target = "$Ip`:$VncDisplay"
    Start-Process -FilePath $ViewerPath -ArgumentList @("-FullScreen", $target)
}

$form = New-Object Windows.Forms.Form
$form.Text = "Gentoo Launcher"
$form.StartPosition = "CenterScreen"
$form.Size = New-Object Drawing.Size(560, 410)
$form.MinimumSize = New-Object Drawing.Size(520, 360)
$form.Font = New-Object Drawing.Font("Segoe UI", 9)

$title = New-Object Windows.Forms.Label
$title.Text = "Gentoo VM Launcher"
$title.Font = New-Object Drawing.Font("Segoe UI", 15, [Drawing.FontStyle]::Bold)
$title.AutoSize = $true
$title.Location = New-Object Drawing.Point(18, 16)
$form.Controls.Add($title)

$status = New-Object Windows.Forms.Label
$status.Text = "Ready"
$status.AutoSize = $false
$status.Size = New-Object Drawing.Size(500, 24)
$status.Location = New-Object Drawing.Point(20, 54)
$form.Controls.Add($status)

$progress = New-Object Windows.Forms.ProgressBar
$progress.Location = New-Object Drawing.Point(22, 84)
$progress.Size = New-Object Drawing.Size(500, 18)
$progress.Style = "Continuous"
$progress.Minimum = 0
$progress.Maximum = 100
$form.Controls.Add($progress)

$connectButton = New-Object Windows.Forms.Button
$connectButton.Text = "Start and Connect"
$connectButton.Location = New-Object Drawing.Point(22, 118)
$connectButton.Size = New-Object Drawing.Size(135, 34)
$form.Controls.Add($connectButton)

$reconnectButton = New-Object Windows.Forms.Button
$reconnectButton.Text = "Open Viewer"
$reconnectButton.Location = New-Object Drawing.Point(168, 118)
$reconnectButton.Size = New-Object Drawing.Size(105, 34)
$reconnectButton.Enabled = $false
$form.Controls.Add($reconnectButton)

$stopButton = New-Object Windows.Forms.Button
$stopButton.Text = "Stop VM"
$stopButton.Location = New-Object Drawing.Point(284, 118)
$stopButton.Size = New-Object Drawing.Size(90, 34)
$form.Controls.Add($stopButton)

$quitButton = New-Object Windows.Forms.Button
$quitButton.Text = "Quit"
$quitButton.Location = New-Object Drawing.Point(384, 118)
$quitButton.Size = New-Object Drawing.Size(74, 34)
$form.Controls.Add($quitButton)

$log = New-Object Windows.Forms.TextBox
$log.Location = New-Object Drawing.Point(22, 170)
$log.Size = New-Object Drawing.Size(500, 170)
$log.Multiline = $true
$log.ReadOnly = $true
$log.ScrollBars = "Vertical"
$log.Anchor = "Top,Bottom,Left,Right"
$form.Controls.Add($log)

function Invoke-Ui([scriptblock]$Block) {
    if ($form.IsDisposed) { return }
    if ($form.InvokeRequired) {
        $form.BeginInvoke([Action]$Block) | Out-Null
    }
    else {
        & $Block
    }
}

function Write-LauncherLog([string]$Message) {
    $line = "{0:HH:mm:ss}  {1}" -f (Get-Date), $Message
    try { Add-Content -Path $LogPath -Value $line -Encoding ASCII } catch { }
    Invoke-Ui {
        $log.AppendText($line + [Environment]::NewLine)
    }
}

function Set-LauncherStatus([string]$Message, [int]$Percent = -1) {
    Invoke-Ui {
        $status.Text = $Message
        if ($Percent -ge 0) {
            $progress.Value = [Math]::Max(0, [Math]::Min(100, $Percent))
        }
    }
}

function Set-Busy([bool]$Busy) {
    $script:IsBusy = $Busy
    Invoke-Ui {
        $connectButton.Enabled = -not $Busy
        $stopButton.Enabled = -not $Busy
        $reconnectButton.Enabled = ((-not $Busy) -and $script:CurrentIp)
    }
}

function Begin-ConnectGentoo {
    if ($script:IsBusy) { return }
    Set-Busy $true
    try {
        Set-LauncherStatus "Checking Hyper-V..." 5
        Write-LauncherLog "Checking VM '$VmName'."

        $vm = Get-VM -Name $VmName
        if ($vm.State -ne "Running") {
            Write-LauncherLog "Starting VM."
            Start-VM -Name $VmName
        }
        else {
            Write-LauncherLog "VM is already running."
        }

        $adapter = Get-VMNetworkAdapter -VMName $VmName
        $script:MacAddress = Convert-MacToDashed $adapter.MacAddress
        Write-LauncherLog "Tracking VM MAC $script:MacAddress."

        $script:ConnectStartedAt = Get-Date
        $script:ConnectDeadline = (Get-Date).AddSeconds(120)
        $script:SeenIps = @{}
        Set-LauncherStatus "Waiting for Gentoo networking and VNC..." 10
        $pollTimer.Start()
    }
    catch {
        Set-LauncherStatus "Error: $($_.Exception.Message)" 0
        Write-LauncherLog "ERROR: $($_.Exception.Message)"
        [Windows.Forms.MessageBox]::Show($_.Exception.Message, "Gentoo Launcher", "OK", "Error") | Out-Null
    }
}

function Poll-Gentoo {
    $pollTimer.Stop()
    try {
        if ((Get-Date) -gt $script:ConnectDeadline) {
            throw "Gentoo started, but VNC did not answer within 120 seconds."
        }

        $elapsed = [int]((Get-Date) - $script:ConnectStartedAt).TotalSeconds
        $percent = 10 + [int]([Math]::Min(80, $elapsed * 0.7))
        Set-LauncherStatus "Waiting for Gentoo networking and VNC..." $percent

        $ips = @(Get-CandidateIps)
        if ($ips.Count -eq 0) {
            Write-LauncherLog "No VM IP visible yet."
        }

        foreach ($ip in $ips) {
            if (-not $script:SeenIps.ContainsKey($ip)) {
                $script:SeenIps[$ip] = $true
                Write-LauncherLog "Found candidate IP $ip."
            }

            if (Test-TcpPort -Ip $ip -Port $VncPort) {
                $script:CurrentIp = $ip
                Set-LauncherStatus "Connected target found: $ip`:$VncDisplay" 95
                Write-LauncherLog "VNC is ready at $ip`:$VncDisplay."
                Start-VncViewer $ip
                Set-LauncherStatus "Opened TigerVNC at $ip`:$VncDisplay" 100
                Set-Busy $false
                return
            }
        }

        $pollTimer.Start()
    }
    catch {
        Set-LauncherStatus "Error: $($_.Exception.Message)" 0
        Write-LauncherLog "ERROR: $($_.Exception.Message)"
        [Windows.Forms.MessageBox]::Show($_.Exception.Message, "Gentoo Launcher", "OK", "Error") | Out-Null
        Set-Busy $false
    }
}

function Stop-Gentoo {
    if ($script:IsBusy) { return }
    Set-Busy $true
    try {
        Set-LauncherStatus "Stopping VM..." 20
        Write-LauncherLog "Stopping VM '$VmName'."
        Stop-VM -Name $VmName -TurnOff -Force
        $script:CurrentIp = $null
        Set-LauncherStatus "VM stopped" 0
        Write-LauncherLog "VM stopped."
    }
    catch {
        Set-LauncherStatus "Error: $($_.Exception.Message)" 0
        Write-LauncherLog "ERROR: $($_.Exception.Message)"
        [Windows.Forms.MessageBox]::Show($_.Exception.Message, "Gentoo Launcher", "OK", "Error") | Out-Null
    }
    finally {
        Set-Busy $false
    }
}

$pollTimer = New-Object Windows.Forms.Timer
$pollTimer.Interval = 2000
$pollTimer.Add_Tick({ Poll-Gentoo })

$connectButton.Add_Click({ Begin-ConnectGentoo })
$stopButton.Add_Click({ Stop-Gentoo })
$reconnectButton.Add_Click({
    if ($script:CurrentIp) {
        try {
            Start-VncViewer $script:CurrentIp
            Write-LauncherLog "Opened viewer at $script:CurrentIp`:$VncDisplay."
        }
        catch {
            [Windows.Forms.MessageBox]::Show($_.Exception.Message, "Gentoo Launcher", "OK", "Error") | Out-Null
        }
    }
})
$quitButton.Add_Click({ $form.Close() })
$form.Add_FormClosing({ $pollTimer.Stop() })
$form.Add_Shown({ Begin-ConnectGentoo })

[void]$form.ShowDialog()
