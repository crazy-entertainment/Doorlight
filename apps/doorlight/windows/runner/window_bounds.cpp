#include "window_bounds.h"

#include <algorithm>
#include <cstdint>
#include <limits>

namespace sybl::window {
namespace {

// Guards against a corrupt or hostile stored value producing an absurd window.
constexpr int kMaxDimension = 32000;

std::int64_t OverlapArea(const Bounds& bounds, const WorkArea& area) {
  const std::int64_t left = std::max<std::int64_t>(bounds.x, area.left);
  const std::int64_t top = std::max<std::int64_t>(bounds.y, area.top);
  const std::int64_t right =
      std::min<std::int64_t>(static_cast<std::int64_t>(bounds.x) + bounds.width,
                             area.right);
  const std::int64_t bottom =
      std::min<std::int64_t>(static_cast<std::int64_t>(bounds.y) + bounds.height,
                             area.bottom);
  if (right <= left || bottom <= top) return 0;
  return (right - left) * (bottom - top);
}

bool ValidArea(const WorkArea& area) {
  return area.right > area.left && area.bottom > area.top;
}

}  // namespace

Bounds ChooseDefaultBounds(const WorkArea& area, int width, int height,
                           const FrameInsets& frame, int gap) {
  const int left = std::max(0, frame.left);
  const int top = std::max(0, frame.top);
  const int right = std::max(0, frame.right);
  const int bottom = std::max(0, frame.bottom);
  gap = std::clamp(gap, 0, (std::min(area.right - area.left,
                                   area.bottom - area.top) - 1) / 2);
  width = std::min(width, area.right - area.left - 2 * gap + left + right);
  height = std::min(height, area.bottom - area.top - 2 * gap + top + bottom);
  return {area.right - gap - width + right, area.bottom - gap - height + bottom,
          width, height, false};
}

std::optional<Bounds> ChooseRestoreBounds(const Bounds& saved,
                                          const std::vector<WorkArea>& work_areas,
                                          int min_width,
                                          int min_height) {
  if (min_width <= 0 || min_height <= 0) return std::nullopt;
  if (saved.width < min_width || saved.height < min_height) return std::nullopt;
  if (saved.width > kMaxDimension || saved.height > kMaxDimension)
    return std::nullopt;

  const WorkArea* best = nullptr;
  std::int64_t best_overlap = 0;
  for (const auto& area : work_areas) {
    if (!ValidArea(area)) continue;
    const auto overlap = OverlapArea(saved, area);
    if (overlap > best_overlap) {
      best_overlap = overlap;
      best = &area;
    }
  }
  // No surviving monitor shows any part of the saved rectangle. Restoring it
  // would put the window somewhere the user cannot reach it, so the caller's
  // default placement is the safer answer.
  if (!best) return std::nullopt;

  const int area_width = best->right - best->left;
  const int area_height = best->bottom - best->top;
  if (area_width < min_width || area_height < min_height) return std::nullopt;

  Bounds restored = saved;
  restored.width = std::min(saved.width, area_width);
  restored.height = std::min(saved.height, area_height);
  restored.x = std::clamp(saved.x, best->left, best->right - restored.width);
  restored.y = std::clamp(saved.y, best->top, best->bottom - restored.height);
  return restored;
}

}  // namespace sybl::window
