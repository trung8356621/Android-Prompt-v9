using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public sealed class AndroidPromptWindow : NativeWindow, IDisposable {
    const int WM_HOTKEY = 0x0312;
    const int WM_CAPTURE_ANDROID = 0x8002, WM_RETURN_WINDOWS = 0x8003;
    const uint MOD_ALT = 0x0001, MOD_NOREPEAT = 0x4000;
    const int ENTER = 0x901, EXIT_ANDROID = 0x902, SEND_IMAGE = 0x903, CAPTURE = 0x904;
    public event Action EnterAndroid;
    public event Action ExitAndroid;
    public event Action SendImage;
    public event Action CaptureAndroid;
    volatile bool androidActive;

    [DllImport("user32.dll", SetLastError=true)] static extern bool RegisterHotKey(IntPtr h, int id, uint mod, uint key);
    [DllImport("user32.dll")] static extern bool UnregisterHotKey(IntPtr h, int id);
    [DllImport("user32.dll")] static extern bool PostMessage(IntPtr h, int message, IntPtr wParam, IntPtr lParam);

    public AndroidPromptWindow() {
        CreateHandle(new CreateParams());
        try {
            Register(ENTER, 0x31); Register(EXIT_ANDROID, 0x32); Register(SEND_IMAGE, 0x33); Register(CAPTURE, 0x34);
        } catch { Dispose(); throw; }
    }
    public void RequestReturnWindows() { PostMessage(Handle, WM_RETURN_WINDOWS, IntPtr.Zero, IntPtr.Zero); }
    public void RequestCaptureAndroid() { PostMessage(Handle, WM_CAPTURE_ANDROID, IntPtr.Zero, IntPtr.Zero); }
    public void SetAndroidActive(bool active) {
        if (androidActive == active) return;
        androidActive = active;
    }
    public bool IsAndroidActive { get { return androidActive; } }
    void Register(int id, uint key) {
        if (!RegisterHotKey(Handle, id, MOD_ALT | MOD_NOREPEAT, key) &&
            !RegisterHotKey(Handle, id, MOD_ALT, key))
            throw new InvalidOperationException("Cannot register Alt+" + (char)key + "; another app owns it.");
    }
    protected override void WndProc(ref Message m) {
        if (m.Msg == WM_HOTKEY) {
            switch (m.WParam.ToInt32()) {
                case ENTER: if (EnterAndroid != null) EnterAndroid(); break;
                case EXIT_ANDROID: if (ExitAndroid != null) ExitAndroid(); break;
                case SEND_IMAGE: if (SendImage != null) SendImage(); break;
                case CAPTURE: if (CaptureAndroid != null) CaptureAndroid(); break;
            }
        } else if (m.Msg == WM_CAPTURE_ANDROID && CaptureAndroid != null) {
            CaptureAndroid();
        } else if (m.Msg == WM_RETURN_WINDOWS && ExitAndroid != null) {
            ExitAndroid();
        }
        base.WndProc(ref m);
    }
    public void Dispose() {
        if (Handle != IntPtr.Zero) {
            UnregisterHotKey(Handle, ENTER); UnregisterHotKey(Handle, EXIT_ANDROID); UnregisterHotKey(Handle, SEND_IMAGE); UnregisterHotKey(Handle, CAPTURE);
            DestroyHandle();
        }
    }
}
