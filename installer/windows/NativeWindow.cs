using System.Diagnostics;
using System.Runtime.InteropServices;

namespace Doorlight.Setup;

internal static class NativeWindow
{
    [StructLayout(LayoutKind.Sequential)]
    internal struct Rect { internal int Left, Top, Right, Bottom; internal int Width => Right - Left; internal int Height => Bottom - Top; internal bool IsEmpty => Width <= 0 || Height <= 0; }
    [DllImport("dwmapi.dll")] internal static extern int DwmSetWindowAttribute(IntPtr window, int attribute, ref int value, int size);
    [DllImport("dwmapi.dll")] private static extern int DwmGetWindowAttribute(IntPtr window, int attribute, out Rect value, int size);
    [DllImport("user32.dll")] private static extern bool GetWindowRect(IntPtr window, out Rect value);
    [DllImport("user32.dll")] internal static extern bool ShowWindow(IntPtr window, int command);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll")] private static extern bool IsIconic(IntPtr window);
    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumWindow callback, IntPtr parameter);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr window, out uint process);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] private static extern IntPtr GetProp(IntPtr window, string name);
    [DllImport("user32.dll")] private static extern bool SetWindowPos(IntPtr window, IntPtr after, int x, int y, int width, int height, uint flags);
    private delegate bool EnumWindow(IntPtr window, IntPtr parameter);

    internal static Rect VisibleBounds(IntPtr window)
    {
        if (DwmGetWindowAttribute(window, 9, out var visible, Marshal.SizeOf<Rect>()) == 0 && visible.Right > visible.Left) return visible;
        return GetWindowRect(window, out var outer) ? outer : default;
    }

    internal static bool WaitForVisible(Process process, IntPtr source, TimeSpan timeout, bool allowForwardedInstance = false)
    {
        // Minimized windows can report offscreen iconic bounds. Let the app
        // restore its own placement instead of handing those coordinates over.
        var target = source == IntPtr.Zero || IsIconic(source) ? default(Rect) : VisibleBounds(source);
        var deadline = Environment.TickCount64 + (long)timeout.TotalMilliseconds;
        while (Environment.TickCount64 < deadline)
        {
            if (process.HasExited) return allowForwardedInstance && process.ExitCode == 0;
            var found = IntPtr.Zero;
            EnumWindows((window, _) => {
                GetWindowThreadProcessId(window, out var owner);
                if (owner == process.Id && GetProp(window, "SybL.MainWindow.Invites.v1") != IntPtr.Zero) { found = window; return false; }
                return true;
            }, IntPtr.Zero);
            if (found != IntPtr.Zero)
            {
                if (!target.IsEmpty && GetWindowRect(found, out var outer))
                {
                    var visible = VisibleBounds(found);
                    SetWindowPos(found, IntPtr.Zero, target.Left - visible.Left + outer.Left,
                        target.Top - visible.Top + outer.Top,
                        target.Width + outer.Right - outer.Left - visible.Width,
                        target.Height + outer.Bottom - outer.Top - visible.Height, 0x14);
                }
                // The native runner shows its main window after a presented Flutter frame.
                if (IsWindowVisible(found)) return true;
            }
            Thread.Sleep(15);
        }
        return false;
    }
}
