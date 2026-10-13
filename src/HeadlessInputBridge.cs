using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Threading;

public enum RoutingState { Windows, EnteringAndroid, Android, ReturningWindows, Disconnected }

public sealed class HeadlessInputBridge : IDisposable {
    const int WH_KEYBOARD_LL = 13, WH_MOUSE_LL = 14;
    const int WM_KEYDOWN = 0x100, WM_KEYUP = 0x101, WM_SYSKEYDOWN = 0x104, WM_SYSKEYUP = 0x105;
    const int WM_MOUSEMOVE = 0x200, WM_LBUTTONDOWN = 0x201, WM_LBUTTONUP = 0x202,
        WM_RBUTTONDOWN = 0x204, WM_RBUTTONUP = 0x205, WM_MBUTTONDOWN = 0x207,
        WM_MBUTTONUP = 0x208, WM_MOUSEWHEEL = 0x20A, WM_XBUTTONDOWN = 0x20B,
        WM_XBUTTONUP = 0x20C, WM_MOUSEHWHEEL = 0x20E;
    const int VK_RMENU = 0xA5, VK_SNAPSHOT = 0x2C;
    const byte UHID_CREATE = 12, UHID_INPUT = 13, UHID_DESTROY = 14;
    const ushort KEYBOARD_ID = 1, MOUSE_ID = 2;
    const uint LLMHF_INJECTED = 1;

    delegate IntPtr HookProc(int code, IntPtr wParam, IntPtr lParam);
    readonly HookProc keyboardProc, mouseProc;
    readonly object sendLock = new object();
    readonly HashSet<byte> keys = new HashSet<byte>();
    IntPtr keyboardHook, mouseHook;
    TcpClient client;
    NetworkStream stream;
    Process serverProcess;
    string adbPath, serial;
    int localPort;
    byte modifiers, mouseButtons;
    int lastX, lastY;
    bool haveMousePosition, disposed;
    volatile RoutingState state = RoutingState.Disconnected;

    public event Action EmergencyReturn;
    public event Action CaptureAndroid;
    public event Action Disconnected;
    public RoutingState State { get { return state; } }
    public bool IsConnected { get { return client != null && client.Connected && state != RoutingState.Disconnected; } }

    public HeadlessInputBridge(string adb, string deviceSerial, string serverJar) {
        adbPath = adb; serial = deviceSerial;
        keyboardProc = KeyboardCallback; mouseProc = MouseCallback;
        try {
            StartServer(serverJar);
            keyboardHook = SetWindowsHookEx(WH_KEYBOARD_LL, keyboardProc, IntPtr.Zero, 0);
            mouseHook = SetWindowsHookEx(WH_MOUSE_LL, mouseProc, IntPtr.Zero, 0);
            if (keyboardHook == IntPtr.Zero || mouseHook == IntPtr.Zero) throw new InvalidOperationException("Cannot install headless input hooks.");
            state = RoutingState.Windows;
        } catch { Dispose(); throw; }
    }

    public bool EnterAndroid() {
        if (!IsConnected || state != RoutingState.Windows) return state == RoutingState.Android;
        state = RoutingState.EnteringAndroid;
        ReleaseAll();
        haveMousePosition = false;
        state = RoutingState.Android;
        return true;
    }

    public void ReturnWindows() {
        if (state == RoutingState.Windows) return;
        state = RoutingState.ReturningWindows;
        try { ReleaseAll(); } catch { }
        haveMousePosition = false;
        state = IsSocketAlive() ? RoutingState.Windows : RoutingState.Disconnected;
    }

    void StartServer(string serverJar) {
        RunAdb(15000, "push", serverJar, "/data/local/tmp/scrcpy-server");
        localPort = GetFreePort();
        string scid = new Random().Next(0x1000000, 0x7fffffff).ToString("x8");
        RunAdb(5000, "forward", "tcp:" + localPort, "localabstract:scrcpy_" + scid);
        var psi = AdbStartInfo("shell", "CLASSPATH=/data/local/tmp/scrcpy-server", "app_process", "/",
            "com.genymobile.scrcpy.Server", "4.1", "scid=" + scid, "log_level=warn", "video=false", "audio=false",
            "control=true", "tunnel_forward=true", "cleanup=false", "send_dummy_byte=true", "stay_awake=true");
        serverProcess = Process.Start(psi);
        Exception last = null; int dummy = -1;
        for (int i = 0; i < 50; i++) {
            try {
                client = new TcpClient(); client.Connect("127.0.0.1", localPort); stream = client.GetStream();
                dummy = stream.ReadByte();
                if (dummy == 0) { last = null; break; }
                throw new IOException("scrcpy socket was not ready.");
            }
            catch (Exception ex) { last = ex; if (client != null) client.Dispose(); client = null; Thread.Sleep(100); }
        }
        if (last != null || client == null) throw new InvalidOperationException("Cannot connect to scrcpy control socket.", last);
        if (dummy != 0) {
            string detail = "";
            try { if (serverProcess.WaitForExit(1000)) detail = serverProcess.StandardError.ReadToEnd(); } catch { }
            throw new InvalidDataException("Invalid scrcpy control handshake byte: " + dummy + ". " + detail);
        }
        SendCreate(KEYBOARD_ID, KeyboardDescriptor);
        SendCreate(MOUSE_ID, MouseDescriptor);
        var reader = new Thread(ReadDeviceMessages) { IsBackground = true, Name = "AndroidPrompt-scrcpy-reader" };
        reader.Start();
    }

