using System.Reflection;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;

namespace Doorlight.Setup;

internal class DoorlightWindow : SynchronizationContext, IDisposable
{
    private readonly object dispatchLock = new();
    private readonly Dictionary<ulong, Action> dispatch = [];
    private readonly Dictionary<uint, UiTimer> timers = [];
    private readonly SynchronizationContext? previousContext;
    private GCHandle self;
    private nint host;
    private ulong nextDispatch;
    private uint nextTimer = 100;
    internal nint Handle => NativeUi.Hwnd(host);
    internal bool IsDisposed { get; private set; }
    internal event EventHandler? Started, ActionClicked, CancelClicked, Licenses;
    internal Func<bool>? CloseRequested;

    protected unsafe DoorlightWindow(bool motion)
    {
        previousContext = Current;
        self = GCHandle.Alloc(this);
        try
        {
            var hanken = Font("HankenGrotesk-Variable.ttf");
            var fraunces = Font("Fraunces-Variable.ttf");
            fixed (byte* h = hanken, f = fraunces)
                host = NativeUi.Create(&Callback, GCHandle.ToIntPtr(self), motion ? 1 : 0, h, hanken.Length, f, fraunces.Length);
            if (host == 0) throw new IOException("The setup window could not open.");
            SetSynchronizationContext(this);
        }
        catch { self.Free(); throw; }
    }

    private static byte[] Font(string name)
    {
        using var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream("Doorlight." + name)
            ?? throw new InvalidDataException("The setup font is missing.");
        using var bytes = new MemoryStream();
        stream.CopyTo(bytes);
        return bytes.ToArray();
    }

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    private static int Callback(nint context, int kind, nint argument)
    {
        var window = (DoorlightWindow)GCHandle.FromIntPtr(context).Target!;
        // Never unwind a managed exception through the native window procedure.
        try { return window.OnEvent(kind, argument); }
        catch (Exception exception)
        {
            Environment.ExitCode = 1;
            NativeUi.ShowError(exception is IOException ? "Setup could not finish. Your profile was kept." : exception.Message);
            return kind == 2 ? 1 : 0;
        }
    }

    private int OnEvent(int kind, nint argument)
    {
        switch (kind)
        {
            case 1: Started?.Invoke(this, EventArgs.Empty); break;
            case 2: return CloseRequested?.Invoke() == true ? 1 : 0;
            case 3: ActionClicked?.Invoke(this, EventArgs.Empty); break;
            case 4: CancelClicked?.Invoke(this, EventArgs.Empty); break;
            case 5: Licenses?.Invoke(this, EventArgs.Empty); break;
            case 6: if (timers.TryGetValue((uint)argument, out var timer)) timer.Fire(); break;
            case 7:
                Action? action;
                lock (dispatchLock) dispatch.Remove((ulong)argument, out action);
                action?.Invoke();
                break;
            case 8: lock (dispatchLock) { IsDisposed = true; dispatch.Clear(); } break;
        }
        return 0;
    }

    public override void Post(SendOrPostCallback callback, object? state)
    {
        lock (dispatchLock)
        {
            if (IsDisposed) return;
            var token = ++nextDispatch;
            dispatch.Add(token, () => callback(state));
            if (NativeUi.Post(host, token) == 0) dispatch.Remove(token);
        }
    }

    internal void RunMessageLoop() => NativeUi.Run(host);
    internal void Hide() => NativeUi.Show(host, 0);
    internal void Close() => NativeUi.Close(host);
    internal void SetText(int slot, string text) => NativeUi.SetText(host, slot, text);
    internal void SetButton(int slot, bool visible, bool enabled) => NativeUi.SetButton(host, slot, visible ? 1 : 0, enabled ? 1 : 0);
    internal void SetProgress(double fraction, bool active) => NativeUi.Progress(host, fraction, active ? 1 : 0);
    internal uint StartTimer(UiTimer timer, uint interval)
    {
        var id = nextTimer++;
        timers.Add(id, timer);
        NativeUi.Timer(host, id, interval);
        return id;
    }
    internal void StopTimer(uint id) { timers.Remove(id); if (!IsDisposed) NativeUi.StopTimer(host, id); }
    public void Dispose() { Dispose(true); GC.SuppressFinalize(this); }
    protected virtual void Dispose(bool disposing)
    {
        if (!disposing || host == 0) return;
        lock (dispatchLock)
        {
            IsDisposed = true;
            dispatch.Clear();
            NativeUi.Destroy(host);
            host = 0;
        }
        timers.Clear();
        self.Free();
        SetSynchronizationContext(previousContext);
    }
}

