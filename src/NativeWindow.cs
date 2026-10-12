using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public sealed class AndroidPromptWindow : NativeWindow, IDisposable {
    const int WM_HOTKEY = 0x0312;
    const int WH_KEYBOARD_LL = 13;
    const int WM_KEYDOWN = 0x0100, WM_KEYUP = 0x0101, WM_SYSKEYDOWN = 0x0104, WM_SYSKEYUP = 0x0105;
    const int VK_SNAPSHOT = 0x2C, VK_SHIFT = 0x10, VK_CONTROL = 0x11, VK_MENU = 0x12, VK_RMENU = 0xA5;
    const uint MOD_ALT = 0x0001, MOD_NOREPEAT = 0x4000;
    const int ENTER = 0x901, EXIT_ANDROID = 0x902, CAPTURE = 0x903, SCREENSHOT = 0x904;
    public event Action EnterAndroid;
    public event Action ExitAndroid;
    public event Action CaptureAndroid;
    delegate IntPtr KeyboardProc(int code, IntPtr wParam, IntPtr lParam);
    readonly KeyboardProc keyboardProc;
    IntPtr keyboardHook;
    volatile bool androidActive;

    [DllImport("user32.dll", SetLastError=true)] static extern bool RegisterHotKey(IntPtr h, int id, uint mod, uint key);
    [DllImport("user32.dll")] static extern bool UnregisterHotKey(IntPtr h, int id);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int command);
    [DllImport("user32.dll", SetLastError=true)] static extern IntPtr SetWindowsHookEx(int id, KeyboardProc callback, IntPtr module, uint threadId);
    [DllImport("user32.dll")] static extern bool UnhookWindowsHookEx(IntPtr hook);
    [DllImport("user32.dll")] static extern IntPtr CallNextHookEx(IntPtr hook, int code, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] static extern bool PostMessage(IntPtr h, int message, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] static extern short GetAsyncKeyState(int key);
    [DllImport("user32.dll")] static extern void keybd_event(byte key, byte scan, uint flags, UIntPtr extraInfo);

    public AndroidPromptWindow() {
        CreateHandle(new CreateParams());
        try {
            Register(ENTER, 0x31); Register(EXIT_ANDROID, 0x32); Register(CAPTURE, 0x34);
            keyboardProc = KeyboardCallback;
            keyboardHook = SetWindowsHookEx(WH_KEYBOARD_LL, keyboardProc, IntPtr.Zero, 0);
            if (keyboardHook == IntPtr.Zero) throw new InvalidOperationException("Cannot install keyboard hook.");
        } catch { Dispose(); throw; }
    }
    IntPtr KeyboardCallback(int code, IntPtr wParam, IntPtr lParam) {
        return CallNextHookEx(keyboardHook, code, wParam, lParam);
    }
    public static void ToggleScrcpyCapture() {
        const uint EXTENDED = 0x0001, KEYUP = 0x0002;
        keybd_event(VK_RMENU, 0, EXTENDED, UIntPtr.Zero);
        keybd_event(VK_RMENU, 0, EXTENDED | KEYUP, UIntPtr.Zero);
    }
    public void SetAndroidActive(bool active) {
        if (androidActive == active) return;
        if (active) {
            if (!RegisterHotKey(Handle, SCREENSHOT, MOD_NOREPEAT, VK_SNAPSHOT) &&
                !RegisterHotKey(Handle, SCREENSHOT, 0, VK_SNAPSHOT))
                throw new InvalidOperationException("Cannot reserve PrtScr for Android capture.");
            androidActive = true;
        } else {
            androidActive = false;
            UnregisterHotKey(Handle, SCREENSHOT);
        }
    }
    public bool IsAndroidActive { get { return androidActive; } }
    public static bool WaitForLocalInputRelease(int timeoutMilliseconds) {
        int[] keys = { VK_SHIFT, VK_CONTROL, VK_MENU, 0x01, 0x02, 0x04, 0x05, 0x06 };
        DateTime deadline = DateTime.UtcNow.AddMilliseconds(timeoutMilliseconds);
        do {
            bool released = true;
            foreach (int key in keys) if ((GetAsyncKeyState(key) & 0x8000) != 0) { released = false; break; }
            if (released) return true;
            System.Threading.Thread.Sleep(10);
        } while (DateTime.UtcNow < deadline);
        return false;
    }
    void Register(int id, uint key) {
        if (!RegisterHotKey(Handle, id, MOD_ALT | MOD_NOREPEAT, key) &&
            !RegisterHotKey(Handle, id, MOD_ALT, key))
            throw new InvalidOperationException("Cannot register Alt+" + (char)key + "; another app owns it.");
    }
    public static bool Focus(IntPtr handle) {
        if (handle == IntPtr.Zero) return false;
        ShowWindow(handle, 4);
        return SetForegroundWindow(handle);
    }
    protected override void WndProc(ref Message m) {
        if (m.Msg == WM_HOTKEY) {
            switch (m.WParam.ToInt32()) {
                case ENTER: if (EnterAndroid != null) EnterAndroid(); break;
                case EXIT_ANDROID: if (ExitAndroid != null) ExitAndroid(); break;
                case CAPTURE: if (CaptureAndroid != null) CaptureAndroid(); break;
                case SCREENSHOT: if (androidActive && CaptureAndroid != null) CaptureAndroid(); break;
            }
        }
        base.WndProc(ref m);
    }
    public void Dispose() {
        if (Handle != IntPtr.Zero) {
            if (keyboardHook != IntPtr.Zero) { UnhookWindowsHookEx(keyboardHook); keyboardHook = IntPtr.Zero; }
            UnregisterHotKey(Handle, ENTER); UnregisterHotKey(Handle, EXIT_ANDROID); UnregisterHotKey(Handle, CAPTURE);
            UnregisterHotKey(Handle, SCREENSHOT);
            DestroyHandle();
        }
    }
}
