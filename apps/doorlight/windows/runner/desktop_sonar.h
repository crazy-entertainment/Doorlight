#pragma once

#include <cstdint>
#include <windows.h>

namespace sybl::sonar {

constexpr unsigned int kDurationMs = 1250;
constexpr DWORD kWindowStyles = WS_EX_LAYERED | WS_EX_TRANSPARENT |
    WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE | WS_EX_TOPMOST;
bool IsValidReveal(double x, double y, std::uint32_t color) noexcept;

class DesktopSonar {
 public:
  DesktopSonar() = default;
  ~DesktopSonar();
  DesktopSonar(const DesktopSonar&) = delete;
  DesktopSonar& operator=(const DesktopSonar&) = delete;

  bool Reveal(HWND flutter_view, double x, double y,
              std::uint32_t color) noexcept;
  void Cancel() noexcept;
  static LRESULT CALLBACK WindowProc(HWND window, UINT message, WPARAM wp,
                                     LPARAM lp) noexcept;

 private:
  void Paint(HWND window) noexcept;
  void Tick() noexcept;

  HWND window_ = nullptr;
  HWND owner_ = nullptr;
  POINT center_{};
  COLORREF color_ = RGB(255, 255, 255);
  int radius_ = 700;
  ULONGLONG started_ = 0;
};

}  // namespace sybl::sonar
