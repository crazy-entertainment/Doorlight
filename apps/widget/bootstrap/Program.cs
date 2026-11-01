// Package broker for desktop install discovery and fixed Open/Install actions only.
// All application state and input belong to Doorlight's authenticated overlay endpoint.
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;
static class P
{
    static readonly string Version = typeof(P).Assembly.GetName().Version.ToString(3);
    static string logPath;
    static readonly object gate=new();
    static StreamWriter pipeOut;
    static void Log(string text) { lock(gate) File.AppendAllText(logPath,DateTime.UtcNow.ToString("O")+" "+text+"\n"); }
    static void Send(string text) {lock(gate) {try{pipeOut?.WriteLine(text);}catch{pipeOut=null;}}}
    static void Check(bool ok,string action) {if(!ok)throw new IOException(action+" failed: "+Marshal.GetLastWin32Error());}
    static int Main(string[] args)
    {
        if (args.Length == 1 && args[0] == "--desktop-status") { Console.WriteLine(DesktopSetup.Status()); return 0; }


        int familyLength = 0;
        if (GetCurrentPackageFamilyName(ref familyLength, null) == 122) {
            var family = new StringBuilder(familyLength);
            if (GetCurrentPackageFamilyName(ref familyLength, family) == 0) args = new[] { family.ToString() };
        }
        if (args.Length < 1) { Console.WriteLine("usage: helper <PackageFamilyName>"); return 2; }
        if (args[0] != "DoorlightOverlayProto_ygmhnd3vvdymm") return 2;
        using var instance = new Mutex(true, @"Local\DoorlightProtoHelper-" + args[0], out bool created);
        if (!created) return 0;
        var stateFolder = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Packages", args[0], "LocalState");
        Directory.CreateDirectory(stateFolder);
        logPath = Path.Combine(stateFolder, "helper.log");
        AppDomain.CurrentDomain.UnhandledException += (s, e) => Log("helper failure: " + e.ExceptionObject);
        Log("helper family " + args[0]);
        PipeLoop(args[0]);
        return 0;
    }

    // The widget runs in an AppContainer; the pipe must live in its namespace and admit it.
    static void PipeLoop(string pfn)
    {
        Check(DeriveAppContainerSidFromAppContainerName(pfn, out var sidPtr) == 0, "derive sid");
        string sid = null;
        if (sidPtr == IntPtr.Zero) {
            // Windows returns null for its own package; resolve the existing user mapping.
            using var mappings = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(@"Software\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppContainer\Mappings");
            foreach (var mappingName in mappings?.GetSubKeyNames() ?? Array.Empty<string>()) {
                using var entry = mappings.OpenSubKey(mappingName);
                if (!string.Equals(entry?.GetValue("Moniker") as string, pfn, StringComparison.OrdinalIgnoreCase)) continue;
                sid = new System.Security.Principal.SecurityIdentifier(mappingName).Value; break;
            }
            Check(sid != null, "registered package sid");
        } else {
            try {
                Check(ConvertSidToStringSid(sidPtr, out var sidText), "convert appcontainer sid");
                sid = Marshal.PtrToStringUni(sidText); LocalFree(sidText);
            } finally { FreeSid(sidPtr); }
        }
        ProcessIdToSessionId((uint)Environment.ProcessId, out var session);
        string name = $@"\\.\pipe\Sessions\{session}\AppContainerNamedObjects\{sid}\doorlight-proto";
        Log($"pipe {name}");
        while (true)
        {
            var owner = System.Security.Principal.WindowsIdentity.GetCurrent().User?.Value;
            if (string.IsNullOrEmpty(owner)) throw new IOException("User identity unavailable");
            Check(ConvertStringSecurityDescriptorToSecurityDescriptor("D:P(A;;GA;;;SY)(A;;GA;;;" + owner + ")(A;;GRGW;;;" + sid + ")S:(ML;;NW;;;LW)", 1, out var sd, IntPtr.Zero), "sddl");
            var sa = new SECURITY_ATTRIBUTES { nLength = Marshal.SizeOf<SECURITY_ATTRIBUTES>(), lpSecurityDescriptor = sd };
            var h = CreateNamedPipe(name, 0x3 | 0x40000000 | 0x80000, 0x8, 1, 65536, 65536, 0, ref sa);
            LocalFree(sd);
            if (h.IsInvalid) { Log($"CreateNamedPipe failed {Marshal.GetLastWin32Error()}"); Thread.Sleep(3000); continue; }
            using var pipe = new NamedPipeServerStream(PipeDirection.InOut, true, false, h);
            pipe.WaitForConnection();
            bool desktopAuthorized = DesktopSetup.Authorized(pipe);
            if (!desktopAuthorized) continue;
            lock (gate) pipeOut = new StreamWriter(pipe, new UTF8Encoding(false)) { AutoFlush = true };
            Log("widget connected");
            Log("desktop setup client authorized=" + desktopAuthorized);
            Send("HELLO|" + Version);
            BootstrapInput.ReadCommands(pipe, line => OnWidget(line, desktopAuthorized));
            if (!desktopAuthorized) continue;
            lock (gate) pipeOut = null;

            Log("widget disconnected");
        }
    }

    static void OnWidget(string line, bool desktopAuthorized)
    {
        switch (line)
        {
            case "DESKTOP_STATUS": if (desktopAuthorized) Send(DesktopSetup.Status()); break;
            case "DESKTOP_OPEN": if (desktopAuthorized) { Send(DesktopSetup.Open(false)); Send(DesktopSetup.Status()); } break;
            case "DESKTOP_INSTALL": if (desktopAuthorized) { Send(DesktopSetup.Open(true)); Send(DesktopSetup.Status()); } break;
        }
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern int GetCurrentPackageFamilyName(ref int length, StringBuilder family);
    [DllImport("advapi32.dll")] static extern IntPtr FreeSid(IntPtr sid);
    [DllImport("kernel32.dll")] static extern bool ProcessIdToSessionId(uint pid, out uint session);
    [DllImport("kernel32.dll")] static extern IntPtr LocalFree(IntPtr p);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern SafePipeHandle CreateNamedPipe(string name, uint openMode, uint pipeMode, uint maxInst, uint outBuf, uint inBuf, uint timeout, ref SECURITY_ATTRIBUTES sa);
    [DllImport("userenv.dll", CharSet = CharSet.Unicode)] static extern int DeriveAppContainerSidFromAppContainerName(string name, out IntPtr sid);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern bool ConvertSidToStringSid(IntPtr sid, out IntPtr str);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern bool ConvertStringSecurityDescriptorToSecurityDescriptor(string sddl, uint rev, out IntPtr sd, IntPtr size);
    [StructLayout(LayoutKind.Sequential)] struct SECURITY_ATTRIBUTES {public int nLength;public IntPtr lpSecurityDescriptor;public int bInheritHandle;}
}
