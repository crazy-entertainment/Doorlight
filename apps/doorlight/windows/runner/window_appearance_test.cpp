#include "win32_window.h"
#include <dwmapi.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <initializer_list>
#include <stdexcept>

namespace {
constexpr DWORD kBorderAttribute = 34;
constexpr COLORREF kNoBorder = 0xFFFFFFFE;
void Require(bool condition, const char* message) {
  if (!condition) throw std::runtime_error(message);
}

// Patches only this test executable's import; never dwmapi or another process.
// Requests are observed without forwarding them to the compositor.
class ScopedDwmObserver {
 public:
  ScopedDwmObserver() : slot_(FindImport()) {
    Require(active_ == nullptr, "nested DWM observer");
    previous_ = Replace(reinterpret_cast<void*>(&Dispatch));
    active_ = this;
  }
  ~ScopedDwmObserver() {
    // Also restores the import when a test assertion throws.
    if (Replace(previous_) != reinterpret_cast<void*>(&Dispatch)) std::abort();
    active_ = nullptr;
  }
  ScopedDwmObserver(const ScopedDwmObserver&) = delete;
  ScopedDwmObserver& operator=(const ScopedDwmObserver&) = delete;
  unsigned border_calls = 0;
  HWND last_window = nullptr;
  COLORREF last_color = 0;
  bool invalid_arguments = false;
 private:
  static void** FindImport() {
    auto* base = reinterpret_cast<unsigned char*>(GetModuleHandleW(nullptr));
    Require(base != nullptr, "missing test module");
    const auto* dos = reinterpret_cast<const IMAGE_DOS_HEADER*>(base);
    Require(dos->e_magic == IMAGE_DOS_SIGNATURE, "invalid DOS header");
    const auto* nt = reinterpret_cast<const IMAGE_NT_HEADERS*>(base + dos->e_lfanew);
    Require(nt->Signature == IMAGE_NT_SIGNATURE, "invalid PE header");
    const auto directory = nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT];
    Require(directory.VirtualAddress != 0 && directory.Size != 0, "no imports");
    auto* descriptor = reinterpret_cast<IMAGE_IMPORT_DESCRIPTOR*>(base + directory.VirtualAddress);
    for (; descriptor->Name; ++descriptor) {
      if (_stricmp(reinterpret_cast<const char*>(base + descriptor->Name), "dwmapi.dll") != 0)
        continue;
      Require(descriptor->OriginalFirstThunk != 0, "DWM import has no names");
      auto* names = reinterpret_cast<IMAGE_THUNK_DATA*>(base + descriptor->OriginalFirstThunk);
      auto* addresses = reinterpret_cast<IMAGE_THUNK_DATA*>(base + descriptor->FirstThunk);
      for (; names->u1.AddressOfData; ++names, ++addresses) {
        if (IMAGE_SNAP_BY_ORDINAL(names->u1.Ordinal)) continue;
        const auto* named = reinterpret_cast<const IMAGE_IMPORT_BY_NAME*>(base + names->u1.AddressOfData);
        if (std::strcmp(reinterpret_cast<const char*>(named->Name), "DwmSetWindowAttribute") == 0)
          return reinterpret_cast<void**>(&addresses->u1.Function);
      }
    }
    throw std::runtime_error("DwmSetWindowAttribute import missing");
  }
  void* Replace(void* replacement) noexcept {
    DWORD protection = 0;
    if (!VirtualProtect(slot_, sizeof(*slot_), PAGE_READWRITE, &protection)) std::abort();
    void* previous = InterlockedExchangePointer(
        reinterpret_cast<PVOID volatile*>(slot_), replacement);
    DWORD ignored = 0;
    if (!VirtualProtect(slot_, sizeof(*slot_), protection, &ignored)) std::abort();
    return previous;
  }
  static HRESULT WINAPI Dispatch(HWND window, DWORD attribute, LPCVOID value, DWORD size) noexcept {
    if (!active_) return E_UNEXPECTED;
    if (attribute == kBorderAttribute) {
      ++active_->border_calls;
      active_->last_window = window;
      if (!value || size != sizeof(COLORREF)) {
        active_->invalid_arguments = true;
        return E_INVALIDARG;
      }
      std::memcpy(&active_->last_color, value, sizeof(COLORREF));
    }
    return S_OK;
  }
  void** slot_ = nullptr;
  void* previous_ = nullptr;
  inline static ScopedDwmObserver* active_ = nullptr;
};
}  // namespace

int main() {
  try {
    ScopedDwmObserver observer;
    Win32Window window;
    Require(window.Create(L"Doorlight disposable appearance test", {0, 0}, {700, 500}),
            "hidden window creation failed");
    const HWND hwnd = window.GetHandle();
    const auto check = [&](unsigned previous_calls, COLORREF expected) {
      Require(observer.border_calls > previous_calls, "border request missing");
      Require(!observer.invalid_arguments, "invalid border request arguments");
      Require(observer.last_window == hwnd, "border targeted the wrong window");
      Require(observer.last_color == expected, "wrong border color");
      Require(!IsWindowVisible(hwnd), "test window became visible");
    };
    check(0, kNoBorder);
    for (bool enabled : {true, false, true, false}) {
      auto before = observer.border_calls;
      Require(SendMessageW(hwnd, Win32Window::kAppearanceMessage, enabled ? 1 : 0, 0) != 0,
              "appearance command failed");
      const COLORREF expected = enabled ? RGB(64, 64, 69) : kNoBorder;
      check(before, expected);
      for (const UINT message : {WM_DWMCOLORIZATIONCOLORCHANGED, WM_THEMECHANGED}) {
        before = observer.border_calls;
        SendMessageW(hwnd, message, 0, 0);
        check(before, expected);
      }
    }
    window.Destroy();
    const auto before = observer.border_calls;
    Require(!Win32Window::SetDisaccordBorder(hwnd, true), "destroyed window accepted");
    Require(!Win32Window::SetDisaccordBorder(nullptr, true), "null window accepted");
    Require(observer.border_calls == before, "invalid window requested a border");
  } catch (const std::exception& error) {
    std::fprintf(stderr, "window_appearance_test: %s\n", error.what());
    return 1;
  }
  std::puts("Window border requests follow appearance and survive OS theme changes.");
  return 0;
}
