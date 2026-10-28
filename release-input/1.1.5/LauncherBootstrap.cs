using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Text;
using System.Windows.Forms;

internal static class LauncherBootstrap
{
    private const string BundleVersion = "1.1.5";
    private static readonly string[] Resources =
    {
        "ZedsDeadLauncher.ps1",
        "Apply-LauncherUpdate.ps1",
        "Launcher.xaml",
        "launcher.config.json",
        "zeds-dead-background.png",
        "zeds-dead-logo.png",
        "zeds-dead-logo.ico",
        "launcher-music.mp3"
    };

    [STAThread]
    private static void Main()
    {
        try
        {
            string root = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "ZedsDeadLauncher", "App");
            Directory.CreateDirectory(root);
            string logPath = Path.Combine(root, "launcher.log");
            File.AppendAllText(logPath, "[" + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + "] Démarrage de l’EXE.\r\n", new UTF8Encoding(false));
            string marker = Path.Combine(root, ".bundle-version");
            bool extract = !File.Exists(marker) || !string.Equals(File.ReadAllText(marker).Trim(), BundleVersion, StringComparison.OrdinalIgnoreCase);
            foreach (string resource in Resources)
            {
                if (!File.Exists(Path.Combine(root, resource))) { extract = true; break; }
            }
            if (extract)
            {
                Assembly assembly = Assembly.GetExecutingAssembly();
                foreach (string resource in Resources)
                {
                    using (Stream input = assembly.GetManifestResourceStream(resource))
                    {
                        if (input == null) { throw new InvalidOperationException("Ressource EXE absente : " + resource); }
                        using (FileStream output = File.Create(Path.Combine(root, resource))) { input.CopyTo(output); }
                    }
                }
                File.WriteAllText(marker, BundleVersion + Environment.NewLine, new UTF8Encoding(false));
            }
            string script = Path.Combine(root, "ZedsDeadLauncher.ps1");

            ProcessStartInfo startInfo = new ProcessStartInfo
            {
                FileName = "powershell.exe",
                Arguments = "-NoLogo -NoProfile -ExecutionPolicy Bypass -File \"" + script + "\"",
                WorkingDirectory = root,
                UseShellExecute = false,
                CreateNoWindow = true,
                WindowStyle = ProcessWindowStyle.Hidden,
                RedirectStandardOutput = true,
                RedirectStandardError = true
            };
            using (Process process = Process.Start(startInfo))
            {
                process.WaitForExit();
                string output = process.StandardOutput.ReadToEnd().Trim();
                string error = process.StandardError.ReadToEnd().Trim();
                string details = string.IsNullOrEmpty(error) ? output : error;
                File.AppendAllText(logPath, "[" + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + "] Fin du processus PowerShell (code " + process.ExitCode + ").\r\n" + details + "\r\n", new UTF8Encoding(false));
                if (process.ExitCode != 0 && !string.IsNullOrEmpty(details))
                {
                    throw new InvalidOperationException(details);
                }
            }
        }
        catch (Exception exception)
        {
            try
            {
                string root = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "ZedsDeadLauncher", "App");
                Directory.CreateDirectory(root);
                File.AppendAllText(Path.Combine(root, "launcher.log"), "[" + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + "] ERREUR EXE\r\n" + exception + "\r\n", new UTF8Encoding(false));
            }
            catch { }
            MessageBox.Show("Impossible de démarrer ZED'S DEAD Launcher.\n\n" + exception.Message,
                "ZED'S DEAD Launcher", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
    }
}

