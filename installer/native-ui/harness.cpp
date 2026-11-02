#define WIN32_LEAN_AND_MEAN
#include "doorlight_ui.h"
#include <filesystem>
#include <fstream>
#include <iterator>
#include <vector>
#include <windows.h>
struct Check {
    bool preview{}, controlsValid{};
    void *window{};
    int started{}, dispatched{}, timers{}, closing{}, destroyed{};
};
int __cdecl event(void *context, int kind, intptr_t argument) {
    auto c = (Check *)context;
    if (kind == DL_STARTED) {
        c->started++;
        if (c->preview) {
            dl_set_text(c->window, DL_STATUS, L"Ready when Doorlight is idle.");
            dl_progress(c->window, .95, 1);
            dl_timer(c->window, 100, 120000);
            return 0;
        }
        auto window = (HWND)dl_hwnd(c->window);
        auto label = GetDlgItem(window, DL_HEADING);
        auto button = GetDlgItem(window, DL_CANCEL_BUTTON);
        SendMessageW(button, BM_SETSTYLE, BS_DEFPUSHBUTTON, TRUE);
        RECT outer{}, client{}, cancel{};
        GetWindowRect(window, &outer);
        GetClientRect(window, &client);
        GetWindowRect(button, &cancel);
        POINT origin{};
        ClientToScreen(window, &origin);
        c->controlsValid = (GetWindowLongPtrW(label, GWL_STYLE) & SS_TYPEMASK) == SS_CENTER &&
                           (GetWindowLongPtrW(button, GWL_STYLE) & BS_TYPEMASK) == BS_OWNERDRAW &&
                           origin.y == outer.top && cancel.bottom <= origin.y + client.bottom;
        dl_set_text(c->window, DL_STATUS, L"Checking native presentation");
        dl_progress(c->window, .65, 1);
        dl_timer(c->window, 100, 60);
        dl_post(c->window, 12345);
    }
    if (kind == DL_DISPATCH && argument == 12345)
        c->dispatched++;
    if (kind == DL_TIMER && argument == 100) {
        c->timers++;
        dl_close(c->window);
    }
    if (kind == DL_CLOSE_REQUESTED) {
        c->closing++;
        return !c->preview && c->closing == 1 ? 1 : 0;
    }
    if (kind == DL_DESTROYED)
        c->destroyed++;
    return 0;
}
std::vector<char> read(const std::filesystem::path &name) {
    std::ifstream file(name, std::ios::binary);
    return {std::istreambuf_iterator<char>(file), {}};
}
int WINAPI wWinMain(HINSTANCE, HINSTANCE, PWSTR args, int) {
    SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    auto fonts = std::filesystem::path(__FILE__).parent_path().parent_path().parent_path() /
                 "apps/doorlight/assets/fonts";
    auto h = read(fonts / "HankenGrotesk-Variable.ttf");
    auto f = read(fonts / "Fraunces-Variable.ttf");
    Check c;
    c.preview = wcsstr(args, L"--preview") != nullptr;
    c.window = dl_create(event, &c, 1, h.data(), (int)h.size(), f.data(), (int)f.size());
    if (!c.window)
        return 2;
    h.clear();
    f.clear();
    dl_show(c.window, (c.preview || wcsstr(args, L"--visible")) ? SW_SHOW : SW_HIDE);
    int result = dl_run(c.window);
    dl_destroy(c.window);
    if (c.preview)
        return result;
    return result == 0 && c.controlsValid && c.started == 1 && c.dispatched == 1 && c.timers == 2 &&
                   c.closing == 2 && c.destroyed == 1
               ? 0
               : 3;
}
