using System.Diagnostics;
using System.Text.Json;
using System.Text.RegularExpressions;
using Microsoft.Win32;
using Microsoft.Win32.SafeHandles;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text;

static class DesktopSetup
{
    // Bootstrap actions require the exact package, user, session and process.
    public static bool Authorized(NamedPipeServerStream pipe)
    {
        try {
            var handle = pipe.SafePipeHandle;
            if (!GetNamedPipeClientProcessId(handle, out uint pid) ||
                !GetNamedPipeClientSessionId(handle, out uint session) ||
                !ProcessIdToSessionId((uint)Environment.ProcessId, out uint ownSession) || session != ownSession) return false;
            using var process = OpenProcess(0x1000, false, pid);
            if (process.IsInvalid) return false;
            var family = new StringBuilder(256); uint length = 256;
            if (GetPackageFamilyName(process, ref length, family) != 0 || family.ToString() != "DoorlightOverlayProto_ygmhnd3vvdymm") return false;
            if (!OpenProcessToken(process, 8, out var token)) return false;
            using (token) using (var client = new WindowsIdentity(token.DangerousGetHandle())) using (var own = WindowsIdentity.GetCurrent()) {
                return client.User != null && client.User == own.User &&
                    GetNamedPipeClientProcessId(handle, out uint confirmed) && confirmed == pid;
            }
        } catch { return false; }
    }
    [DllImport("kernel32.dll")] static extern bool GetNamedPipeClientProcessId(SafePipeHandle pipe, out uint pid);
    [DllImport("kernel32.dll")] static extern bool GetNamedPipeClientSessionId(SafePipeHandle pipe, out uint session);
    [DllImport("kernel32.dll")] static extern bool ProcessIdToSessionId(uint pid, out uint session);
    [DllImport("kernel32.dll")] static extern SafeProcessHandle OpenProcess(uint access, bool inherit, uint pid);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern int GetPackageFamilyName(SafeProcessHandle process, ref uint length, StringBuilder family);
    [DllImport("advapi32.dll")] static extern bool OpenProcessToken(SafeProcessHandle process, uint access, out SafeAccessTokenHandle token);

    public static string RegisteredExecutable(string command, Func<string, bool> exists, Func<string, string> product)
    {
        if (string.IsNullOrEmpty(command) || command.Any(char.IsControl)) return null;
        var match = Regex.Match(command, "^\"([^\"]+)\" \"%1\"$");
        if (!match.Success) return null;
        try {
            string path = match.Groups[1].Value;
            if (!Path.IsPathFullyQualified(path) || path.StartsWith(@"\\") || !string.Equals(Path.GetFileName(path), "sybl.exe", StringComparison.OrdinalIgnoreCase) ||
                !exists(path) || !exists(Path.Combine(Path.GetDirectoryName(path), "flutter_windows.dll"))) return null;
            string name = product(path);
            return name == "Doorlight" || name == "Syb-L" ? path : null;
        } catch { return null; }
    }

    public static string Download(string json)
    {
        try {
            if (json == null || json.Length > 8192) return null;
            using var document = JsonDocument.Parse(json);
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object) return null;
            var entries = root.EnumerateObject().ToArray();
            if (entries.Length != 3 || entries.Select(p => p.Name).Distinct().Count() != 3 || entries.Any(p => p.Name != "version" && p.Name != "desktopDownloadUrl" && p.Name != "widgetDownloadUrl") ||
                !root.GetProperty("version").TryGetInt32(out int version) || version != 1) return null;
            foreach (var key in new[] { "desktopDownloadUrl", "widgetDownloadUrl" }) {
                var value = root.GetProperty(key);
                if (value.ValueKind == JsonValueKind.Null) continue;
                if (value.ValueKind != JsonValueKind.String || !SafeUrl(value.GetString())) return null;
            }
            return root.GetProperty("desktopDownloadUrl").ValueKind == JsonValueKind.Null ? null : root.GetProperty("desktopDownloadUrl").GetString();
        } catch { return null; }
    }

    public static bool SafeUrl(string text)
    {
        if (string.IsNullOrWhiteSpace(text) || text.Length > 2048 || text.Any(c => char.IsControl(c) || char.IsWhiteSpace(c)) || text.Contains('?') || text.Contains('#')) return false;
        try {
            return !Uri.UnescapeDataString(text).Any(char.IsControl) && Uri.TryCreate(text, UriKind.Absolute, out var uri) && uri.Scheme == "https" &&
                uri.UserInfo.Length == 0 && uri.HostNameType == UriHostNameType.Dns && uri.Host.Contains('.') && !uri.IsLoopback &&
                !uri.Host.EndsWith(".localhost", StringComparison.OrdinalIgnoreCase) && !uri.Host.EndsWith(".local", StringComparison.OrdinalIgnoreCase);
        } catch { return false; }
    }

    static string Find()
    {
        using var key = Registry.CurrentUser.OpenSubKey(@"Software\Classes\doorlight\shell\open\command");
        return RegisteredExecutable(key?.GetValue(null, null, RegistryValueOptions.DoNotExpandEnvironmentNames) as string,
            File.Exists, path => FileVersionInfo.GetVersionInfo(path).ProductName);
    }
    static string Installer()
    {
        try {
            string file = Path.Combine(AppContext.BaseDirectory, "companion-links.json");
            return new FileInfo(file).Length <= 8192 ? Download(File.ReadAllText(file)) : null;
        } catch { return null; }
    }
    public static string Status()
    {
        try {
            string path = Find();
            bool running = false;
            if (path != null) foreach (var process in Process.GetProcessesByName("sybl")) {
                using (process) { try { if (string.Equals(process.MainModule?.FileName, path, StringComparison.OrdinalIgnoreCase)) running = true; } catch { } }
            }
            return "DESKTOP|" + (path == null ? "missing" : "installed") + "|" + (running ? "running" : "closed") + "|" + (Installer() == null ? "0" : "1");
        } catch { return "DESKTOP|unknown|unknown|0"; }
    }
    public static string Open(bool install)
    {
        try {
            if (install && Find() != null) return "DESKTOP_ACTION|installed";
            string target = install ? Installer() : Find() == null ? null : "doorlight://open";
            if (target == null) return "DESKTOP_ACTION|unavailable";
            Process.Start(new ProcessStartInfo(target) { UseShellExecute = true });
            return install ? "DESKTOP_ACTION|download_opened" : "DESKTOP_ACTION|opened";
        } catch { return "DESKTOP_ACTION|failed"; }
    }
}
