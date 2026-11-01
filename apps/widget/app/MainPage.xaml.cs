using System;
using System.Text;
using System.Threading.Tasks;
using Windows.ApplicationModel;
using Windows.Storage;
using Windows.UI.Xaml;
using Windows.UI.Xaml.Controls;
using Windows.UI.Xaml.Controls.Primitives;
using Windows.UI.Xaml.Data;
using Windows.UI.Xaml.Input;
using Windows.UI.Xaml.Media;
using Windows.UI.Xaml.Navigation;

namespace WidgetSampleCS
{
    public sealed partial class MainPage : Page
    {
        public MainPage()
        {
            WidgetTheme.Attach(this); InitializeComponent();
        }
        async void OpenGameBar(object sender, RoutedEventArgs args)
        {
            try {
                bool opened = await Windows.System.Launcher.LaunchUriAsync(new Uri("ms-gamebar://launch/activate/" + Package.Current.Id.FamilyName + "_App_Helper"));
                Status.Text = opened ? "" : "Game Bar could not open. Check that Xbox Game Bar is installed, then press Win+G.";
            } catch (Exception) { Status.Text = "Game Bar could not open. Try Win+G."; }
        }
        async Task ShowFiles(params string[] files)
        {
            try {
                var text = new StringBuilder();
                foreach (var file in files) {
                    var asset = await StorageFile.GetFileFromApplicationUriAsync(new Uri("ms-appx:///" + file));
                    text.AppendLine(await FileIO.ReadTextAsync(asset)).AppendLine();
                }
                Details.Text = text.ToString();
            } catch (Exception) { Details.Text = "Could not open this notice. Close and reopen Doorlight Widget to retry."; }
        }
        async void ShowPrivacy(object sender, RoutedEventArgs args) => await ShowFiles("Assets/PRIVACY.txt");
        async void ShowLicenses(object sender, RoutedEventArgs args) => await ShowFiles("Assets/WEATHER-NOTICE.txt", "Notices/LICENSE-Microsoft.txt", "Assets/Flags/NOTICE.txt", "Assets/Flags/LICENSE.txt", "Assets/CountryCentres-NOTICE.txt", "Assets/Fonts/OFL-Fraunces.txt", "Assets/Fonts/OFL-HankenGrotesk.txt", "Companion/GAME-BAR-SDK-LICENSE.TXT", "Companion/LICENSE.TXT", "Companion/THIRD-PARTY-NOTICES.TXT");
    }
}
