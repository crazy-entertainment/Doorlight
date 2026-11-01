#pragma once

#include <windows.h>
#include <cstdint>
#include <functional>
#include <mutex>
#include <thread>
#include <condition_variable>
#include <vector>

namespace sybl::window {

constexpr UINT kDismissDurationMs = 240;
constexpr UINT kDismissWatchdogMs = 350;
constexpr UINT_PTR kDismissWatchdog = 0x394;

// Shell UIA runs off the window thread. Only our executable's taskbar bounds
// cross the thread boundary; an unavailable/grouped button uses its monitor edge.
class TaskbarTarget {
 public:
  TaskbarTarget();
  ~TaskbarTarget();
  void Refresh();
  POINT ForWindow(HWND window);
 private:
  void Run();
  std::mutex mutex_;
  std::condition_variable wake_;
  bool stop_ = false;
  uint64_t requested_ = 1, completed_ = 0;
  std::vector<RECT> buttons_;
  std::thread worker_;
};

bool IsOverlappingForeignWindow(HWND owner, HWND other) noexcept;
bool IsCoveredByAnotherWindow(HWND owner) noexcept;

bool ValidDismissFrame(int width, int height, size_t bytes) noexcept;
RECT DismissBounds(RECT source, POINT target, double progress) noexcept;
enum class DismissStyle { kTray, kDoor, kWarp, kFade, kNone, kFoldRight, kFoldUp, kFoldDown };
inline bool IsFold(DismissStyle style) noexcept {
  return style == DismissStyle::kDoor || style == DismissStyle::kFoldRight ||
      style == DismissStyle::kFoldUp || style == DismissStyle::kFoldDown;
}

void ShapeDismissFrame(std::vector<uint32_t>& pixels, int width, int height,
    double radius, COLORREF border, double thickness) noexcept;
double FoldOutlineDistance(double along, double across, int axis, int cross_axis,
    double cosine, double sine) noexcept;

// A temporary per-pixel-alpha surface with confirmed source affinity before show.
// It owns only an in-memory Flutter frame, never a screen capture or disk file.
class WindowDismissEffect {
 public:
  ~WindowDismissEffect();
  bool PrepareRestore(HWND owner);
  bool Start(HWND owner, int width, int height,
             const std::vector<std::uint8_t>& rgba, POINT target, DismissStyle style,
             std::function<void(bool)> finish, bool restoring = false,
             UINT duration_ms = kDismissDurationMs, bool preview = false);
  void Reset() noexcept;
  bool active() const noexcept { return overlay_ != nullptr; }
  int failure() const noexcept { return failure_; }
  static LRESULT CALLBACK WindowProc(HWND hwnd, UINT message, WPARAM wp,
                                     LPARAM lp) noexcept;
 private:
  bool Paint(double progress, BYTE opacity = 255) noexcept;
  bool ConcealOwner() noexcept;
  void Tick() noexcept;
  void Finish(bool completed) noexcept;
  HWND owner_ = nullptr;
  HWND overlay_ = nullptr;
  HDC dc_ = nullptr;
  HBITMAP bitmap_ = nullptr;
  HGDIOBJ previous_ = nullptr;
  std::uint32_t* output_ = nullptr;
  std::vector<std::uint32_t> source_;
  RECT source_bounds_{};
  POINT target_{};
  int width_ = 0, height_ = 0;
  DismissStyle style_ = DismissStyle::kTray;
  COLORREF border_ = 0;
  double border_width_ = 1;
  bool cloaked_owner_ = false;
  bool transitions_changed_ = false;
  BOOL old_transitions_ = FALSE;
  UINT duration_ms_ = kDismissDurationMs;
  ULONGLONG started_ = 0;
  ULONGLONG endpoint_presented_ = 0;
  bool restoring_ = false;
  bool preview_round_trip_ = false;
  std::function<void(bool)> finish_;
  int failure_ = 0;
};

}  // namespace sybl::window
