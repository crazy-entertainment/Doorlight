#pragma once
#include <cstdint>
#include <optional>
#include <utility>

namespace sybl {
// The caller serializes access. Reads never renew authority.
template<class T> class NativeAuthorityLease {
 public:
  bool Publish(T value, uint64_t observed, uint64_t now) {
    if (now < observed || now - observed >= 250) { Clear(); return false; }
    observed_ = observed;
    value_ = std::move(value);
    return true;
  }
  const T* Current(uint64_t now) const {
    return value_ && now >= observed_ && now - observed_ < 250 ? &*value_ : nullptr;
  }
  bool RefreshDue(uint64_t now) const {
    return !value_ || now < observed_ || now - observed_ >= 100;
  }
  void Clear() { value_.reset(); }
 private:
  std::optional<T> value_;
  uint64_t observed_ = 0;
};
}
