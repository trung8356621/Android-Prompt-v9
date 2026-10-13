using System;
using System.Diagnostics;
using System.IO;
using System.Windows.Forms;

internal static class Program {
    [STAThread]
    private static void Main() {
        string root = AppDomain.CurrentDomain.BaseDirectory;
        string script = Path.Combine(root, "src", "Start-AndroidPrompt.ps1");
        string powershell = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "WindowsPowerShell", "v1.0", "powershell.exe");
        try {
            if (!File.Exists(script)) throw new FileNotFoundException("Missing application script.", script);
            if (!File.Exists(powershell)) throw new FileNotFoundException("Windows PowerShell 5.1 is unavailable.", powershell);
            var start = new ProcessStartInfo {
                FileName = powershell,
                Arguments = "-NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File " + Quote(script),
                WorkingDirectory = root,
                UseShellExecute = false,
                CreateNoWindow = true,
                WindowStyle = ProcessWindowStyle.Hidden
            };
            if (Process.Start(start) == null) throw new InvalidOperationException("Windows could not start AndroidPrompt.");
        } catch (Exception ex) {
            MessageBox.Show(ex.Message, "AndroidPrompt", MessageBoxButtons.OK, MessageBoxIcon.Error);
            Environment.ExitCode = 1;
        }
    }

    private static string Quote(string value) { return "\"" + value.Replace("\"", "\\\"") + "\""; }
}