internal sealed class UiTimer : IDisposable
{
    private readonly DoorlightWindow window = SynchronizationContext.Current as DoorlightWindow
        ?? throw new InvalidOperationException("A setup timer requires the UI thread.");
    private uint id;
    internal int Interval { get; init; }
    internal event EventHandler? Tick;
    internal void Start() { if (id == 0) id = window.StartTimer(this, checked((uint)Interval)); }
    internal void Stop() { if (id != 0) { window.StopTimer(id); id = 0; } }
    internal void Fire() => Tick?.Invoke(this, EventArgs.Empty);
    public void Dispose() => Stop();
}

internal class NativeText(DoorlightWindow window, int slot)
{
    protected DoorlightWindow Window { get; } = window;
    protected int Slot { get; } = slot;
    private string text = "";
    internal string Text { get => text; set { text = value; Window.SetText(Slot, value); } }
}
internal sealed class NativeButton(DoorlightWindow window, int slot) : NativeText(window, slot)
{
    private bool visible = true, enabled = true;
    internal bool Visible { get => visible; set { visible = value; Window.SetButton(Slot, visible, enabled); } }
    internal bool Enabled { get => enabled; set { enabled = value; Window.SetButton(Slot, visible, enabled); } }
    internal event EventHandler? Click;
    internal void InvokeClick() { if (enabled && visible) Click?.Invoke(this, EventArgs.Empty); }
}
internal sealed class NativeProgress(DoorlightWindow window)
{
    private double fraction;
    private bool active;
    internal double Fraction { get => fraction; set { fraction = value; window.SetProgress(fraction, active); } }
    internal bool Active { get => active; set { active = value; window.SetProgress(fraction, active); } }
}

internal static unsafe partial class NativeUi
{
    private const string Library = "doorlight_ui";
    [LibraryImport(Library, EntryPoint = "dl_create")]
    [UnmanagedCallConv(CallConvs = [typeof(CallConvCdecl)])]
    internal static partial nint Create(delegate* unmanaged[Cdecl]<nint, int, nint, int> callback, nint context, int motion, byte* hanken, int hankenLength, byte* fraunces, int frauncesLength);
    [LibraryImport(Library, EntryPoint = "dl_hwnd")] internal static partial nint Hwnd(nint host);
    [LibraryImport(Library, EntryPoint = "dl_show")] internal static partial void Show(nint host, int command);
    [LibraryImport(Library, EntryPoint = "dl_run")] internal static partial int Run(nint host);
    [LibraryImport(Library, EntryPoint = "dl_destroy")] internal static partial void Destroy(nint host);
    [LibraryImport(Library, EntryPoint = "dl_set_text", StringMarshalling = StringMarshalling.Utf16)] internal static partial void SetText(nint host, int slot, string text);
    [LibraryImport(Library, EntryPoint = "dl_set_button")] internal static partial void SetButton(nint host, int slot, int visible, int enabled);
    [LibraryImport(Library, EntryPoint = "dl_progress")] internal static partial void Progress(nint host, double fraction, int active);
    [LibraryImport(Library, EntryPoint = "dl_post")] internal static partial int Post(nint host, ulong token);
    [LibraryImport(Library, EntryPoint = "dl_timer")] internal static partial void Timer(nint host, uint id, uint interval);
    [LibraryImport(Library, EntryPoint = "dl_stop_timer")] internal static partial void StopTimer(nint host, uint id);
    [LibraryImport(Library, EntryPoint = "dl_close")] internal static partial void Close(nint host);
    [LibraryImport("user32.dll", EntryPoint = "MessageBoxW", StringMarshalling = StringMarshalling.Utf16)]
    private static partial int MessageBox(nint owner, string text, string caption, uint flags);
    [LibraryImport("user32.dll")]
    private static partial int SetProcessDpiAwarenessContext(nint context);
    internal static void Initialize() => SetProcessDpiAwarenessContext(-4);
    internal static void ShowError(string text) => MessageBox(0, text, "Doorlight", 0x10);
}
