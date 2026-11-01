using System;
using Microsoft.Gaming.XboxGameBar;
using Windows.Data.Json;
using Windows.UI.Xaml;
using Windows.UI.Xaml.Controls;
using Windows.UI.Xaml.Navigation;

namespace WidgetSampleCS
{
    public sealed class VoiceWidget : Page
    {
        readonly StackPanel body = new StackPanel { Spacing = 10, Padding = new Thickness(14) };
        Element element;
        Action update;
        public VoiceWidget() { WidgetTheme.Attach(this); Content = body; }
        protected override void OnNavigatedTo(NavigationEventArgs e) {
            element = new Element("voice", (XboxGameBarWidget)e.Parameter, body);
            update = () => element.Ui(Render);
            OverlaySync.Changed += update;
            Unloaded += (s,a) => OverlaySync.Changed -= update;
            Render();
        }
        void Offers(JsonObject voice) {
            foreach(var item in voice.GetNamedArray("offers",new JsonArray())) {var offer=item.GetObject();string id=offer.GetNamedString("id");var button=new Button{Content="Join "+offer.GetNamedString("label"),IsEnabled=OverlaySync.Writable};button.Click+=(s,a)=>OverlaySync.Request("voice.join",OverlaySync.Args("token",id));body.Children.Add(button);}
            var chat=OverlaySync.State?.GetNamedObject("chat");if(chat!=null)foreach(var item in chat.GetNamedArray("conversations",new JsonArray())) {var conversation=item.GetObject();if(conversation.GetNamedString("kind","")!="direct")continue;string id=conversation.GetNamedString("id");var button=new Button{Content="Call "+conversation.GetNamedString("label"),IsEnabled=OverlaySync.Writable};button.Click+=(s,a)=>OverlaySync.Request("voice.start",OverlaySync.Args("token",id));body.Children.Add(button);}
        }
        void Render() {
            body.Children.Clear();
            var voice = OverlaySync.State?.GetNamedObject("voice");
            string kind = voice?.GetNamedString("kind", "none") ?? "none";
            body.Children.Add(new TextBlock { Text = "Voice", FontFamily = WidgetTheme.Heading, FontSize = 18 });
            if (voice == null || kind == "none") {
                string status=voice?.GetNamedString("status", "disconnected")??"disconnected";
                body.Children.Add(new TextBlock { Text = status=="locked"?"Unlock Doorlight to view voice.":voice == null||status=="disconnected" ? "Voice uses the Doorlight desktop app." : status=="consent"?"Show voice while gaming.":"No active call.", TextWrapping=TextWrapping.Wrap });
                if(status=="consent") {var enable=new Button{Content="Enable voice",IsEnabled=OverlaySync.Writable};enable.Click+=async(s,a)=>{if(OverlaySync.Request("chat.enable",new JsonObject()))await Windows.System.Launcher.LaunchUriAsync(new Uri("doorlight://open"));};body.Children.Add(enable);}
                if(voice!=null) Offers(voice); return;
            }
            body.Children.Add(new TextBlock { Text = voice.GetNamedString("phase", "") });
            foreach (var item in voice.GetNamedArray("participants", new JsonArray())) {
                var person = item.GetObject();
                bool knownSpeaking = person.TryGetValue("speaking", out var speaking) && speaking.ValueType == JsonValueType.Boolean && speaking.GetBoolean();
                body.Children.Add(new TextBlock { Text = person.GetNamedString("name", "") + ((person.TryGetValue("muted",out var muteState)&&muteState.ValueType==JsonValueType.Boolean&&muteState.GetBoolean()) ? " · Muted" : knownSpeaking ? " · Speaking" : ""), TextWrapping = TextWrapping.Wrap });
            }
            string token = voice.GetNamedString("token", "");
            if(voice.GetNamedBoolean("canAnswer",false)) {var answer=new Button{Content="Answer",IsEnabled=OverlaySync.Writable};answer.Click+=(s,a)=>OverlaySync.Request("voice.answer",OverlaySync.Args("token",token));body.Children.Add(answer);}
            if(voice.GetNamedBoolean("canDecline",false)) {var decline=new Button{Content="Decline",IsEnabled=OverlaySync.Writable};decline.Click+=(s,a)=>OverlaySync.Request("voice.decline",OverlaySync.Args("token",token));body.Children.Add(decline);}
            bool muted = voice.GetNamedBoolean("muted", true);
            var mute = new Button { Content = muted ? "Unmute" : "Mute", IsEnabled = OverlaySync.Writable && voice.GetNamedBoolean("canMute", false) };
            mute.Click += (s,a) => OverlaySync.Request("voice.mute", OverlaySync.Args("token", token, "muted", !muted)); body.Children.Add(mute);
            if(voice.GetNamedBoolean("canDeafen",false)) { bool deafened=voice.GetNamedBoolean("deafened",false); var deafen=new Button{Content=deafened?"Undeafen":"Deafen",IsEnabled=OverlaySync.Writable}; deafen.Click+=(s,a)=>OverlaySync.Request("voice.deafen",OverlaySync.Args("token",token,"deafened",!deafened));body.Children.Add(deafen); }
            var leave = new Button { Content = "Leave call", IsEnabled = OverlaySync.Writable && voice.GetNamedBoolean("canLeave", false) };
            leave.Click += (s,a) => OverlaySync.Request("voice.leave", OverlaySync.Args("token", token)); body.Children.Add(leave);
        }
    }
}