    void ReadDeviceMessages() {
        try {
            byte[] buffer = new byte[4096];
            while (!disposed && stream.Read(buffer, 0, buffer.Length) > 0) { }
        } catch { }
        if (!disposed) {
            state = RoutingState.Disconnected;
            var callback = Disconnected; if (callback != null) callback();
        }
    }

    IntPtr KeyboardCallback(int code, IntPtr wParam, IntPtr lParam) {
        if (code < 0 || state != RoutingState.Android) return CallNextHookEx(keyboardHook, code, wParam, lParam);
        int message = wParam.ToInt32();
        bool down = message == WM_KEYDOWN || message == WM_SYSKEYDOWN;
        bool up = message == WM_KEYUP || message == WM_SYSKEYUP;
        if (!down && !up) return CallNextHookEx(keyboardHook, code, wParam, lParam);
        KbdData data = (KbdData)Marshal.PtrToStructure(lParam, typeof(KbdData));
        if (data.vkCode == VK_RMENU || (data.vkCode == 0x32 && down && (modifiers & 4) != 0)) {
            if (down) { var callback = EmergencyReturn; if (callback != null) callback(); }
            return new IntPtr(1);
        }
        if (data.vkCode == VK_SNAPSHOT && down) {
            var capture = CaptureAndroid; if (capture != null) capture();
            return new IntPtr(1);
        }
        byte modifier = ModifierFor(data.vkCode);
        if (modifier != 0) {
            if (down) modifiers |= modifier; else modifiers = (byte)(modifiers & ~modifier);
        } else {
            byte hid = HidFor(data.vkCode);
            if (hid != 0) { if (down) keys.Add(hid); else keys.Remove(hid); }
        }
        try { SendKeyboard(); } catch { MarkDisconnected(); }
        return new IntPtr(1);
    }

    IntPtr MouseCallback(int code, IntPtr wParam, IntPtr lParam) {
        if (code < 0 || state != RoutingState.Android) return CallNextHookEx(mouseHook, code, wParam, lParam);
        MouseData data = (MouseData)Marshal.PtrToStructure(lParam, typeof(MouseData));
        if ((data.flags & LLMHF_INJECTED) != 0) return new IntPtr(1);
        int msg = wParam.ToInt32(), dx = 0, dy = 0, wheel = 0, hWheel = 0;
        if (msg == WM_MOUSEMOVE) {
            if (haveMousePosition) { dx = data.pt.x - lastX; dy = data.pt.y - lastY; }
            lastX = data.pt.x; lastY = data.pt.y; haveMousePosition = true;
            int width = GetSystemMetrics(0), height = GetSystemMetrics(1);
            if (data.pt.x < 100 || data.pt.y < 100 || data.pt.x > width - 100 || data.pt.y > height - 100) {
                lastX = width / 2; lastY = height / 2; SetCursorPos(lastX, lastY);
            }
        } else if (msg == WM_LBUTTONDOWN) mouseButtons |= 1;
        else if (msg == WM_LBUTTONUP) mouseButtons = (byte)(mouseButtons & ~1);
        else if (msg == WM_RBUTTONDOWN) mouseButtons |= 2;
        else if (msg == WM_RBUTTONUP) mouseButtons = (byte)(mouseButtons & ~2);
        else if (msg == WM_MBUTTONDOWN) mouseButtons |= 4;
        else if (msg == WM_MBUTTONUP) mouseButtons = (byte)(mouseButtons & ~4);
        else if (msg == WM_XBUTTONDOWN) mouseButtons |= (byte)((HighWord(data.mouseData) == 1) ? 8 : 16);
        else if (msg == WM_XBUTTONUP) mouseButtons = (byte)(mouseButtons & ~((HighWord(data.mouseData) == 1) ? 8 : 16));
        else if (msg == WM_MOUSEWHEEL) wheel = Math.Sign((short)HighWord(data.mouseData));
        else if (msg == WM_MOUSEHWHEEL) hWheel = Math.Sign((short)HighWord(data.mouseData));
        try { SendMouse(dx, dy, wheel, hWheel); } catch { MarkDisconnected(); }
        return new IntPtr(1);
    }

