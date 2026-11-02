#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
// Windows COM declarations must precede GDI+ headers.
#include <windows.h>
#include <windowsx.h>
#include <objidl.h>
#include <dwmapi.h>
#include <shellapi.h>
#include <gdiplus.h>
#include <algorithm>
#include <cmath>
#include <memory>
#include <string>
#include <vector>
#include "doorlight_ui.h"
using namespace Gdiplus;
namespace {
constexpr UINT DispatchMessageId = WM_APP + 41;
constexpr UINT StartedMessageId = WM_APP + 42;
const Color Background(255, 33, 23, 20), Ink(255, 244, 233, 223), Muted(255, 180, 157, 144),
    Amber(255, 242, 183, 117);
struct Window {
    HWND hwnd{};
    HWND controls[9]{};
    dl_callback callback{};
    void *context{};
    bool motion{}, active{}, started{};
    double fraction{};
    float phase{}, scale{1};
    ULONG_PTR gdiplus{};
    std::vector<BYTE> hanken, fraunces;
    std::unique_ptr<PrivateFontCollection> fonts;
    std::unique_ptr<FontFamily> body, display;
    HFONT accessibleFont{};
    WNDPROC staticProcedure{}, buttonProcedure{};
    int emit(int event, intptr_t arg = 0) {
        return callback ? callback(context, event, arg) : 0;
    }
};
std::wstring text(HWND control) {
    int length = GetWindowTextLengthW(control);
    std::wstring result(length + 1, L'\0');
    GetWindowTextW(control, result.data(), length + 1);
    result.resize(length);
    return result;
}
void layout(Window *w) {
    RECT client;
    GetClientRect(w->hwnd, &client);
    float s = w->scale;
    auto place = [&](int id, int x, int y, int width, int height) {
        MoveWindow(w->controls[id], int((client.right / s - 700) / 2 * s + x * s), int(y * s),
                   int(width * s), int(height * s), TRUE);
    };
    place(1, 52, 218, 596, 58);
    place(2, 52, 284, 596, 30);
    place(3, 70, 365, 560, 26);
    place(4, 267, 403, 166, 34);
    place(5, 560, 447, 108, 30);
    place(6, 292, 450, 116, 24);
    MoveWindow(w->controls[7], client.right - int(88 * s), 0, int(44 * s), int(34 * s), TRUE);
    MoveWindow(w->controls[8], client.right - int(44 * s), 0, int(44 * s), int(34 * s), TRUE);
    if (w->accessibleFont)
        DeleteObject(w->accessibleFont);
    w->accessibleFont = CreateFontW(-int(13.333 * s), 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE,
                                    DEFAULT_CHARSET, 0, 0, CLEARTYPE_QUALITY, 0, L"Hanken Grotesk");
    for (int i = 1; i <= 8; i++)
        SendMessageW(w->controls[i], WM_SETFONT, (WPARAM)w->accessibleFont, TRUE);
    InvalidateRect(w->hwnd, nullptr, FALSE);
}
void door(Graphics &g, Window *w, int width) {
    auto saved = g.Save();
    g.TranslateTransform((width / w->scale - 700) / 2 * w->scale + 170 * w->scale, 68 * w->scale);
    g.ScaleTransform(w->scale, w->scale);
    g.SetSmoothingMode(SmoothingModeAntiAlias);
    float f = (float)w->fraction;
    float opening =
        std::clamp(f + (w->active && w->motion ? .025f * std::sin(w->phase) : 0), 0.f, 1.f);
    float left = 145, right = 215 - 67 * opening;
    PointF spillPoints[] = {{145, 126}, {215, 126}, {242, 158}, {117, 158}};
    GraphicsPath spill;
    spill.AddPolygon(spillPoints, 4);
    PathGradientBrush glow(&spill);
    glow.SetCenterColor(Color(BYTE(35 + 80 * f), 242, 183, 117));
    Color clear(0, 242, 183, 117);
    int count = 1;
    glow.SetSurroundColors(&clear, &count);
    g.FillPath(&glow, &spill);
    Pen pen(Amber, 3);
    pen.SetLineJoin(LineJoinRound);
    pen.SetStartCap(LineCapRound);
    pen.SetEndCap(LineCapRound);
    SolidBrush background(Background), light(Color(BYTE(25 + 85 * f), 242, 183, 117)), amber(Amber);
    g.FillRectangle(&light, left, 24.f, 70.f, 102.f);
    g.DrawRectangle(&pen, left, 24.f, 70.f, 102.f);
    PointF leaf[] = {
        {left, 24}, {right, 24 - 12 * opening}, {right, 126 + 15 * opening}, {left, 126}};
    g.FillPolygon(&background, leaf, 4);
    g.DrawPolygon(&pen, leaf, 4);
    g.FillEllipse(&amber, left + (right - left) * .85f - 2, 71 + opening * 2, 4.f, 4.f);
    Pen track(Color(255, 66, 44, 38), 4);
    track.SetStartCap(LineCapRound);
    track.SetEndCap(LineCapRound);
    g.DrawLine(&track, 0.f, 254.f, 332.f, 254.f);
    float end = 332 * f;
    GraphicsPath wave;
    auto y = [&](float x) {
        return 254 + (w->active && w->motion ? std::sin(x / 9 - w->phase * 3) * 3 : 0);
    };
    for (float x = 0; x < end; x += 2)
        wave.AddLine(x, y(x), std::min(x + 2, end), y(x + 2));
    if (end > 0)
        g.DrawPath(&pen, &wave);
    if (w->active)
        g.DrawArc(&pen, 344.f, 247.f, 14.f, 14.f, w->motion ? w->phase * 150 : -90, 250);
    g.Restore(saved);
}
void drawControl(Window *w, DRAWITEMSTRUCT *item) {
    Graphics g(item->hDC);
    int id = (int)item->CtlID;
    // Antialiased rectangle fills leave half-covered edge pixels on the control's white DC.
    g.Clear(id == 4 ? Amber : Background);
    g.SetSmoothingMode(SmoothingModeAntiAlias);
    g.SetTextRenderingHint(TextRenderingHintAntiAliasGridFit);
    RectF area(0, 0, float(item->rcItem.right), float(item->rcItem.bottom));
    if (id >= 7) {
        Pen pen(Muted, w->scale);
        float x = area.Width / 2, y = area.Height / 2, r = 3 * w->scale;
        if (id == 8) {
            g.DrawLine(&pen, x - r, y - r, x + r, y + r);
            g.DrawLine(&pen, x - r, y + r, x + r, y - r);
        } else
            g.DrawLine(&pen, x - r, y, x + r, y);
        return;
    }
    Font font(id == 1 ? w->display.get() : w->body.get(),
              (id == 1   ? 28.f
               : id == 3 ? 9.f
                         : 10.f) *
                  96 / 72 * w->scale,
              id == 6 ? FontStyleUnderline : FontStyleRegular, UnitPixel);
    Color color = id == 4 ? Background : id == 1 || id == 2 ? Ink : Muted;
    if (!(item->itemState & ODS_DISABLED) && id == 4 && (item->itemState & ODS_SELECTED)) {
        SolidBrush pressed(Color(255, 218, 161, 101));
        g.FillRectangle(&pressed, area);
    }
    SolidBrush foreground(color);
    StringFormat format;
    format.SetAlignment(StringAlignmentCenter);
    format.SetLineAlignment(StringAlignmentCenter);
    format.SetTrimming(StringTrimmingEllipsisCharacter);
    format.SetFormatFlags(StringFormatFlagsNoWrap);
    auto value = text(item->hwndItem);
    g.DrawString(value.c_str(), (int)value.size(), &font, area, &format, &foreground);
    if (id == 5) {
        Pen border(Muted, w->scale);
        g.DrawRectangle(&border, .5f * w->scale, .5f * w->scale, area.Width - w->scale,
                        area.Height - w->scale);
    }
    if (id >= 4 && GetFocus() == item->hwndItem && (item->itemState & ODS_FOCUS)) {
        RECT focus = item->rcItem;
        InflateRect(&focus, -3, -3);
        DrawFocusRect(item->hDC, &focus);
    }
}
// Retain standard text/button accessibility and keyboard behavior while owning paint.
LRESULT CALLBACK controlProcedure(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    auto w = reinterpret_cast<Window *>(GetWindowLongPtrW(GetParent(hwnd), GWLP_USERDATA));
    if (!w)
        return DefWindowProcW(hwnd, msg, wp, lp);
    int id = GetDlgCtrlID(hwnd);
    auto original = id < 4 ? w->staticProcedure : w->buttonProcedure;
    if (id < 4 && msg == WM_PAINT) {
        PAINTSTRUCT paint;
        DRAWITEMSTRUCT item{};
        item.hDC = BeginPaint(hwnd, &paint);
        item.hwndItem = hwnd;
        item.CtlID = id;
        GetClientRect(hwnd, &item.rcItem);
        drawControl(w, &item);
        EndPaint(hwnd, &paint);
        return 0;
    }
    if (id < 4 && msg == WM_ERASEBKGND)
        return 1;
    // IsDialogMessage toggles default-button styles as focus moves. Keep owner draw.
    if (id >= 4 && msg == BM_SETSTYLE)
        wp = (wp & ~BS_TYPEMASK) | BS_OWNERDRAW;
    return CallWindowProcW(original, hwnd, msg, wp, lp);
}
LRESULT CALLBACK procedure(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    auto w = reinterpret_cast<Window *>(GetWindowLongPtrW(hwnd, GWLP_USERDATA));
    if (msg == WM_NCCREATE) {
        w = static_cast<Window *>(reinterpret_cast<CREATESTRUCTW *>(lp)->lpCreateParams);
        w->hwnd = hwnd;
        SetWindowLongPtrW(hwnd, GWLP_USERDATA, (LONG_PTR)w);
    }
    if (!w)
        return DefWindowProcW(hwnd, msg, wp, lp);
    switch (msg) {
    case WM_NCCALCSIZE: {
        auto area = wp ? &((NCCALCSIZE_PARAMS *)lp)->rgrc[0] : (RECT *)lp;
        LONG top = area->top;
        DefWindowProcW(hwnd, msg, wp, lp);
        area->top = top;
        return 0;
    }
    case WM_NCHITTEST: {
        auto hit = DefWindowProcW(hwnd, msg, wp, lp);
        if (hit != HTCLIENT)
            return hit;
        POINT p{GET_X_LPARAM(lp), GET_Y_LPARAM(lp)};
        ScreenToClient(hwnd, &p);
        RECT r;
        GetClientRect(hwnd, &r);
        if (p.y >= 0 && p.y < 34 * w->scale && p.x < r.right - 88 * w->scale)
            return HTCAPTION;
        return hit;
    }
    case WM_GETMINMAXINFO: {
        auto info = (MINMAXINFO *)lp;
        info->ptMinTrackSize = {LONG(480 * w->scale), LONG(420 * w->scale)};
        return 0;
    }
    case WM_SIZE:
        if (w->controls[1])
            layout(w);
        return 0;
    case WM_DPICHANGED: {
        w->scale = HIWORD(wp) / 96.f;
        auto r = (RECT *)lp;
        SetWindowPos(hwnd, nullptr, r->left, r->top, r->right - r->left, r->bottom - r->top,
                     SWP_NOZORDER | SWP_NOACTIVATE);
        layout(w);
        return 0;
    }
    case WM_ERASEBKGND:
        return 1;
    case WM_PAINT: {
        PAINTSTRUCT ps;
        HDC dc = BeginPaint(hwnd, &ps);
        RECT r;
        GetClientRect(hwnd, &r);
        if (r.right > 0 && r.bottom > 0) {
            Bitmap buffer(r.right, r.bottom);
            Graphics g(&buffer);
            g.Clear(Background);
            door(g, w, r.right);
            Graphics screen(dc);
            screen.DrawImage(&buffer, 0, 0);
        }
        EndPaint(hwnd, &ps);
        return 0;
    }
    case WM_DRAWITEM:
        drawControl(w, (DRAWITEMSTRUCT *)lp);
        return TRUE;
    case WM_COMMAND:
        if (HIWORD(wp) == BN_CLICKED) {
            int id = LOWORD(wp);
            if (id == IDOK)
                id = GetDlgCtrlID(GetFocus());
            switch (id) {
            case 4:
                w->emit(DL_ACTION);
                break;
            case 5:
                w->emit(DL_CANCEL);
                break;
            case 6:
                w->emit(DL_LICENSES);
                break;
            case 7:
                ShowWindow(hwnd, SW_MINIMIZE);
                break;
            case 8:
                SendMessageW(hwnd, WM_CLOSE, 0, 0);
                break;
            case IDCANCEL:
                SendMessageW(hwnd, WM_CLOSE, 0, 0);
                break;
            }
        }
        return 0;
    case WM_TIMER:
        if (wp == 1) {
            if (w->active && w->motion) {
                w->phase += .06f;
                InvalidateRect(hwnd, nullptr, FALSE);
            }
        } else if (wp >= 100)
            w->emit(DL_TIMER, (intptr_t)wp);
        return 0;
    case StartedMessageId:
        if (!w->started) {
            w->started = true;
            w->emit(DL_STARTED);
        }
        return 0;
    case DispatchMessageId:
        w->emit(DL_DISPATCH, (intptr_t)wp);
        return 0;
    case WM_CLOSE:
        if (!w->emit(DL_CLOSE_REQUESTED))
            DestroyWindow(hwnd);
        return 0;
    case WM_DESTROY:
        KillTimer(hwnd, 1);
        w->emit(DL_DESTROYED);
        PostQuitMessage(0);
        return 0;
    case WM_NCDESTROY:
        SetWindowLongPtrW(hwnd, GWLP_USERDATA, 0);
        w->hwnd = nullptr;
        return DefWindowProcW(hwnd, msg, wp, lp);
    }
    return DefWindowProcW(hwnd, msg, wp, lp);
}
} // namespace
extern "C" {
void *dl_create(dl_callback callback, void *context, int motion, const void *hanken,
                int hankenLength, const void *fraunces, int frauncesLength) {
    if (!hanken || !fraunces || hankenLength <= 0 || frauncesLength <= 0)
        return nullptr;
    auto w = std::make_unique<Window>();
    w->callback = callback;
    w->context = context;
    w->motion = motion != 0;
    GdiplusStartupInput startup;
    if (GdiplusStartup(&w->gdiplus, &startup, nullptr) != Ok)
        return nullptr;
    w->hanken.assign((const BYTE *)hanken, (const BYTE *)hanken + hankenLength);
    w->fraunces.assign((const BYTE *)fraunces, (const BYTE *)fraunces + frauncesLength);
    w->fonts = std::make_unique<PrivateFontCollection>();
    if (w->fonts->AddMemoryFont(w->hanken.data(), hankenLength) != Ok ||
        w->fonts->AddMemoryFont(w->fraunces.data(), frauncesLength) != Ok) {
        dl_destroy(w.release());
        return nullptr;
    }
    {
        int count = w->fonts->GetFamilyCount();
        auto families = std::make_unique<FontFamily[]>(count);
        int found = 0;
        w->fonts->GetFamilies(count, families.get(), &found);
        for (int i = 0; i < found; i++) {
            WCHAR name[LF_FACESIZE];
            families[i].GetFamilyName(name);
            if (!w->body && wcsstr(name, L"Hanken"))
                w->body.reset(families[i].Clone());
            if (!w->display && wcsstr(name, L"Fraunces"))
                w->display.reset(families[i].Clone());
        }
    }
    if (!w->body || !w->display) {
        dl_destroy(w.release());
        return nullptr;
    }
    auto instance = GetModuleHandleW(nullptr);
    WNDCLASSEXW wc{sizeof(wc)};
    wc.lpfnWndProc = procedure;
    wc.hInstance = instance;
    wc.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    wc.lpszClassName = L"DoorlightSetup.Native.v1";
    WNDCLASSEXW existing{sizeof(existing)};
    if (!GetClassInfoExW(instance, wc.lpszClassName, &existing)) {
        wchar_t path[32768];
        GetModuleFileNameW(nullptr, path, 32768);
        wc.hIcon = ExtractIconW(instance, path, 0);
        if (wc.hIcon == (HICON)1)
            wc.hIcon = nullptr;
        if (!RegisterClassExW(&wc)) {
            if (wc.hIcon)
                DestroyIcon(wc.hIcon);
            dl_destroy(w.release());
            return nullptr;
        }
    }
    if (!CreateWindowExW(WS_EX_CONTROLPARENT, wc.lpszClassName, L"Doorlight",
                         (WS_OVERLAPPEDWINDOW & ~WS_MAXIMIZEBOX) | WS_CLIPCHILDREN, CW_USEDEFAULT,
                         CW_USEDEFAULT, 700, 500, nullptr, nullptr, instance, w.get())) {
        dl_destroy(w.release());
        return nullptr;
    }
    w->scale = GetDpiForWindow(w->hwnd) / 96.f;
    const wchar_t *labels[] = {L"",       L"Doorlight", L"",         L"",     L"Try again",
                               L"Cancel", L"Licenses",  L"Minimize", L"Close"};
    for (int i = 1; i <= 8; i++) {
        w->controls[i] =
            CreateWindowExW(0, i < 4 ? L"STATIC" : L"BUTTON", labels[i],
                            WS_CHILD | WS_VISIBLE | (i < 4 ? SS_CENTER : BS_OWNERDRAW | WS_TABSTOP),
                            0, 0, 0, 0, w->hwnd, (HMENU)(INT_PTR)i, instance, nullptr);
        auto original =
            (WNDPROC)SetWindowLongPtrW(w->controls[i], GWLP_WNDPROC, (LONG_PTR)controlProcedure);
        if (i < 4)
            w->staticProcedure = original;
        else
            w->buttonProcedure = original;
    }
    ShowWindow(w->controls[4], SW_HIDE);
    int rounded = 2, border = -2;
    DwmSetWindowAttribute(w->hwnd, 33, &rounded, 4);
    DwmSetWindowAttribute(w->hwnd, 34, &border, 4);
    RECT work{}, outer{}, visible{};
    SystemParametersInfoW(SPI_GETWORKAREA, 0, &work, 0);
    GetWindowRect(w->hwnd, &outer);
    if (FAILED(
            DwmGetWindowAttribute(w->hwnd, DWMWA_EXTENDED_FRAME_BOUNDS, &visible, sizeof(visible))))
        visible = outer;
    int gap = int(8 * w->scale),
        width = std::min(int(700 * w->scale), int(work.right - work.left - gap * 2)),
        height = std::min(int(500 * w->scale), int(work.bottom - work.top - gap * 2));
    SetWindowPos(w->hwnd, nullptr, work.right - gap - width + outer.right - visible.right,
                 work.bottom - gap - height + outer.bottom - visible.bottom, width, height,
                 SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED);
    layout(w.get());
    SetTimer(w->hwnd, 1, 30, nullptr);
    PostMessageW(w->hwnd, StartedMessageId, 0, 0);
    return w.release();
}
void *dl_hwnd(void *ptr) {
    return ((Window *)ptr)->hwnd;
}
void dl_show(void *ptr, int command) {
    ShowWindow(((Window *)ptr)->hwnd, command);
}
int dl_run(void *ptr) {
    auto w = (Window *)ptr;
    MSG msg;
    int result;
    while ((result = GetMessageW(&msg, nullptr, 0, 0)) > 0) {
        if (!w->hwnd || !IsDialogMessageW(w->hwnd, &msg)) {
            TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
    }
    return result < 0 ? -1 : (int)msg.wParam;
}
void dl_destroy(void *ptr) {
    if (!ptr)
        return;
    auto w = (Window *)ptr;
    if (w->hwnd)
        DestroyWindow(w->hwnd);
    if (w->accessibleFont)
        DeleteObject(w->accessibleFont);
    w->body.reset();
    w->display.reset();
    w->fonts.reset();
    if (w->gdiplus)
        GdiplusShutdown(w->gdiplus);
    delete w;
}
void dl_set_text(void *ptr, int slot, const wchar_t *value) {
    auto w = (Window *)ptr;
    if (slot >= 1 && slot <= 5) {
        SetWindowTextW(w->controls[slot], value ? value : L"");
        InvalidateRect(w->controls[slot], nullptr, FALSE);
    }
}
void dl_set_button(void *ptr, int slot, int visible, int enabled) {
    auto w = (Window *)ptr;
    if (slot == 4 || slot == 5) {
        ShowWindow(w->controls[slot], visible ? SW_SHOW : SW_HIDE);
        EnableWindow(w->controls[slot], enabled);
    }
}
void dl_progress(void *ptr, double fraction, int active) {
    auto w = (Window *)ptr;
    w->fraction = std::isfinite(fraction) ? std::clamp(fraction, 0., 1.) : 0;
    w->active = active != 0;
    InvalidateRect(w->hwnd, nullptr, FALSE);
}
int dl_post(void *ptr, uint64_t token) {
    return PostMessageW(((Window *)ptr)->hwnd, DispatchMessageId, (WPARAM)token, 0) != FALSE;
}
void dl_timer(void *ptr, uint32_t id, uint32_t interval) {
    if (id >= 100 && interval)
        SetTimer(((Window *)ptr)->hwnd, id, interval, nullptr);
}
void dl_stop_timer(void *ptr, uint32_t id) {
    if (id >= 100)
        KillTimer(((Window *)ptr)->hwnd, id);
}
void dl_close(void *ptr) {
    SendMessageW(((Window *)ptr)->hwnd, WM_CLOSE, 0, 0);
}
}
