using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;

namespace Windows.UI {
    struct Color { public static Color FromArgb(byte a,byte r,byte g,byte b)=>new Color(); }
}
namespace Windows.UI.Core {
    enum CoreDispatcherPriority { Normal }
    sealed class CoreDispatcher {
        readonly int owner=Environment.CurrentManagedThreadId;
        public Task RunAsync(CoreDispatcherPriority priority,Action action){if(owner!=Environment.CurrentManagedThreadId)throw new InvalidOperationException("Wrong dispatcher");action();return Task.CompletedTask;}
    }
}
namespace Windows.UI.Xaml.Media {
    sealed class FontFamily {
        static readonly List<FontFamily> objects=new();
        public readonly string Source;
        readonly int owner=Environment.CurrentManagedThreadId;
        bool released;
        public FontFamily(string source){Source=source;lock(objects)objects.Add(this);}
        public void Validate(){if(released)throw new InvalidOperationException("Released view RCW");if(owner!=Environment.CurrentManagedThreadId)throw new InvalidOperationException("Foreign UI apartment");}
        public static void ReleaseView(){lock(objects)foreach(var font in objects.Where(value=>value.owner==Environment.CurrentManagedThreadId))font.released=true;}
    }
    sealed class SolidColorBrush {
        readonly int owner=Environment.CurrentManagedThreadId;
        Windows.UI.Color color;
        public SolidColorBrush(Windows.UI.Color value){color=value;}
        public Windows.UI.Color Color{get=>color;set{Validate();color=value;}}
        public void Validate(){if(owner!=Environment.CurrentManagedThreadId)throw new InvalidOperationException("Foreign brush apartment");}
    }
}
namespace Windows.UI.Xaml {
    sealed class Window {
        [ThreadStatic]static Window current;
        public static Window Current=>current??=new Window();
        public event EventHandler<object> Closed;
        public void Close(){Closed?.Invoke(this,null);Windows.UI.Xaml.Media.FontFamily.ReleaseView();}
    }
}
namespace Windows.UI.Xaml.Controls {
    sealed class Page {
        Windows.UI.Xaml.Media.FontFamily font;
        public readonly Dictionary<string,object> Resources=new();
        public readonly Windows.UI.Core.CoreDispatcher Dispatcher=new();
        public Windows.UI.Xaml.Media.FontFamily FontFamily{get=>font;set{value.Validate();font=value;}}
    }
}
namespace WidgetSampleCS {
    static class Cfg {
        [ThreadStatic]public static string Theme;
        public static event Action<string> Changed;
        public static int Subscribers=>Changed?.GetInvocationList().Length??0;
        public static T Get<T>(string key,T fallback)=>key=="helper.theme"?(T)(object)(Theme??"cozy"):fallback;
        public static Windows.UI.Color? Parse(string value)=>Windows.UI.Color.FromArgb(255,0,0,0);
        public static void Refresh()=>Changed?.Invoke("helper.appearance");
    }
    static class Program {
        static int checks;
        static void Check(bool condition,string description){if(!condition)throw new Exception(description);checks++;}
        static void View(string theme){
            Exception failure=null;
            var thread=new Thread(()=>{try{
                Cfg.Theme=theme;
                var first=new Windows.UI.Xaml.Controls.Page();WidgetTheme.Attach(first);
                var second=new Windows.UI.Xaml.Controls.Page();WidgetTheme.Attach(second);
                Check(first.FontFamily.Source==second.FontFamily.Source,"New pages must keep the same sans font design");
                WidgetTheme.Heading.Validate();
                Check(WidgetTheme.Heading.Source.Contains(theme=="disaccord"?"Hanken":"Fraunces"),"Heading appearance must remain unchanged");
                var firstBrush=first.Resources["WidgetBackground"];var secondBrush=second.Resources["WidgetBackground"];
                Check(!ReferenceEquals(firstBrush,secondBrush),"Mutable brushes must remain page-owned");
                Cfg.Refresh();
                first.FontFamily.Validate();second.FontFamily.Validate();
                ((Windows.UI.Xaml.Media.SolidColorBrush)firstBrush).Validate();
                Check(ReferenceEquals(first.Resources["WidgetBackground"],firstBrush),"Theme updates may reuse only their own view's brush");
                Windows.UI.Xaml.Window.Current.Close();
                Check(Cfg.Subscribers==0,"Closing a view must detach theme listeners");
            }catch(Exception error){failure=error;}});
            thread.Start();thread.Join();if(failure!=null)throw failure;
        }
        static void Main(){View("disaccord");View("disaccord");View("cozy");Console.WriteLine(checks+" actual WidgetTheme apartment/font/brush/lifecycle checks passed");}
    }
}
