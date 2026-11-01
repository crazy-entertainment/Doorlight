#include "sybl_recording_bridge.h"
#include "include/record_windows/record_windows_plugin_c_api.h"

namespace record_windows {
SybLRecordingBridge& SybLRecordingBridge::Get() {
  static SybLRecordingBridge bridge;
  return bridge;
}

SybLRecordingBridge::SybLRecordingBridge()
    : leases_([] { return GetTickCount64(); }, [this](uint64_t owner) {
        const auto current = owner_current_.load();
        return current && current(owner);
      }), watchdog_([this] { Watchdog(); }) {}

SybLRecordingBridge::~SybLRecordingBridge() {
  { std::lock_guard<std::mutex> lock(timer_mutex_); stopping_ = true; }
  timer_wake_.notify_all();
  watchdog_.join();
  owner_current_.store(nullptr);
  owner_released_.store(nullptr);
  leases_.Revoke();
}

void SybLRecordingBridge::Configure(bool (*current)(uint64_t), void (*released)(uint64_t)) {
  owner_current_.store(current);
  owner_released_.store(released);
}

bool SybLRecordingBridge::Offer(uint64_t owner, const std::wstring& path) {
  std::lock_guard<std::mutex> lock(mutex_);
  const auto current = owner_current_.load();
  if (!foreground_ || permit_ || leases_.Occupied() || !current || !current(owner) || path.empty()) return false;
  permit_ = Permit{owner, path, GetTickCount64() + 2000};
  return true;
}

void SybLRecordingBridge::ExpirePermit(bool force) {
  std::optional<Permit> expired;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    const auto current = owner_current_.load();
    if (permit_ && (force || GetTickCount64() >= permit_->expires || !current || !current(permit_->owner))) {
      expired = std::move(permit_);
      permit_.reset();
    }
  }
  const auto released = owner_released_.load();
  if (expired && released) released(expired->owner);
}

NativeRecordingLease::Lease SybLRecordingBridge::Begin(const std::string& recorder,
    const RecordConfig& config, const std::wstring& path, NativeRecordingLease::Stop stop) {
  if (config.encoderName != AudioEncoder::aacLc || config.sampleRate != 48000 ||
      config.numChannels != 1 || config.bitRate != 96000) return {};
  std::lock_guard<std::mutex> lock(mutex_);
  if (!permit_ || permit_->path != path || GetTickCount64() >= permit_->expires) return {};
  auto ticket = leases_.Begin(permit_->owner, recorder, std::move(stop));
  if (!ticket) return {};
  ticket_ = ticket;
  path_ = path;
  permit_.reset();
  return ticket;
}

void SybLRecordingBridge::Released(const NativeRecordingLease::Lease& ticket, bool success) {
  leases_.Released(ticket, success);
  CollectRelease();
}

void SybLRecordingBridge::CollectRelease() {
  // Failed release remains occupied. Stale and repeated callbacks cannot
  // retire another host owner or clear its output path.
  bool retired = false;
  NativeRecordingLease::Lease ticket;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (ticket_ && ticket_->released.wait_for(std::chrono::milliseconds(0)) == std::future_status::ready &&
        ticket_->released.get()) {
      ticket = ticket_;
      ticket_.reset(); path_.clear(); retired = true;
    }
  }
  const auto released = owner_released_.load();
  if (retired && released) released(ticket->owner);
}

bool SybLRecordingBridge::Renew(const std::wstring& path) {
  std::lock_guard<std::mutex> lock(mutex_);
  return path == path_ && leases_.Renew(ticket_);
}

void SybLRecordingBridge::SetForeground(bool foreground) {
  { std::lock_guard<std::mutex> lock(mutex_); foreground_ = foreground; }
  if (!foreground) ExpirePermit(true);
  leases_.SetForeground(foreground);
}

bool SybLRecordingBridge::RevokeAndWait(uint32_t timeout_ms) {
  ExpirePermit(true);
  const auto release = leases_.Revoke();
  const bool ready = release.wait_for(std::chrono::milliseconds(std::min<uint32_t>(timeout_ms, 3000))) ==
      std::future_status::ready && release.get();
  if (ready) CollectRelease();
  return ready;
}

void SybLRecordingBridge::Watchdog() {
  std::unique_lock<std::mutex> timer(timer_mutex_);
  while (!timer_wake_.wait_for(timer, std::chrono::milliseconds(100), [this] { return stopping_; })) {
    timer.unlock();
    try { ExpirePermit(); leases_.Tick(); CollectRelease(); }
    catch (...) { leases_.Revoke(); }
    timer.lock();
  }
}
}  // namespace record_windows

void RecordWindowsSybLConfigure(bool (*current)(uint64_t), void (*released)(uint64_t)) {
  try { record_windows::SybLRecordingBridge::Get().Configure(current, released); }
  catch (...) { }
}
bool RecordWindowsSybLOffer(uint64_t owner, const wchar_t* path) {
  try { return path && record_windows::SybLRecordingBridge::Get().Offer(owner, path); }
  catch (...) { return false; }
}
bool RecordWindowsSybLRenew(const wchar_t* path) {
  try { return path && record_windows::SybLRecordingBridge::Get().Renew(path); }
  catch (...) { return false; }
}
void RecordWindowsSybLSetForeground(bool foreground) {
  try { record_windows::SybLRecordingBridge::Get().SetForeground(foreground); }
  catch (...) { }
}
bool RecordWindowsSybLRevokeAndWait(uint32_t timeout_ms) {
  try { return record_windows::SybLRecordingBridge::Get().RevokeAndWait(timeout_ms); }
  catch (...) { return false; }
}
