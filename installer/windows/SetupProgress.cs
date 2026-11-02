namespace Doorlight.Setup;

// Keep one latest value instead of posting a UI message for every archive chunk.
// Slow status readers must not fill the message queue and strand continuations.
internal sealed class SetupProgress : IProgress<InstallProgress>, IDisposable
{
    private InstallProgress? latest;
    private readonly Action<InstallProgress> present;
    private readonly UiTimer timer = new() { Interval = 100 };

    internal SetupProgress(Action<InstallProgress> present)
    {
        this.present = present;
        timer.Tick += (_, _) => Flush();
        timer.Start();
    }

    public void Report(InstallProgress value) => Interlocked.Exchange(ref latest, value);

    private void Flush()
    {
        var value = Interlocked.Exchange(ref latest, null);
        if (value is not null) present(value);
    }

    public void Dispose()
    {
        timer.Stop();
        timer.Dispose();
        Flush();
    }
}
