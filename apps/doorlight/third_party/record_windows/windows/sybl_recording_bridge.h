#pragma once
#include "native_recording_lease.h"
#include "record_config.h"
#include <atomic>
#include <condition_variable>
#include <optional>
#include <thread>
#include <windows.h>

namespace record_windows {
class SybLRecordingBridge {
 public:
  static SybLRecordingBridge& Get();
  void Configure(bool (*current)(uint64_t), void (*released)(uint64_t));
  bool Offer(uint64_t owner, const std::wstring& path);
  NativeRecordingLease::Lease Begin(const std::string& recorder, const RecordConfig& config,
                                   const std::wstring& path, NativeRecordingLease::Stop stop);
  bool Current(const NativeRecordingLease::Lease& ticket) const { return leases_.Current(ticket); }
  void Released(const NativeRecordingLease::Lease& ticket, bool success);
  bool Renew(const std::wstring& path);
  void SetForeground(bool foreground);
  bool RevokeAndWait(uint32_t timeout_ms);

 private:
  SybLRecordingBridge();
  ~SybLRecordingBridge();
  struct Permit { uint64_t owner; std::wstring path; uint64_t expires; };
  void ExpirePermit(bool force = false);
  void Watchdog();
  void CollectRelease();
  std::atomic<bool (*)(uint64_t)> owner_current_{nullptr};
  std::atomic<void (*)(uint64_t)> owner_released_{nullptr};
  NativeRecordingLease leases_;
  std::mutex mutex_;
  std::optional<Permit> permit_;
  NativeRecordingLease::Lease ticket_;
  std::wstring path_;
  bool foreground_ = false;
  std::mutex timer_mutex_;
  std::condition_variable timer_wake_;
  bool stopping_ = false;
  std::thread watchdog_;
};
}  // namespace record_windows