    void SendKeyboard() {
        byte[] report = new byte[8]; report[0] = modifiers; int i = 2;
        foreach (byte key in keys) { if (i == report.Length) break; report[i++] = key; }
        SendInput(KEYBOARD_ID, report);
    }
    void SendMouse(int dx, int dy, int wheel, int hWheel) {
        while (dx != 0 || dy != 0) {
            int x = Clamp(dx), y = Clamp(dy); SendInput(MOUSE_ID, new byte[] { mouseButtons, unchecked((byte)(sbyte)x), unchecked((byte)(sbyte)y), 0, 0 });
            dx -= x; dy -= y;
        }
        if (dx == 0 && dy == 0) SendInput(MOUSE_ID, new byte[] { mouseButtons, 0, 0, unchecked((byte)(sbyte)wheel), unchecked((byte)(sbyte)hWheel) });
    }
    void ReleaseAll() { modifiers = mouseButtons = 0; keys.Clear(); if (IsSocketAlive()) { SendKeyboard(); SendMouse(0, 0, 0, 0); } }
    void SendCreate(ushort id, byte[] descriptor) {
        using (var ms = new MemoryStream()) using (var bw = new BinaryWriter(ms)) {
            bw.Write(UHID_CREATE); Write16(bw, id); Write16(bw, 0); Write16(bw, 0); bw.Write((byte)0); Write16(bw, (ushort)descriptor.Length); bw.Write(descriptor); Send(ms.ToArray());
        }
    }
    void SendInput(ushort id, byte[] report) {
        using (var ms = new MemoryStream()) using (var bw = new BinaryWriter(ms)) { bw.Write(UHID_INPUT); Write16(bw, id); Write16(bw, (ushort)report.Length); bw.Write(report); Send(ms.ToArray()); }
    }
    void SendDestroy(ushort id) { Send(new byte[] { UHID_DESTROY, (byte)(id >> 8), (byte)id }); }
    void Send(byte[] data) { lock (sendLock) { if (stream == null) throw new IOException("Control socket is closed."); stream.Write(data, 0, data.Length); stream.Flush(); } }
    static void Write16(BinaryWriter bw, ushort value) { bw.Write((byte)(value >> 8)); bw.Write((byte)value); }
    bool IsSocketAlive() { return client != null && client.Connected && stream != null; }
    void MarkDisconnected() { state = RoutingState.Disconnected; var callback = Disconnected; if (callback != null) callback(); }

    ProcessStartInfo AdbStartInfo(params string[] args) {
        var psi = new ProcessStartInfo { FileName = adbPath, UseShellExecute = false, CreateNoWindow = true, RedirectStandardError = true, RedirectStandardOutput = true };
        var all = new List<string>(); all.Add("-s"); all.Add(serial); all.AddRange(args); psi.Arguments = Quote(all); return psi;
    }
    string RunAdb(int timeout, params string[] args) {
        using (var p = Process.Start(AdbStartInfo(args))) { string stdout = p.StandardOutput.ReadToEnd(), stderr = p.StandardError.ReadToEnd(); if (!p.WaitForExit(timeout)) { p.Kill(); throw new TimeoutException("ADB command timed out."); } if (p.ExitCode != 0) throw new InvalidOperationException("ADB failed: " + stderr); return stdout.Trim(); }
    }
    static string Quote(IEnumerable<string> args) { var result = new List<string>(); foreach (string value in args) result.Add(value.IndexOfAny(new[] {' ', '\"'}) >= 0 ? "\"" + value.Replace("\"", "\\\"") + "\"" : value); return string.Join(" ", result.ToArray()); }
    static int GetFreePort() { var listener = new System.Net.Sockets.TcpListener(System.Net.IPAddress.Loopback, 0); listener.Start(); int port = ((System.Net.IPEndPoint)listener.LocalEndpoint).Port; listener.Stop(); return port; }
    static int Clamp(int value) { return Math.Max(-127, Math.Min(127, value)); }
    static int HighWord(uint value) { return (int)((value >> 16) & 0xffff); }

