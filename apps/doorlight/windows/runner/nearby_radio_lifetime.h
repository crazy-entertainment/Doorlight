#pragma once
#include <utility>

namespace sybl::nearby_radio {
// WinRT cleanup can pump callbacks back into the owner; detach before calling it.
template <typename T>
void Cancel(T& operation) noexcept {
  auto owned = std::exchange(operation, nullptr);
  try { if (owned) owned.Cancel(); } catch (...) {}
}

template <typename T>
void Close(T& object) noexcept {
  auto owned = std::exchange(object, nullptr);
  try { if (owned) owned.Close(); } catch (...) {}
}
}  // namespace sybl::nearby_radio
