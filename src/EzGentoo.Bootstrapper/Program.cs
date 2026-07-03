using System.Diagnostics;
using System.Net.Sockets;
using System.Security.Principal;
using System.Text;
using System.Windows.Forms;

namespace EzGentoo;

internal static class Program
{
    [STAThread]
    private static void Main()
    {
        ApplicationConfiguration.Initialize();

        if (!IsAdministrator())
        {
            Process.Start(new ProcessStartInfo
            {
                FileName = Environment.ProcessPath!,
                UseShellExecute = true,
                Verb = "runas"
            });
            return;
        }

        var exeName = Path.GetFileNameWithoutExtension(Environment.ProcessPath ?? "EzGentooLauncher");
        Application.Run(new MainForm(autoRun: exeName.Contains("Installer", StringComparison.OrdinalIgnoreCase)));
    }

    private static bool IsAdministrator()
    {
        using var identity = WindowsIdentity.GetCurrent();
        var principal = new WindowsPrincipal(identity);
        return principal.IsInRole(WindowsBuiltInRole.Administrator);
    }
}

internal sealed class MainForm : Form
{
    private readonly bool _autoRun;
    private readonly TextBox _vmName = new() { Text = "EzGentoo" };
    private readonly TextBox _installDir = new() { Text = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "EzGentoo") };
    private readonly TextBox _image = new() { Text = "https://github.com/Pocimin/ez-gentoo/releases/latest/download/ez-gentoo-base.vhdx" };
    private readonly NumericUpDown _ram = new() { Minimum = 2, Maximum = 64, Value = 4 };
    private readonly NumericUpDown _cpu = new() { Minimum = 1, Maximum = 32, Value = 4 };
    private readonly NumericUpDown _disk = new() { Minimum = 20, Maximum = 512, Value = 40 };
    private readonly ProgressBar _progress = new() { Minimum = 0, Maximum = 100 };
    private readonly Label _status = new() { Text = "Ready" };
    private readonly TextBox _log = new() { Multiline = true, ReadOnly = true, ScrollBars = ScrollBars.Vertical };
    private readonly Button _install = new() { Text = "Install / Start" };
    private readonly Button _connect = new() { Text = "Connect" };
    private readonly Button _stop = new() { Text = "Stop VM" };
    private readonly Button _chooseImage = new() { Text = "Image..." };
    private readonly Button _browse = new() { Text = "Browse" };

    private string? _currentIp;
    private bool _busy;

    public MainForm(bool autoRun)
    {
        _autoRun = autoRun;
        Text = "ez gentoo";
        StartPosition = FormStartPosition.CenterScreen;
        MinimumSize = new Size(780, 620);
        Size = new Size(820, 660);
        Font = new Font("Segoe UI", 9F);
        BackColor = Color.FromArgb(246, 245, 241);

        BuildUi();

        _install.Click += async (_, _) => await GuardedRunAsync(InstallStartConnectAsync);
        _connect.Click += async (_, _) => await GuardedRunAsync(ConnectOnlyAsync);
        _stop.Click += async (_, _) => await GuardedRunAsync(StopVmAsync);
        _browse.Click += (_, _) => BrowseInstallFolder();
        _chooseImage.Click += (_, _) => ChooseLocalImage();

        if (_autoRun)
        {
            Shown += async (_, _) => await GuardedRunAsync(InstallStartConnectAsync);
        }
    }

    private void BuildUi()
    {
        var title = new Label
        {
            Text = "ez gentoo",
            Font = new Font("Segoe UI", 24F, FontStyle.Bold),
            AutoSize = true,
            Location = new Point(24, 18)
        };

        var subtitle = new Label
        {
            Text = "Gentoo for people who want the desktop first and the pain later.",
            AutoSize = true,
            Location = new Point(29, 66)
        };

        Controls.Add(title);
        Controls.Add(subtitle);

        AddLabel("VM name", 30, 110);
        Place(_vmName, 140, 106, 220);

        AddLabel("Install folder", 30, 148);
        Place(_installDir, 140, 144, 510);
        Place(_browse, 660, 143, 90, 28);

        AddLabel("Image URL/file", 30, 186);
        Place(_image, 140, 182, 510);
        Place(_chooseImage, 660, 181, 90, 28);

        AddLabel("RAM", 30, 224);
        Place(_ram, 140, 220, 70);
        AddLabel("GB", 216, 224);

        AddLabel("CPU", 270, 224);
        Place(_cpu, 320, 220, 70);

        AddLabel("Disk", 440, 224);
        Place(_disk, 492, 220, 80);
        AddLabel("GB", 578, 224);

        Place(_install, 30, 274, 130, 36);
        Place(_connect, 170, 274, 100, 36);
        Place(_stop, 280, 274, 100, 36);

        _status.Location = new Point(30, 332);
        _status.Size = new Size(720, 22);
        Controls.Add(_status);

        _progress.Location = new Point(30, 360);
        _progress.Size = new Size(720, 18);
        Controls.Add(_progress);

        _log.Location = new Point(30, 400);
        _log.Size = new Size(720, 180);
        _log.Anchor = AnchorStyles.Top | AnchorStyles.Bottom | AnchorStyles.Left | AnchorStyles.Right;
        _log.BackColor = Color.FromArgb(31, 33, 36);
        _log.ForeColor = Color.FromArgb(232, 232, 225);
        _log.BorderStyle = BorderStyle.FixedSingle;
        Controls.Add(_log);
    }

    private void AddLabel(string text, int x, int y)
    {
        Controls.Add(new Label
        {
            Text = text,
            Location = new Point(x, y),
            Size = new Size(100, 22)
        });
    }

    private static void Place(Control control, int x, int y, int w, int h = 24)
    {
        control.Location = new Point(x, y);
        control.Size = new Size(w, h);
    }

    private async Task GuardedRunAsync(Func<Task> action)
    {
        if (_busy) return;

        SetBusy(true);
        try
        {
            await action();
        }
        catch (Exception ex)
        {
            SetStatus("Something snapped. Read the log.", 0);
            Log("ERROR: " + ex.Message);
            MessageBox.Show(ex.Message, "ez gentoo", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
        finally
        {
            SetBusy(false);
        }
    }

    private async Task InstallStartConnectAsync()
    {
        var settings = ReadSettings();

        SetStatus("Checking Windows bits...", 5);
        await EnsureToolingAsync();

        SetStatus("Preparing image...", 15);
        var imagePath = await EnsureImageAsync(settings);

        SetStatus("Creating VM...", 45);
        await EnsureVmAsync(settings, imagePath);

        SetStatus("Starting VM...", 60);
        await StartVmAsync(settings.VmName);

        await ConnectOnlyAsync();
    }

    private async Task ConnectOnlyAsync()
    {
        var settings = ReadSettings();
        SetStatus("Finding the VM on Hyper-V's weird little network...", 70);
        var ip = await WaitForVncAsync(settings.VmName, settings.VncPort);
        _currentIp = ip;
        SetStatus($"Opening desktop at {ip}:{settings.VncDisplay}", 95);
        OpenViewer(ip, settings.VncDisplay);
        SetStatus($"Ready. Gentoo is at {ip}:{settings.VncDisplay}", 100);
    }

    private async Task StopVmAsync()
    {
        var settings = ReadSettings();
        SetStatus("Stopping VM...", 20);
        await PowerShellAsync($"Stop-VM -Name {Ps(settings.VmName)} -TurnOff -Force");
        _currentIp = null;
        SetStatus("VM stopped.", 0);
        Log("VM stopped.");
    }

    private Settings ReadSettings()
    {
        var settings = new Settings(
            VmName: _vmName.Text.Trim(),
            InstallDir: _installDir.Text.Trim(),
            ImageSource: _image.Text.Trim(),
            MemoryGb: (int)_ram.Value,
            CpuCount: (int)_cpu.Value,
            DiskGb: (int)_disk.Value,
            VncDisplay: 1,
            VncPort: 5901);

        if (settings.VmName.Length == 0) throw new InvalidOperationException("VM name is required.");
        if (settings.InstallDir.Length == 0) throw new InvalidOperationException("Install folder is required.");
        if (settings.ImageSource.Length == 0) throw new InvalidOperationException("Image URL or local image path is required.");

        return settings;
    }

    private async Task EnsureToolingAsync()
    {
        await PowerShellAsync("if (-not (Get-Command Get-VM -ErrorAction SilentlyContinue)) { throw 'Hyper-V PowerShell tools are missing. Enable Hyper-V first.' }");

        if (!File.Exists(TigerVncPath))
        {
            Log("TigerVNC not found. Trying winget install.");
            await PowerShellAsync("winget install --id TigerVNC.TigerVNC --exact --accept-source-agreements --accept-package-agreements");
        }
    }

    private async Task<string> EnsureImageAsync(Settings settings)
    {
        var imagePath = Path.Combine(settings.InstallDir, "ez-gentoo-base.vhdx");
        Directory.CreateDirectory(settings.InstallDir);

        if (File.Exists(imagePath))
        {
            Log("Base image already exists.");
            await ResizeImageAsync(imagePath, settings.DiskGb);
            return imagePath;
        }

        if (File.Exists(settings.ImageSource))
        {
            if (settings.ImageSource.EndsWith(".vhdx", StringComparison.OrdinalIgnoreCase))
            {
                Log("Copying local VHDX.");
                File.Copy(settings.ImageSource, imagePath, overwrite: true);
            }
            else if (settings.ImageSource.EndsWith(".qcow2", StringComparison.OrdinalIgnoreCase))
            {
                Log("Converting local QCOW2 to VHDX.");
                var qemu = await GetQemuImgAsync();
                await RunProcessAsync(qemu, $"convert -p -O vhdx {Quote(settings.ImageSource)} {Quote(imagePath)}");
            }
            else
            {
                throw new InvalidOperationException("Use a .vhdx or .qcow2 image.");
            }

            await ResizeImageAsync(imagePath, settings.DiskGb);
            return imagePath;
        }

        Log("Downloading base image.");
        using var http = new HttpClient();
        using var response = await http.GetAsync(settings.ImageSource, HttpCompletionOption.ResponseHeadersRead);
        response.EnsureSuccessStatusCode();
        await using (var input = await response.Content.ReadAsStreamAsync())
        await using (var output = File.Create(imagePath))
        {
            await input.CopyToAsync(output);
        }

        await ResizeImageAsync(imagePath, settings.DiskGb);
        return imagePath;
    }

    private async Task<string> GetQemuImgAsync()
    {
        var found = await PowerShellAsync("(Get-Command qemu-img -ErrorAction SilentlyContinue).Source", allowFailure: true);
        if (File.Exists(found.Trim())) return found.Trim();

        Log("qemu-img not found. Trying winget install.");
        await PowerShellAsync("winget install --id cloudbase.qemu-img --exact --accept-source-agreements --accept-package-agreements");
        found = await PowerShellAsync("(Get-Command qemu-img -ErrorAction SilentlyContinue).Source", allowFailure: true);
        if (File.Exists(found.Trim())) return found.Trim();

        var wingetDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Microsoft", "WinGet", "Packages");
        var qemu = Directory.Exists(wingetDir)
            ? Directory.EnumerateFiles(wingetDir, "qemu-img.exe", SearchOption.AllDirectories).FirstOrDefault()
            : null;

        return qemu ?? throw new InvalidOperationException("qemu-img was not found.");
    }

    private async Task ResizeImageAsync(string imagePath, int diskGb)
    {
        var targetBytes = (long)diskGb * 1024 * 1024 * 1024;
        await PowerShellAsync(string.Join(Environment.NewLine,
            $"$vhd = Get-VHD -Path {Ps(imagePath)}",
            $"if ($vhd.Size -lt {targetBytes}) {{",
            $"    Resize-VHD -Path {Ps(imagePath)} -SizeBytes {targetBytes}",
            "}"));
    }

    private async Task EnsureVmAsync(Settings settings, string imagePath)
    {
        var vmDir = Path.Combine(settings.InstallDir, "vm");
        Directory.CreateDirectory(vmDir);
        var memoryBytes = (long)settings.MemoryGb * 1024 * 1024 * 1024;
        var minMemoryBytes = 2L * 1024 * 1024 * 1024;

        await PowerShellAsync(string.Join(Environment.NewLine,
            $"$vm = Get-VM -Name {Ps(settings.VmName)} -ErrorAction SilentlyContinue",
            "if (-not $vm) {",
            $"    New-VM -Name {Ps(settings.VmName)} -Generation 2 -MemoryStartupBytes {memoryBytes} -VHDPath {Ps(imagePath)} -Path {Ps(vmDir)} -SwitchName 'Default Switch' | Out-Null",
            $"    Set-VMFirmware -VMName {Ps(settings.VmName)} -EnableSecureBoot Off",
            "}",
            $"Set-VMProcessor -VMName {Ps(settings.VmName)} -Count {settings.CpuCount}",
            $"Set-VMMemory -VMName {Ps(settings.VmName)} -DynamicMemoryEnabled $true -MinimumBytes {minMemoryBytes} -StartupBytes {memoryBytes} -MaximumBytes {memoryBytes}"));

        Log($"VM ready: {settings.VmName}");
    }

    private async Task StartVmAsync(string vmName)
    {
        await PowerShellAsync(string.Join(Environment.NewLine,
            $"$vm = Get-VM -Name {Ps(vmName)}",
            "if ($vm.State -ne 'Running') {",
            $"    Start-VM -Name {Ps(vmName)}",
            "}"));
    }

    private async Task<string> WaitForVncAsync(string vmName, int port)
    {
        var deadline = DateTime.UtcNow.AddSeconds(150);
        var seen = new HashSet<string>();

        while (DateTime.UtcNow < deadline)
        {
            var ips = await GetCandidateIpsAsync(vmName);
            foreach (var ip in ips)
            {
                if (seen.Add(ip)) Log($"Found candidate IP {ip}.");
                if (await TestTcpAsync(ip, port))
                {
                    Log($"VNC answered at {ip}:{port}.");
                    return ip;
                }
            }

            await Task.Delay(2000);
        }

        throw new TimeoutException("Gentoo started, but VNC never answered.");
    }

    private async Task<List<string>> GetCandidateIpsAsync(string vmName)
    {
        var output = await PowerShellAsync(string.Join(Environment.NewLine,
            $"$adapter = Get-VMNetworkAdapter -VMName {Ps(vmName)}",
            "$mac = (($adapter.MacAddress -replace '[^0-9A-Fa-f]', '').ToUpper() -replace '(.{2})(?!$)', '$1-')",
            "$ips = @()",
            "$ips += @($adapter.IPAddresses | Where-Object { $_ -match '^\\d+\\.\\d+\\.\\d+\\.\\d+$' })",
            "$ips += @(Get-NetNeighbor -AddressFamily IPv4 -ErrorAction SilentlyContinue |",
            "    Where-Object { $_.LinkLayerAddress -eq $mac -and $_.State -notin @('Unreachable','Incomplete') } |",
            "    Select-Object -ExpandProperty IPAddress)",
            "$ips | Select-Object -Unique"), allowFailure: true);

        return output.Split(new[] { '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries)
            .Select(x => x.Trim())
            .Where(x => x.Count(c => c == '.') == 3)
            .Distinct()
            .ToList();
    }

    private static async Task<bool> TestTcpAsync(string ip, int port)
    {
        using var client = new TcpClient();
        var connect = client.ConnectAsync(ip, port);
        var done = await Task.WhenAny(connect, Task.Delay(900));
        return done == connect && client.Connected;
    }

    private void OpenViewer(string ip, int display)
    {
        if (!File.Exists(TigerVncPath))
        {
            throw new FileNotFoundException("TigerVNC viewer was not found.", TigerVncPath);
        }

        Process.Start(new ProcessStartInfo
        {
            FileName = TigerVncPath,
            ArgumentList = { "-FullScreen", $"{ip}:{display}" },
            UseShellExecute = true
        });
    }

    private async Task<string> PowerShellAsync(string script, bool allowFailure = false)
    {
        var encoded = Convert.ToBase64String(Encoding.Unicode.GetBytes("$ErrorActionPreference='Stop'; " + script));
        return await RunProcessAsync("powershell.exe", "-NoProfile -ExecutionPolicy Bypass -EncodedCommand " + encoded, allowFailure);
    }

    private async Task<string> RunProcessAsync(string fileName, string arguments, bool allowFailure = false)
    {
        var psi = new ProcessStartInfo
        {
            FileName = fileName,
            Arguments = arguments,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true
        };

        using var process = Process.Start(psi) ?? throw new InvalidOperationException($"Could not start {fileName}.");
        var stdout = await process.StandardOutput.ReadToEndAsync();
        var stderr = await process.StandardError.ReadToEndAsync();
        await process.WaitForExitAsync();

        if (process.ExitCode != 0 && !allowFailure)
        {
            throw new InvalidOperationException(stderr.Trim().Length > 0 ? stderr.Trim() : $"{fileName} exited with {process.ExitCode}.");
        }

        return stdout.Trim();
    }

    private void BrowseInstallFolder()
    {
        using var dialog = new FolderBrowserDialog { SelectedPath = _installDir.Text };
        if (dialog.ShowDialog(this) == DialogResult.OK) _installDir.Text = dialog.SelectedPath;
    }

    private void ChooseLocalImage()
    {
        using var dialog = new OpenFileDialog
        {
            Title = "Choose a Gentoo VM image",
            Filter = "VM images (*.vhdx;*.qcow2)|*.vhdx;*.qcow2|All files (*.*)|*.*"
        };

        if (dialog.ShowDialog(this) == DialogResult.OK) _image.Text = dialog.FileName;
    }

    private void SetBusy(bool busy)
    {
        _busy = busy;
        _install.Enabled = !busy;
        _connect.Enabled = !busy;
        _stop.Enabled = !busy;
        _browse.Enabled = !busy;
        _chooseImage.Enabled = !busy;
    }

    private void SetStatus(string text, int percent)
    {
        _status.Text = text;
        _progress.Value = Math.Max(0, Math.Min(100, percent));
        Log(text);
    }

    private void Log(string message)
    {
        _log.AppendText($"{DateTime.Now:HH:mm:ss}  {message}{Environment.NewLine}");
    }

    private static string Ps(string value) => "'" + value.Replace("'", "''") + "'";

    private static string Quote(string value) => "\"" + value.Replace("\"", "\\\"") + "\"";

    private const string TigerVncPath = @"C:\Program Files\TigerVNC\vncviewer.exe";
}

internal sealed record Settings(
    string VmName,
    string InstallDir,
    string ImageSource,
    int MemoryGb,
    int CpuCount,
    int DiskGb,
    int VncDisplay,
    int VncPort);
