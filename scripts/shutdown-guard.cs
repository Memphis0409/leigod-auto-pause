using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Threading;
using System.Windows.Forms;
using System.Diagnostics.Eventing.Reader;
using System.Xml.Linq;

internal sealed class ShutdownGuardWindow : NativeWindow, IDisposable
{
    private const int WmQueryEndSession = 0x0011;
    private volatile bool allowNextShutdown;
    private int handlingShutdown;

    public ShutdownGuardWindow()
    {
        CreateHandle(new CreateParams { Caption = "Leigod Auto Pause Shutdown Guard" });
    }

    protected override void WndProc(ref Message message)
    {
        if (message.Msg == WmQueryEndSession)
        {
            if (allowNextShutdown || Process.GetProcessesByName("leigod").Length == 0)
            {
                message.Result = new IntPtr(1);
                return;
            }

            if (Interlocked.CompareExchange(ref handlingShutdown, 1, 0) == 0)
            {
                long baselineLength = GetLogLength();
                ThreadPool.QueueUserWorkItem(_ => PauseThenResumeShutdown(baselineLength));
            }

            // Cancel the first request so Electron's suspended event loop can resume
            // and finish Leigod's asynchronous pause request.
            message.Result = IntPtr.Zero;
            return;
        }

        base.WndProc(ref message);
    }

    private void PauseThenResumeShutdown(long baselineLength)
    {
        try
        {
            string logPath = GetLogPath();
            string shutdownArgument = DetectShutdownArgument();
            AppendLog("shutdown-guard intercepted " + shutdownArgument);
            bool paused = WaitForPauseResult(logPath, baselineLength, TimeSpan.FromSeconds(15));

            if (!paused)
            {
                AppendLog("shutdown-guard pause-failed; shutdown remains cancelled");
                Interlocked.Exchange(ref handlingShutdown, 0);
                ShowFailureMessage();
                return;
            }

            WaitForLeigodExit(TimeSpan.FromSeconds(4));
            allowNextShutdown = true;
            ThreadPool.QueueUserWorkItem(_ =>
            {
                Thread.Sleep(TimeSpan.FromSeconds(30));
                allowNextShutdown = false;
                Interlocked.Exchange(ref handlingShutdown, 0);
            });

            AppendLog("shutdown-guard pause-confirmed; resuming " + shutdownArgument);
            Process.Start(new ProcessStartInfo
            {
                FileName = Path.Combine(Environment.SystemDirectory, "shutdown.exe"),
                Arguments = shutdownArgument + " /t 0",
                UseShellExecute = false,
                CreateNoWindow = true
            });
        }
        catch (Exception error)
        {
            Interlocked.Exchange(ref handlingShutdown, 0);
            AppendLog("shutdown-guard error " + error);
            ShowFailureMessage();
        }
    }

    private static string GetLogPath()
    {
        return Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "LeigodAutoPause",
            "auto-pause.log");
    }

    private static long GetLogLength()
    {
        try
        {
            string logPath = GetLogPath();
            return File.Exists(logPath) ? new FileInfo(logPath).Length : 0;
        }
        catch (IOException)
        {
            return 0;
        }
    }

    private static void AppendLog(string message)
    {
        try
        {
            string path = GetLogPath();
            Directory.CreateDirectory(Path.GetDirectoryName(path));
            File.AppendAllText(path, DateTime.UtcNow.ToString("o") + " " + message + Environment.NewLine);
        }
        catch { }
    }

    private static void ShowFailureMessage()
    {
        MessageBox.Show(
            "雷神时长未能自动暂停，Windows 关机已取消。请手动暂停时长后再关机。",
            "雷神自动暂停",
            MessageBoxButtons.OK,
            MessageBoxIcon.Warning,
            MessageBoxDefaultButton.Button1,
            MessageBoxOptions.ServiceNotification);
    }

    private static bool WaitForPauseResult(string logPath, long baselineLength, TimeSpan timeout)
    {
        DateTime deadline = DateTime.UtcNow.Add(timeout);
        while (DateTime.UtcNow < deadline)
        {
            try
            {
                if (File.Exists(logPath))
                {
                    using (FileStream stream = new FileStream(logPath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
                    {
                        if (stream.Length > baselineLength)
                        {
                            stream.Position = Math.Min(baselineLength, stream.Length);
                            using (StreamReader reader = new StreamReader(stream))
                            {
                                string appended = reader.ReadToEnd();
                                if (appended.Contains("auto-shutdown-native {\"status\":\"pause\"") ||
                                    appended.Contains("auto-shutdown-native {\"status\":\"pause-requested\"") ||
                                    appended.Contains("auto-shutdown-native {\"status\":\"already-paused\""))
                                {
                                    return true;
                                }
                                if (appended.Contains("auto-shutdown-native {\"status\":\"error\"") ||
                                    appended.Contains("auto-shutdown-native execute-error") ||
                                    appended.Contains("auto-shutdown-native {\"status\":\"timeout\"") ||
                                    appended.Contains("auto-shutdown-native no-window"))
                                {
                                    return false;
                                }
                            }
                        }
                    }
                }
            }
            catch (IOException) { }

            Thread.Sleep(250);
        }
        return false;
    }

    private static string DetectShutdownArgument()
    {
        try
        {
            string query = "*[System[(EventID=1074) and TimeCreated[timediff(@SystemTime) <= 15000]]]";
            EventLogQuery eventQuery = new EventLogQuery("System", PathType.LogName, query)
            {
                ReverseDirection = true
            };
            using (EventLogReader reader = new EventLogReader(eventQuery))
            using (EventRecord record = reader.ReadEvent())
            {
                if (record != null)
                {
                    XElement xml = XElement.Parse(record.ToXml());
                    XNamespace ns = xml.Name.Namespace;
                    string type = xml.Descendants(ns + "Data")
                        .Where(item => (string)item.Attribute("Name") == "param5")
                        .Select(item => item.Value)
                        .FirstOrDefault() ?? "";
                    string normalized = type.ToLowerInvariant();
                    if (normalized.Contains("restart") || normalized.Contains("重新启动") || normalized.Contains("重启"))
                    {
                        return "/r";
                    }
                }
            }
        }
        catch { }
        return "/s";
    }

    private static void WaitForLeigodExit(TimeSpan timeout)
    {
        DateTime deadline = DateTime.UtcNow.Add(timeout);
        while (DateTime.UtcNow < deadline && Process.GetProcessesByName("leigod").Length > 0)
        {
            Thread.Sleep(200);
        }
    }

    public void Dispose()
    {
        DestroyHandle();
    }
}

internal static class Program
{
    [STAThread]
    private static void Main()
    {
        bool created;
        using (Mutex mutex = new Mutex(true, "Local\\LeigodAutoPauseShutdownGuard", out created))
        {
            if (!created) return;
            Application.EnableVisualStyles();
            using (ShutdownGuardWindow window = new ShutdownGuardWindow())
            {
                Application.Run();
            }
        }
    }
}