    public void Dispose() {
        if (disposed) return; disposed = true;
        state = RoutingState.ReturningWindows;
        try { ReleaseAll(); SendDestroy(KEYBOARD_ID); SendDestroy(MOUSE_ID); } catch { }
        if (keyboardHook != IntPtr.Zero) { UnhookWindowsHookEx(keyboardHook); keyboardHook = IntPtr.Zero; }
        if (mouseHook != IntPtr.Zero) { UnhookWindowsHookEx(mouseHook); mouseHook = IntPtr.Zero; }
        try { if (stream != null) stream.Dispose(); } catch { } try { if (client != null) client.Dispose(); } catch { }
        try { if (serverProcess != null && !serverProcess.HasExited) serverProcess.Kill(); } catch { }
        try { RunAdb(3000, "forward", "--remove", "tcp:" + localPort); } catch { }
        state = RoutingState.Windows;
    }

    static byte ModifierFor(uint vk) { switch (vk) { case 0xA2: return 1; case 0xA0: return 2; case 0xA4: return 4; case 0x5B: return 8; case 0xA3: return 16; case 0xA1: return 32; case 0xA5: return 64; case 0x5C: return 128; default: return 0; } }
    static byte HidFor(uint vk) {
        if (vk >= 0x41 && vk <= 0x5A) return (byte)(4 + vk - 0x41);
        if (vk >= 0x31 && vk <= 0x39) return (byte)(30 + vk - 0x31);
        if (vk == 0x30) return 39;
        if (vk >= 0x70 && vk <= 0x7B) return (byte)(58 + vk - 0x70);
        switch (vk) { case 0x0D:return 40; case 0x1B:return 41; case 0x08:return 42; case 0x09:return 43; case 0x20:return 44; case 0xBD:return 45; case 0xBB:return 46; case 0xDB:return 47; case 0xDD:return 48; case 0xDC:return 49; case 0xBA:return 51; case 0xDE:return 52; case 0xC0:return 53; case 0xBC:return 54; case 0xBE:return 55; case 0xBF:return 56; case 0x14:return 57; case 0x2C:return 70; case 0x2D:return 73; case 0x24:return 74; case 0x21:return 75; case 0x2E:return 76; case 0x23:return 77; case 0x22:return 78; case 0x27:return 79; case 0x25:return 80; case 0x28:return 81; case 0x26:return 82; default:return 0; }
    }

    static readonly byte[] KeyboardDescriptor = {0x05,0x01,0x09,0x06,0xA1,0x01,0x05,0x07,0x19,0xE0,0x29,0xE7,0x15,0x00,0x25,0x01,0x75,0x01,0x95,0x08,0x81,0x02,0x75,0x08,0x95,0x01,0x81,0x01,0x05,0x08,0x19,0x01,0x29,0x05,0x75,0x01,0x95,0x05,0x91,0x02,0x75,0x03,0x95,0x01,0x91,0x01,0x05,0x07,0x19,0x00,0x29,0x65,0x15,0x00,0x25,0x65,0x75,0x08,0x95,0x06,0x81,0x00,0xC0};
    static readonly byte[] MouseDescriptor = {0x05,0x01,0x09,0x02,0xA1,0x01,0x09,0x01,0xA1,0x00,0x05,0x09,0x19,0x01,0x29,0x05,0x15,0x00,0x25,0x01,0x95,0x05,0x75,0x01,0x81,0x02,0x95,0x01,0x75,0x03,0x81,0x01,0x05,0x01,0x09,0x30,0x09,0x31,0x09,0x38,0x15,0x81,0x25,0x7F,0x75,0x08,0x95,0x03,0x81,0x06,0x05,0x0C,0x0A,0x38,0x02,0x15,0x81,0x25,0x7F,0x75,0x08,0x95,0x01,0x81,0x06,0xC0,0xC0};

    [StructLayout(LayoutKind.Sequential)] struct Point { public int x, y; }
    [StructLayout(LayoutKind.Sequential)] struct KbdData { public uint vkCode, scanCode, flags, time; public UIntPtr extraInfo; }
    [StructLayout(LayoutKind.Sequential)] struct MouseData { public Point pt; public uint mouseData, flags, time; public UIntPtr extraInfo; }
    [DllImport("user32.dll", SetLastError=true)] static extern IntPtr SetWindowsHookEx(int id, HookProc callback, IntPtr module, uint threadId);
    [DllImport("user32.dll")] static extern bool UnhookWindowsHookEx(IntPtr hook);
    [DllImport("user32.dll")] static extern IntPtr CallNextHookEx(IntPtr hook, int code, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] static extern int GetSystemMetrics(int index);
    [DllImport("user32.dll")] static extern bool SetCursorPos(int x, int y);
}
