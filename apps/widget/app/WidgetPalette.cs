namespace WidgetSampleCS
{
    // These stable names can be mapped to Doorlight's settings when sync is added.
    sealed class WidgetPalette
    {
        public string Id, Background, Desk, Surface, High, Top, Accent, Fill, Pressed, Ink, Muted, Faint, Danger, Border, Selected, OnAccent, Sky;
        public bool Serif;
        public string ButtonFill => Id == "disaccord" ? "#1F97979F" : High;
        public string ButtonHover => Id == "disaccord" ? "#2997979F" : Top;
        public string ButtonPressed => Id == "disaccord" ? "#3397979F" : Selected;
        public string ButtonBorder => Id == "disaccord" ? "#0A97979F" : Border;
        public string FieldBorder => Id == "disaccord" ? "#14EFEFF1" : Border;
        public string ActiveTab => Id == "disaccord" ? Fill : Selected;
        public string ActiveTabInk => Id == "disaccord" ? OnAccent : Ink;
        public double HeadingSize => Id == "disaccord" ? 28 : 34;

        public static readonly WidgetPalette Disaccord = new WidgetPalette {
            Id = "disaccord", Background = "#202024", Desk = "#121214", Surface = "#1A1A1E", High = "#242429", Top = "#2C2D32",
            Accent = "#8CA0FD", Fill = "#5865F2", Pressed = "#3A48A3", Ink = "#EFEFF1", Muted = "#ABACB2", Faint = "#96979E",
            Danger = "#F87E7A", Border = "#21EFEFF1", Selected = "#30345A", OnAccent = "#FFFFFF", Sky = "#4D96EE"
        };
        public static readonly WidgetPalette Cozy = new WidgetPalette {
            Id = "cozy", Background = "#211714", Desk = "#140E0C", Surface = "#2A1D19", High = "#34231F", Top = "#422C26",
            Accent = "#F2B775", Fill = "#F2B775", Pressed = "#E69A4E", Ink = "#F4E9DF", Muted = "#B49D90", Faint = "#B19A8F",
            Danger = "#E36E63", Border = "#6B5044", Selected = "#513928", OnAccent = "#211714", Sky = "#A5BFDA", Serif = true
        };
        public static readonly WidgetPalette Midnight = new WidgetPalette {
            Id = "midnight", Background = "#0B0D12", Desk = "#07090D", Surface = "#11131A", High = "#181C26", Top = "#222735",
            Accent = "#9BB8D6", Fill = "#9BB8D6", Pressed = "#7F9FCA", Ink = "#E8ECF3", Muted = "#9CA5B4", Faint = "#8993A3",
            Danger = "#E16E69", Border = "#465164", Selected = "#283547", OnAccent = "#0B0D12", Sky = "#9BB8D6", Serif = true
        };
        public static WidgetPalette For(string id) => id == "disaccord" || id == "calm" ? Disaccord : id == "midnight" ? Midnight : Cozy;
    }
}
