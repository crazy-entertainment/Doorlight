using System;
using System.Linq;
using System.Collections.Generic;
using Microsoft.Gaming.XboxGameBar;
using Windows.Data.Json;
using Windows.System;
using Windows.UI;
using Windows.UI.Xaml;
using Windows.UI.Xaml.Controls;
using Windows.UI.Xaml.Input;
using Windows.UI.Xaml.Media;
using Windows.UI.Xaml.Navigation;

namespace WidgetSampleCS
{
    public sealed partial class ChatWidget : Page
    {
        sealed class Conversation { public string Id; public string Label { get; set; } }
        XboxGameBarWidget widget;
        Element element;
        Action changed;
        Action<string> settingsChanged;
        bool rendering, quickChat; Action<string> input; readonly ChatDrafts drafts=new ChatDrafts();
        string token="", selected="";
        string displayedToken;
        readonly MessageWindow<JsonObject> messageWindow = new MessageWindow<JsonObject>(6,row=>row.GetNamedString("id"),row=>row.Stringify());
        readonly DispatcherTimer age = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(500) };
        double width, height;
        string lastSubmission, lastCompose;
        public ChatWidget() { WidgetTheme.Attach(this); InitializeComponent(); }
        protected override void OnNavigatedTo(NavigationEventArgs e) {
            widget=(XboxGameBarWidget)e.Parameter; element=new Element("chat",widget,Root);
            changed=()=>element.Ui(Render); settingsChanged=k=>element.Ui(Render);
            OverlaySync.Changed+=changed; Cfg.Changed+=settingsChanged;
            input=line=>{if(line.StartsWith("INPUT|"))element.Ui(()=>Input(JsonObject.Parse(line.Substring(6))));};Link.Received+=input;
            widget.GameBarDisplayModeChanged+=(s,a)=>element.Ui(Render);
            widget.VisibleChanged+=(s,a)=>element.Ui(()=>Surface(widget.Visible ? (bool?)null : false));
            age.Tick+=(s,a)=>{Surface();if(widget.GameBarDisplayMode!=XboxGameBarDisplayMode.Foreground)Render();};age.Start();
            Unloaded+=(s,a)=>{Surface(false);age.Stop();OverlaySync.Changed-=changed;Cfg.Changed-=settingsChanged;Link.Received-=input;};Render();
        }
        JsonObject Chat => OverlaySync.State?.GetNamedObject("chat");
        void Surface(bool? visible = null) {
            if(!OverlaySync.Writable)return;
            var chat=Chat;
            string owner=chat?.GetNamedString("token","")??"";
            drafts.Bind(owner,chat?.GetNamedString("draftKey",""));
            var draft=drafts.For(owner);
            bool shown=(visible??(widget.Visible&&element.Visible&&chat?.GetNamedString("status","")=="ready"))&&chat?.GetNamedBoolean("canSend",false)==true&&!draft.Pending&&!draft.Unknown;
            OverlaySync.Request("chat.surface",OverlaySync.Args("token",owner,"visible",shown));
        }
        IEnumerable<JsonObject> VisibleMessages(JsonArray messages, bool foreground) {
            var rows=messages.Select(v=>v.GetObject()).ToArray();
            if(displayedToken!=token){displayedToken=token;messageWindow.Reset();}
            var now=DateTime.UtcNow;double minimum=Cfg.Get("chat.minSeconds",5.0),fade=Cfg.Get("chat.fadeSeconds",30.0);
            var projected=messageWindow.Project(rows,now,minimum,fade);
            return foreground?rows:projected;
        }
        void Render() {
            var chat=Chat; string status=chat?.GetNamedString("status","disconnected")??"disconnected";
            string nextToken=status=="ready"?(chat?.GetNamedString("token","")??""):"";
            if(nextToken.Length>0)drafts.Bind(nextToken,chat.GetNamedString("draftKey",""));
            if(nextToken!=token){if(token.Length>0&&!drafts.For(token).Pending&&!drafts.For(token).Unknown)drafts.For(token).Text=Composer.Text;token=nextToken;Composer.Text=drafts.For(token).Text;quickChat=false;}
            selected=chat!=null&&chat.TryGetValue("selected",out var selection)&&selection.ValueType==JsonValueType.String?selection.GetString():"";
            bool ready=status=="ready";
            if(!ready){messageWindow.Reset();displayedToken=null;quickChat=false;drafts.Interrupt();Composer.Text="";}
            else ReconcileInput();
            Status.Text=OverlaySync.Error??(ready?"":status=="consent"?"Show chat while gaming.":status=="locked"?"Unlock Doorlight to view chat.":"Chat uses the Doorlight desktop app.");
            if(ready&&OverlaySync.Error==null) {
                if(chat.GetNamedBoolean("loading",false))Status.Text="Loading messages…";
                else if(chat.GetNamedBoolean("error",false))Status.Text="Couldn’t load messages. Try again.";
            }
            Status.Visibility=Status.Text.Length==0?Visibility.Collapsed:Visibility.Visible;
            Enable.Visibility=status=="consent"?Visibility.Visible:Visibility.Collapsed;Enable.IsEnabled=OverlaySync.Writable;
            rendering=true;
            Conversations.Items.Clear();
            if(ready)foreach(var value in chat.GetNamedArray("conversations",new JsonArray())) {
                var row=value.GetObject();var option=new Conversation{Id=row.GetNamedString("id"),Label=row.GetNamedString("label")};
                Conversations.Items.Add(option);if(option.Id==selected)Conversations.SelectedItem=option;
            }
            rendering=false;Conversations.Visibility=ready?Visibility.Visible:Visibility.Collapsed;Conversations.IsEnabled=OverlaySync.Writable;
            Older.Visibility=ready&&chat.GetNamedBoolean("hasOlder",false)?Visibility.Visible:Visibility.Collapsed;Older.IsEnabled=OverlaySync.Writable;
            Latest.Visibility=ready?Visibility.Visible:Visibility.Collapsed;Latest.IsEnabled=OverlaySync.Writable;
            Messages.Children.Clear();
            if(ready)foreach(var row in VisibleMessages(chat.GetNamedArray("messages",new JsonArray()),widget.GameBarDisplayMode==XboxGameBarDisplayMode.Foreground)) {
                string author=row.GetNamedString("author","");bool own=row.GetNamedBoolean("own",false);
                var content=new StackPanel{Spacing=4,HorizontalAlignment=own?HorizontalAlignment.Right:HorizontalAlignment.Left};
                if(Cfg.Get("chat.names",true))content.Children.Add(new TextBlock{Text=author,FontFamily=WidgetTheme.Heading});
                if(Cfg.Get("chat.text",true))content.Children.Add(new TextBlock{Text=row.GetNamedString("text",""),TextWrapping=TextWrapping.Wrap,FontSize=Cfg.Get("chat.textSize",14.0)});
                string delivery=Delivery(row.GetNamedString("status",""));if(own&&delivery.Length>0)content.Children.Add(new TextBlock{Text=delivery,FontSize=10});
                var line=new StackPanel{Orientation=Orientation.Horizontal,Spacing=8,HorizontalAlignment=content.HorizontalAlignment};
                if(Cfg.Get("chat.avatars",true))line.Children.Add(new Border{Width=28,Height=28,CornerRadius=new CornerRadius(14),Child=new TextBlock{Text=author.Length>0?author.Substring(0,1).ToUpperInvariant():"",HorizontalAlignment=HorizontalAlignment.Center,VerticalAlignment=VerticalAlignment.Center}});
                line.Children.Add(content);Messages.Children.Add(line);
            }
            bool canSend=ready&&chat.GetNamedBoolean("canSend",false)&&Cfg.Get("chat.writable",true);
            ComposeArea.Visibility=ready&&(quickChat||widget.GameBarDisplayMode==XboxGameBarDisplayMode.Foreground)?Visibility.Visible:Visibility.Collapsed;
            var draft=drafts.For(token);
            Composer.IsReadOnly=quickChat;Composer.IsEnabled=canSend&&!draft.Pending&&!draft.Unknown;SendButton.IsEnabled=canSend&&!draft.Pending&&!draft.Unknown&&!quickChat&&OverlaySync.Writable;
            if(draft.Error!=null){Status.Text=draft.Error;Status.Visibility=Visibility.Visible;}
            var color=WidgetTheme.Color(WidgetTheme.Current.Background);color.A=(byte)(Cfg.Get("chat.bgOpacity",0.0)*255);Root.Background=new SolidColorBrush(color);
            double requestedWidth=Cfg.Get("chat.width",400.0),requestedHeight=Cfg.Get("chat.height",300.0);
            if(width!=requestedWidth||height!=requestedHeight){width=requestedWidth;height=requestedHeight;_=widget.TryResizeWindowAsync(new Windows.Foundation.Size(width,height));}
        }
        void ReconcileInput() {
            var chatSubmission=Chat?.GetNamedObject("submission",new JsonObject());
            if(chatSubmission!=null){
                string chatOperation=chatSubmission.GetNamedString("operationId",""),chatOutcome=chatSubmission.GetNamedString("status","");
                if(drafts.ReconcileReceipt(token,chatOperation,chatOutcome,Composer.Text)){quickChat=false;Composer.Text=drafts.For(token).Text;}
            }
            var inputState=OverlaySync.State?.GetNamedObject("input",new JsonObject());if(inputState==null)return;
            var submission=inputState.GetNamedObject("submission",new JsonObject());
            string owner=submission.GetNamedString("owner",""),operation=submission.GetNamedString("operationId",""),outcome=submission.GetNamedString("status","");
            string signature=owner+"/"+operation+"/"+outcome;
            if(owner==token&&operation.Length>0&&signature!=lastSubmission){
                lastSubmission=signature;var draft=drafts.For(owner);string text=submission.GetNamedString("text","");
                if(drafts.Reconcile(owner,text,operation,outcome,Composer.Text)){quickChat=false;Composer.Text=draft.Text;}
            }
            var compose=inputState.GetNamedObject("compose",new JsonObject());
            string composeSignature=compose.Stringify();
            if(composeSignature!=lastCompose){lastCompose=composeSignature;var draft=drafts.For(token);
                if(compose.GetNamedString("owner","")==token&&compose.GetNamedBoolean("active",false)&&!draft.Pending&&!draft.Unknown){quickChat=true;Composer.Text=compose.GetNamedString("text","");draft.Text=Composer.Text;}
                else quickChat=false;
            }
        }
        void Input(JsonObject e) {
            string type=e.GetNamedString("type","");
            string owner=e.GetNamedString("owner","");
            if(type=="sendResult") {
                string text=e.GetNamedString("text","");bool changed=drafts.Complete(owner,text,e.GetNamedString("operationId",""),e.GetNamedString("status","unknown"));
                if(changed&&drafts.SharesDraft(token,owner)){quickChat=false;Composer.Text=drafts.For(owner).Text;Render();}return;
            }
            if(owner.Length==0||owner!=token||Chat?.GetNamedString("status","")!="ready")return;
            var draft=drafts.For(owner);
            if(type=="compose"&&!draft.Unknown&&!draft.Pending){quickChat=true;Composer.Text=e.GetNamedString("text","");draft.Text=Composer.Text;Render();}
            else if(type=="submit"){drafts.Begin(owner,e.GetNamedString("text",draft.Text),e.GetNamedString("operationId",""));quickChat=false;Render();}
            else if(type=="cancel"){quickChat=false;Render();}
            else if(type=="blocked"){Status.Text=e.GetNamedString("text","");Status.Visibility=Visibility.Visible;}
        }
        static string Delivery(string value) {
            switch(value){case "committed":case "sent":return "Sent";case "delivered":return "Delivered";case "read":return "Read";case "pending":case "queued":return "Sending…";case "failedBeforeCommit":case "failed":return "Couldn’t send";case "unknown":return "Delivery unconfirmed";default:return "";}
        }
        async void SendNow() {
            var chat=Chat;var draft=drafts.For(token);if(draft.Pending||draft.Unknown||quickChat||chat==null||!chat.GetNamedBoolean("canSend",false)||!OverlaySync.Writable||string.IsNullOrWhiteSpace(Composer.Text))return;
            string text=Composer.Text,ownerToken=token,conversation=selected,operationId=Guid.NewGuid().ToString("N");
            if(!OverlaySync.TryRequestAsync("chat.send",OverlaySync.Args("token",ownerToken,"conversation",conversation,"text",text,"operationId",operationId),out var response))return;
            drafts.Begin(ownerToken,text,operationId);Render();
            var result=await response;
            var receipt=result?.GetNamedObject("result",new JsonObject()); string outcome=receipt?.GetNamedString("status","")??"";
            outcome=ChatDrafts.Outcome(true,result?.GetNamedBoolean("ok",false),outcome,result?.GetNamedString("error", ""));
            bool changed=drafts.Complete(ownerToken,text,operationId,outcome);
            if (changed && drafts.SharesDraft(token, ownerToken)) {
                Composer.Text = drafts.For(ownerToken).Text;
            }
            Render();
        }
        void Conversations_SelectionChanged(object sender,SelectionChangedEventArgs e) { if(!rendering&&Conversations.SelectedItem is Conversation option)OverlaySync.Request("chat.select",OverlaySync.Args("token",option.Id,"conversation",option.Id)); }
        async void Enable_Click(object sender,RoutedEventArgs e) { if(OverlaySync.Request("chat.enable",new JsonObject()))await Launcher.LaunchUriAsync(new Uri("doorlight://open")); }
        void Latest_Click(object sender,RoutedEventArgs e)=>OverlaySync.Request("chat.latest",OverlaySync.Args("token",token,"conversation",selected));
        void Older_Click(object sender,RoutedEventArgs e)=>OverlaySync.Request("chat.history",OverlaySync.Args("token",token,"conversation",selected));
        void Composer_KeyDown(object sender,KeyRoutedEventArgs e) {if(e.Key==VirtualKey.Enter){SendNow();e.Handled=true;}}
        void SendButton_Click(object sender,RoutedEventArgs e)=>SendNow();
    }
}
