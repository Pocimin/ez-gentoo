using System.Diagnostics;
using System.Security.Principal;
using System.Text;
using System.Windows.Forms;

namespace EzGentoo;

internal static class Program
{
    [STAThread]
    private static int Main(string[] args)
    {
        ApplicationConfiguration.Initialize();

        try
        {
            var exeName = Path.GetFileNameWithoutExtension(Environment.ProcessPath ?? "EzGentooInstaller");
            var autoRun = exeName.Contains("Installer", StringComparison.OrdinalIgnoreCase);
            var scriptRelativePath = "ez-gentoo.ps1";
            var baseDir = AppContext.BaseDirectory;
            var scriptPath = Path.Combine(baseDir, scriptRelativePath);

            if (!File.Exists(scriptPath))
            {
                MessageBox.Show(
                    $"Missing script:\n\n{scriptPath}\n\nKeep the EXE beside the ez gentoo files.",
                    "ez gentoo",
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Error);
                return 1;
            }

            StartPowerShell(scriptPath, args, baseDir, autoRun);
            return 0;
        }
        catch (Exception ex)
        {
            MessageBox.Show(ex.Message, "ez gentoo", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
    }

    private static void StartPowerShell(string scriptPath, string[] args, string baseDir, bool autoRun)
    {
        var psArgs = new StringBuilder();
        psArgs.Append("-NoProfile -ExecutionPolicy Bypass -File ");
        psArgs.Append(Quote(scriptPath));

        if (autoRun)
        {
            psArgs.Append(" -AutoRun");
        }

        foreach (var arg in args)
        {
            psArgs.Append(' ');
            psArgs.Append(Quote(arg));
        }

        var info = new ProcessStartInfo
        {
            FileName = "powershell.exe",
            Arguments = psArgs.ToString(),
            UseShellExecute = true,
            WorkingDirectory = baseDir
        };

        // ponytail: the PowerShell scripts also self-elevate; this makes the EXE feel like a real installer.
        if (!IsAdministrator())
        {
            info.Verb = "runas";
        }

        Process.Start(info);
    }

    private static bool IsAdministrator()
    {
        using var identity = WindowsIdentity.GetCurrent();
        var principal = new WindowsPrincipal(identity);
        return principal.IsInRole(WindowsBuiltInRole.Administrator);
    }

    private static string Quote(string value)
    {
        return "\"" + value.Replace("\"", "\\\"") + "\"";
    }
}
