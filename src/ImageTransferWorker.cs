using System;
using System.Collections.Specialized;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Windows.Forms;

public sealed class ImageTransferWorker : IDisposable {
    readonly string adbPath, serial, logPath;
    readonly object processLock = new object();
    Process currentProcess;
    Thread workerThread;
    volatile bool cancelled;
    int busy;

    public ImageTransferWorker(string adbPath, string serial, string logPath) {
        this.adbPath = adbPath; this.serial = serial; this.logPath = logPath;
    }

    public bool IsBusy { get { return Volatile.Read(ref busy) != 0; } }

    public bool TryStart() {
        if (Interlocked.CompareExchange(ref busy, 1, 0) != 0) return false;
        cancelled = false;
        workerThread = new Thread(Transfer) { IsBackground = true, Name = "AndroidPrompt image transfer" };
        workerThread.SetApartmentState(ApartmentState.STA);
        workerThread.Start();
        return true;
    }

    void Transfer() {
        string temp = null, remote = null;
        bool success = false, pushed = false;
        try {
            string name = "AndroidPrompt-" + DateTime.Now.ToString("yyyyMMdd-HHmmss") + "-" + Guid.NewGuid().ToString("N") + ".png";
            temp = Path.Combine(Path.GetTempPath(), "android-prompt-" + Guid.NewGuid().ToString("N") + ".png");
            SaveClipboardPng(temp);
            ThrowIfCancelled();
            long length = new FileInfo(temp).Length;
            if (length < 1 || length > 20L * 1024 * 1024) throw new InvalidOperationException("PNG size is outside the 1..20971520 byte limit: " + length);
            string expectedHash = Sha256(temp);
            const string directory = "/sdcard/Pictures/AndroidPrompt";
            remote = directory + "/" + name;

            RequireSuccessChecked(RunAdb(new[]{"shell","mkdir","-p",directory}, 5000), "prepare destination");
            RequireSuccessChecked(RunAdb(new[]{"push",temp,remote}, 60000), "push image"); pushed = true;
            CommandResult remoteHash = RunAdb(new[]{"shell","sha256sum",remote}, 10000);
            RequireSuccessChecked(remoteHash, "verify image hash");
            if (!remoteHash.StdOut.StartsWith(expectedHash, StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException("Android SHA-256 does not match Windows PNG");
            RequireSuccessChecked(RunAdb(new[]{"shell","content","call","--uri","content://media","--method","scan_file","--arg",remote}, 15000), "index image");
            CommandResult query = RunAdb(new[]{"shell","content","query","--uri","content://media/external/images/media","--projection","_id:_display_name:relative_path:mime_type:_size","--where","\"_display_name='" + name + "'\""}, 15000);
            RequireSuccessChecked(query, "verify MediaStore");
            if (query.StdOut.IndexOf(name, StringComparison.Ordinal) < 0 || query.StdOut.IndexOf("relative_path=Pictures/AndroidPrompt/", StringComparison.Ordinal) < 0)
                throw new InvalidOperationException("MediaStore did not expose the transferred image in Pictures/AndroidPrompt");
            success = true;
            Log("PASS", "image-transfer saved name=" + name + " bytes=" + length + " sha256=" + expectedHash + " path=" + remote);
        } catch (OperationCanceledException) {
            Log("WARN", "image-transfer cancelled");
        } catch (Exception error) {
            Log("FAIL", "image-transfer failed error=" + Clean(error.Message));
        } finally {
            if (!success && pushed && remote != null && !cancelled) RunAdb(new[]{"shell","rm","-f",remote}, 5000);
            if (temp != null) try { File.Delete(temp); } catch {}
            Interlocked.Exchange(ref busy, 0);
        }
    }

    void SaveClipboardPng(string path) {
        Image image = null;
        try {
            if (Clipboard.ContainsImage()) image = Clipboard.GetImage();
            else if (Clipboard.ContainsFileDropList()) {
                StringCollection files = Clipboard.GetFileDropList();
                if (files.Count != 1 || !System.Text.RegularExpressions.Regex.IsMatch(Path.GetExtension(files[0]), "^\\.(png|jpe?g)$", System.Text.RegularExpressions.RegexOptions.IgnoreCase))
                    throw new InvalidOperationException("Windows clipboard must contain one PNG or JPEG image");
                using (Image source = Image.FromFile(files[0])) image = new Bitmap(source);
            } else throw new InvalidOperationException("Windows clipboard does not contain an image");
            if (image == null || image.Width < 1 || image.Height < 1) throw new InvalidOperationException("Windows clipboard image is empty");
            image.Save(path, ImageFormat.Png);
        } finally { if (image != null) image.Dispose(); }
    }

    CommandResult RunAdb(string[] commandArgs, int timeoutMs) {
        ThrowIfCancelled();
        string[] args = new string[commandArgs.Length + 2]; args[0] = "-s"; args[1] = serial; Array.Copy(commandArgs, 0, args, 2, commandArgs.Length);
        ProcessStartInfo psi = new ProcessStartInfo { FileName = adbPath, UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true, Arguments = JoinArguments(args) };
        Process process = new Process { StartInfo = psi }; Stopwatch timer = Stopwatch.StartNew();
        try {
            lock (processLock) currentProcess = process;
            if (!process.Start()) throw new InvalidOperationException("Could not start adb");
            var stdoutTask = process.StandardOutput.ReadToEndAsync(); var stderrTask = process.StandardError.ReadToEndAsync();
            bool exited = process.WaitForExit(timeoutMs);
            if (!exited) { try { process.Kill(); } catch {} process.WaitForExit(2000); }
            string stdout = stdoutTask.GetAwaiter().GetResult(), stderr = stderrTask.GetAwaiter().GetResult();
            timer.Stop();
            CommandResult result = new CommandResult { Command = Quote(adbPath) + " " + JoinArguments(args), ExitCode = exited ? process.ExitCode : -1, StdOut = stdout, StdErr = stderr, DurationMs = timer.ElapsedMilliseconds, TimedOut = !exited };
            bool ok = exited && result.ExitCode == 0;
            string loggedOut = ok ? Clip(Clean(stdout), 1200) : Clean(stdout), loggedErr = ok ? Clip(Clean(stderr), 1200) : Clean(stderr);
            Log(ok ? "INFO" : "FAIL", "image-transfer command=\"" + Clean(result.Command) + "\" exit=" + (exited ? result.ExitCode.ToString() : "TIMEOUT") + " durationMs=" + result.DurationMs + " stdout=\"" + loggedOut + "\" stderr=\"" + loggedErr + "\"");
            return result;
        } finally {
            lock (processLock) if (ReferenceEquals(currentProcess, process)) currentProcess = null;
            process.Dispose();
        }
    }

    void RequireSuccessChecked(CommandResult result, string operation) {
        ThrowIfCancelled();
        if (result.TimedOut) throw new TimeoutException(operation + " timed out after " + result.DurationMs + "ms");
        if (result.ExitCode != 0) throw new InvalidOperationException(operation + " failed; exit=" + result.ExitCode + " stdout=" + Clean(result.StdOut) + " stderr=" + Clean(result.StdErr));
    }
    void ThrowIfCancelled() { if (cancelled) throw new OperationCanceledException(); }
    static string Sha256(string path) { using (SHA256 hash = SHA256.Create()) using (FileStream file = File.OpenRead(path)) return BitConverter.ToString(hash.ComputeHash(file)).Replace("-", "").ToLowerInvariant(); }
    static string Clean(string value) { return (value ?? "").Replace("\r", " ").Replace("\n", " ").Replace("\"", "'").Trim(); }
    static string Clip(string value, int limit) { return value.Length <= limit ? value : value.Substring(0, limit) + "...[truncated]"; }
    static string JoinArguments(string[] args) { StringBuilder text = new StringBuilder(); foreach (string arg in args) { if (text.Length > 0) text.Append(' '); text.Append(Quote(arg)); } return text.ToString(); }
    static string Quote(string value) { if (value.Length > 0 && value.IndexOfAny(new[]{' ', '\t', '"'}) < 0) return value; return "\"" + value.Replace("\"", "\\\"") + "\""; }
    void Log(string level, string message) { try { File.AppendAllText(logPath, DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss.fff") + " [" + level + "] " + message + Environment.NewLine, Encoding.UTF8); } catch {} }

    public void Dispose() {
        cancelled = true;
        lock (processLock) if (currentProcess != null) try { currentProcess.Kill(); } catch {}
        Thread thread = workerThread; if (thread != null && thread.IsAlive) thread.Join(3000);
    }

    sealed class CommandResult { public string Command, StdOut, StdErr; public int ExitCode; public long DurationMs; public bool TimedOut; }
}
