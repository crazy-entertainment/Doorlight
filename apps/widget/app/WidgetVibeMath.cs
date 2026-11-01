using System;

namespace WidgetSampleCS
{
    static class WidgetVibeMath
    {
        public static double Unit(double value) => Math.Max(0, Math.Min(1, value));
        public static double Wrap(double value, double span) => span > 0 ? (value % span + span) % span : 0;
        public static double Seed(int index, double salt) => Wrap(Math.Sin(index * 12.9898 + salt) * 43758.5453, 1);
        public static int Count(double width, double height, double intensity) =>
            (int)Math.Round(Math.Max(14, Math.Min(48, Math.Round(width * height / 14000))) * Unit(intensity));
        public static double Edge(double x, double y, double width, double height) {
            if (width <= 0 || height <= 0) return 0;
            double edge = Math.Max(Math.Abs(Unit(x / width) - .5) * 2, Math.Abs(Unit(y / height) - .5) * 2);
            return .18 + .82 * Math.Pow(edge, 3);
        }
        public static bool Animate(bool foreground, bool loaded, bool animated, string vibe, double opacity, double intensity) =>
            foreground && loaded && animated && (vibe == "rain" || vibe == "snow" || vibe == "halloween") && opacity > 0 && intensity > 0;
    }
}
