namespace WidgetSampleCS
{
    sealed class DesktopStatus
    {
        public string State { get; private set; } = "checking";
        public bool CanInstall { get; private set; }
        public void Reset() { State = "checking"; CanInstall = false; }
        public void Unavailable() { State = "unknown"; CanInstall = false; }
        public bool Receive(string line) {
            var parts = line.Split('|');
            if (parts.Length != 4 || parts[0] != "DESKTOP" || (parts[3] != "0" && parts[3] != "1")) return false;
            string state;
            if (parts[1] == "installed" && (parts[2] == "closed" || parts[2] == "running")) state = parts[2];
            else if (parts[1] == "missing" && parts[2] == "closed") state = "missing";
            else if (parts[1] == "unknown" && parts[2] == "unknown" && parts[3] == "0") state = "unknown";
            else return false;
            State = state; CanInstall = parts[3] == "1"; return true;
        }
    }
}
