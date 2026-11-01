#pragma once

#include <cstdint>
#include <string>
#include <utility>
#include <vector>

#include <windows.h>

namespace sybl::annotation {

constexpr std::size_t kMaxStrokes = 160;
constexpr std::size_t kMaxPoints = 24000;

struct Point {
  double x = 0;
  double y = 0;
};

struct Stroke {
  std::uint32_t argb = 0;
  double width = 0;
  std::vector<Point> points;
};

struct Snapshot {
  std::string call_id;
  std::uint64_t source_revision = 0;
  std::vector<Stroke> strokes;
};

struct Surface {
  int left = 0;
  int top = 0;
  int width = 0;
  int height = 0;
};

bool IsValid(const Snapshot& snapshot, const Surface& surface) noexcept;
std::pair<int, int> ProjectPoint(const Point& point,
                                 const Surface& surface) noexcept;

// A nonactivating, click-through, topmost projection of the locally owned
// shared-screen board. It intentionally remains part of desktop composition so
// the screen encoder and the physical host both see the same marks.
class Overlay {
 public:
  Overlay() = default;
  ~Overlay();

  Overlay(const Overlay&) = delete;
  Overlay& operator=(const Overlay&) = delete;

  bool Update(Snapshot snapshot, const Surface& surface) noexcept;
  void Clear() noexcept;
  void Shutdown() noexcept;

  bool visible() const noexcept;
  static LRESULT CALLBACK WndProc(HWND window, UINT message, WPARAM wparam,
                                  LPARAM lparam) noexcept;

 private:
  bool EnsureWindow() noexcept;
  void Paint(HWND window) noexcept;

  HWND window_ = nullptr;
  Snapshot snapshot_;
  Surface surface_;
};

}  // namespace sybl::annotation
