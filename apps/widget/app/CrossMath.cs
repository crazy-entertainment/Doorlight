using System;
using System.Linq;
using System.Collections.Generic;
namespace WidgetSampleCS
{
    static class CrossMath
    {
        // Partition the union into disjoint cells, excluding the body from the outline.
        public static IEnumerable<double[]> OutlineCells(IList<double[]> arms, double thickness)
        {
            if (thickness <= 0) yield break;
            var xs = arms.SelectMany(a => new[] { a[0] - thickness, a[0], a[0] + a[2], a[0] + a[2] + thickness }).Distinct().OrderBy(v => v).ToArray();
            var ys = arms.SelectMany(a => new[] { a[1] - thickness, a[1], a[1] + a[3], a[1] + a[3] + thickness }).Distinct().OrderBy(v => v).ToArray();
            for (int x = 0; x + 1 < xs.Length; x++)
                for (int y = 0; y + 1 < ys.Length; y++) {
                    double cx = (xs[x] + xs[x + 1]) / 2, cy = (ys[y] + ys[y + 1]) / 2;
                    bool Inside(double[] a, double padding) => cx > a[0] - padding && cx < a[0] + a[2] + padding && cy > a[1] - padding && cy < a[1] + a[3] + padding;
                    if (arms.Any(a => Inside(a, thickness)) && !arms.Any(a => Inside(a, 0)))
                        yield return new[] { xs[x], ys[y], xs[x + 1] - xs[x], ys[y + 1] - ys[y] };
                }
        }
        public static double Clamp(double v, double min, double max) => double.IsNaN(v) || double.IsInfinity(v) ? min : Math.Max(min, Math.Min(max, v));
        public static double ClampFadeEnd(double start, double end) => Clamp(end, 0, Clamp(start, 0, 240));
        public static double AimTransition(double elapsedMs, double durationMs, double from, bool aiming)
        {
            durationMs = Clamp(durationMs, 0, 750);
            double target = aiming ? 0 : 1;
            double progress = durationMs == 0 ? 1 : Clamp(elapsedMs / durationMs, 0, 1);
            return from + (target - from) * progress;
        }
        public static double AimFade(double elapsedMs, double durationMs, bool aiming)
        {
            if (!aiming) return 1;
            durationMs = Clamp(durationMs, 0, 750);
            return durationMs == 0 ? 0 : 1 - Clamp(elapsedMs / durationMs, 0, 1);
        }
        public static double Fade(double distance, double start, double end, bool eligible)
        {
            start = Clamp(start, 0, 240); end = Clamp(end, 0, start);
            if (!eligible || start == 0) return 1;
            if (start == end) return distance <= end ? 0 : 1;
            return Clamp((distance - end) / (start - end), 0, 1);
        }
    }
}
