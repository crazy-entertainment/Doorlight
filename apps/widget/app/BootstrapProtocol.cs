using System;

namespace WidgetSampleCS
{
    // This channel carries installation status only, never overlay input or receipts.
    static class BootstrapProtocol
    {
        internal const int MaxLine = 256;
        internal static bool TryParse(string line, out string version)
        {
            version = null;
            if (line == null || line.Length > MaxLine || line.IndexOfAny(new[] { '\r', '\n', '\0' }) >= 0) return false;
            if (line.StartsWith("HELLO|", StringComparison.Ordinal)) {
                string candidate = line.Substring(6);
                if (!Version.TryParse(candidate, out var parsed) || parsed.Build < 0 || parsed.ToString() != candidate ||
                    parsed.Major > 65535 || parsed.Minor > 65535 || parsed.Build > 65535 || parsed.Revision > 65535) return false;
                version = candidate;
                return true;
            }
            if (line.StartsWith("DESKTOP|", StringComparison.Ordinal)) return new DesktopStatus().Receive(line);
            switch (line) {
                case "DESKTOP_ACTION|opened":
                case "DESKTOP_ACTION|installed":
                case "DESKTOP_ACTION|download_opened":
                case "DESKTOP_ACTION|unavailable":
                case "DESKTOP_ACTION|failed": return true;
                default: return false;
            }
        }
        internal static bool IsCommand(string line) => line == "DESKTOP_STATUS" || line == "DESKTOP_OPEN" || line == "DESKTOP_INSTALL";
    }
}
