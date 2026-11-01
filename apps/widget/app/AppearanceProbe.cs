#if DEBUG
using System;
using System.Diagnostics;
using System.Threading.Tasks;
using Windows.Storage;

namespace WidgetSampleCS
{
    public sealed partial class HelperWidget
    {
        async Task ProbeAppearance()
        {
            var folder = ApplicationData.Current.LocalFolder;
            var marker = await folder.TryGetItemAsync("verify-appearance-sync");
            if (marker == null) return;
            await marker.DeleteAsync();
            AppearanceSnapshot original = null;
            int test = -1;
            string result = "FAIL no authoritative snapshot";
            bool restored = false, ownsRecovery = false;
            string Values(AppearanceValues value) => "theme=" + value.Theme + ",vibe=" + value.Vibe + ",opacity=" + value.Opacity + ",intensity=" + value.Intensity + ",animated=" + value.Animated;
            async Task Wait(Func<bool> condition) {
                var elapsed = Stopwatch.StartNew();
                while (!condition()) {
                    if (elapsed.Elapsed.TotalSeconds > 15) throw new TimeoutException("Appearance probe confirmation timed out");
                    await Task.Delay(100);
                }
            }
            try {
                await Wait(() => AppearanceSync.Writable);
                original = AppearanceSync.CurrentSnapshot;
                test = original.Values.Opacity == 100 ? 99 : original.Values.Opacity + 1;
                var recovery = await folder.CreateFileAsync("appearance-probe-original.txt", CreationCollisionOption.FailIfExists);
                ownsRecovery = true;
                await FileIO.WriteTextAsync(recovery,
                    "originalOpacity=" + original.Values.Opacity + " testOpacity=" + test + " epoch=" + original.Epoch + " revision=" + original.Revision);
                if (!AppearanceSync.Request("vibeOpacity", test)) throw new InvalidOperationException("Probe patch refused");
                await Wait(() => AppearanceSync.Writable && AppearanceSync.CurrentSnapshot.Values.Opacity == test && AppearanceSync.CurrentSnapshot.Revision > original.Revision);
                var changed = AppearanceSync.CurrentSnapshot;
                if (changed.Epoch != original.Epoch) throw new InvalidOperationException("Doorlight restarted during probe");
                result = "PASS authoritative app snapshot; actual UWP package patch persisted and echoed; epoch=" + original.Epoch + "; initialRevision=" + original.Revision + " changedRevision=" + changed.Revision + "; original=" + Values(original.Values) + "; testOpacity=" + test;
            } catch (Exception ex) { result = "FAIL " + ex.GetType().Name + ": " + ex.Message + "; status=" + AppearanceSync.Message + "; connected=" + AppearanceSync.Connected; }
            finally {
                if (original != null && ownsRecovery) {
                    try {
                        await Wait(() => AppearanceSync.Writable);
                        var current = AppearanceSync.CurrentSnapshot;
                        if (current.Epoch != original.Epoch || current.Revision > original.Revision + 1 ||
                            current.Values.Theme != original.Values.Theme || current.Values.Vibe != original.Values.Vibe ||
                            current.Values.Intensity != original.Values.Intensity || current.Values.Animated != original.Values.Animated)
                            throw new InvalidOperationException("Concurrent app change; recovery record retained");
                        if (current.Values.Opacity == test) {
                            if (!AppearanceSync.Request("vibeOpacity", original.Values.Opacity)) throw new InvalidOperationException("Restore patch refused");
                            await Wait(() => AppearanceSync.Writable && AppearanceSync.CurrentSnapshot.Values.Opacity == original.Values.Opacity);
                        }
                        var last = AppearanceSync.CurrentSnapshot.Values;
                        restored = last.Opacity == original.Values.Opacity && last.Theme == original.Values.Theme && last.Vibe == original.Values.Vibe && last.Intensity == original.Values.Intensity && last.Animated == original.Values.Animated;
                        result += restored ? "; original appearance restored and confirmed" : "; FAIL concurrent appearance change or restore mismatch";
                        result += "; restored=" + Values(last) + "; restoredRevision=" + AppearanceSync.CurrentSnapshot.Revision;
                    } catch (Exception ex) { result += "; FAIL restore unconfirmed: " + ex.GetType().Name; }
                }
                if (restored && ownsRecovery) { var recovery = await folder.TryGetItemAsync("appearance-probe-original.txt"); if (recovery != null) await recovery.DeleteAsync(); }
                await FileIO.WriteTextAsync(await folder.CreateFileAsync("verify-appearance-sync-result.txt", CreationCollisionOption.ReplaceExisting), result);
                Log.Write("appearance probe: " + result);
            }
        }
    }
}
#endif
