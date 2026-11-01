#pragma once
#include <windows.h>
#include <functional>

// A single native surface: no Flutter engine, focus, hit testing, or history.
class HologramPopup {
 public:
  HologramPopup() = default;
  ~HologramPopup();
  HologramPopup(const HologramPopup&) = delete;
  HologramPopup& operator=(const HologramPopup&) = delete;
  static bool SessionAllows();
  static bool EnvironmentAllows(HWND main_window);
  bool Show(HWND main_window, bool reduced_motion, std::function<bool()> still_allowed);
  void Cancel();
 private:
  static LRESULT CALLBACK WindowProc(HWND window, UINT message, WPARAM wp, LPARAM lp);
  bool LoadPixels(int size);
  bool Protected() const;
  bool Draw(BYTE opacity);
  void Tick();
  HWND window_ = nullptr;
  HWND main_ = nullptr;
  HDC pixels_ = nullptr;
  HBITMAP bitmap_ = nullptr;
  HGDIOBJ old_bitmap_ = nullptr;
  POINT position_{};
  SIZE size_{};
  ULONGLONG started_ = 0;
  bool reduced_motion_ = false;
  bool sounding_ = false;
  std::function<bool()> still_allowed_;
};
