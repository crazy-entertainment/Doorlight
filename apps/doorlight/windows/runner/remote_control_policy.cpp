#include "remote_control_policy.h"

#include <algorithm>
#include <cmath>
#include <limits>
#include <type_traits>

namespace sybl::remote {
namespace {

constexpr Capabilities kKnownCapabilities =
    CapabilityBit(Capability::kMouse) | CapabilityBit(Capability::kKeyboard) |
    CapabilityBit(Capability::kText) | CapabilityBit(Capability::kClipboard) |
    CapabilityBit(Capability::kBack) | CapabilityBit(Capability::kHome) |
    CapabilityBit(Capability::kRecents);

bool LowerHex(std::string_view value) {
  return std::all_of(value.begin(), value.end(), [](char c) {
    return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f');
  });
}

bool ConstantTimeEqual(std::string_view a, std::string_view b) {
  std::size_t difference = a.size() ^ b.size();
  const auto count = std::max(a.size(), b.size());
  for (std::size_t i = 0; i < count; ++i) {
    const auto left = i < a.size() ? static_cast<unsigned char>(a[i]) : 0;
    const auto right = i < b.size() ? static_cast<unsigned char>(b[i]) : 0;
    difference |= left ^ right;
  }
  return difference == 0;
}

bool ValidCallId(std::string_view value) {
  return !value.empty() && value.size() <= 128 &&
      std::all_of(value.begin(), value.end(), [](unsigned char c) {
        return c >= 0x21 && c <= 0x7e;
      });
}

bool ValidAccountId(std::string_view value) {
  return value.size() == 40 && LowerHex(value);
}

bool ValidDeviceId(std::string_view value) {
  return value.size() >= 40 && value.size() <= 128 && LowerHex(value);
}

bool ValidToken(std::string_view value) {
  return value.size() >= 32 && value.size() <= 128 && value.size() % 2 == 0 &&
      LowerHex(value);
}

bool ValidSessionBinding(const SessionBinding& binding) {
  return ValidCallId(binding.call_id) &&
      ValidAccountId(binding.controller_account) &&
      ValidDeviceId(binding.controller_device) && binding.source_revision > 0;
}

bool ValidTypedInputEvent(const InputEvent& event) {
  return std::visit(
      [](const auto& item) {
        using T = std::decay_t<decltype(item)>;
        if constexpr (std::is_same_v<T, MoveEvent>)
          return std::isfinite(item.x) && std::isfinite(item.y) &&
              item.x >= 0 && item.x <= 1 && item.y >= 0 && item.y <= 1;
        if constexpr (std::is_same_v<T, WheelEvent>)
          return item.delta != 0 && item.delta >= -12000 && item.delta <= 12000;
        if constexpr (std::is_same_v<T, KeyEvent>)
          return item.virtual_key > 0 && item.virtual_key <= 0xff;
        if constexpr (std::is_same_v<T, TextEvent>)
          return RemoteTextUtf16Units(item.utf8).has_value();
        if constexpr (std::is_same_v<T, ActionEvent>) return true;
        return true;
      },
      event);
}

bool ValidClipboardId(std::string_view value) {
  return value.size() >= 16 && value.size() <= 64 && LowerHex(value);
}

bool ValidSha(std::string_view value) {
  return value.size() == 64 && LowerHex(value);
}

std::uint64_t SaturatingAdd(std::uint64_t left, std::uint64_t right) {
  if (right > std::numeric_limits<std::uint64_t>::max() - left)
    return std::numeric_limits<std::uint64_t>::max();
  return left + right;
}

}  // namespace

bool SessionBinding::operator==(const SessionBinding& other) const {
  return call_id == other.call_id && controller_account == other.controller_account &&
      controller_device == other.controller_device &&
      source_revision == other.source_revision;
}

std::optional<AbsolutePoint> MapToVirtualDesktop(const MoveEvent& event,
                                                 const DesktopRect& source,
                                                 const DesktopRect& virtual_desktop) {
  if (!std::isfinite(event.x) || !std::isfinite(event.y) || event.x < 0 ||
      event.x > 1 || event.y < 0 || event.y > 1 || source.width <= 0 ||
      source.height <= 0 || virtual_desktop.width <= 1 || virtual_desktop.height <= 1) {
    return std::nullopt;
  }
  const std::int64_t source_right =
      static_cast<std::int64_t>(source.left) + source.width;
  const std::int64_t source_bottom =
      static_cast<std::int64_t>(source.top) + source.height;
  const std::int64_t virtual_right =
      static_cast<std::int64_t>(virtual_desktop.left) + virtual_desktop.width;
  const std::int64_t virtual_bottom =
      static_cast<std::int64_t>(virtual_desktop.top) + virtual_desktop.height;
  if (source.left < virtual_desktop.left || source.top < virtual_desktop.top ||
      source_right > virtual_right || source_bottom > virtual_bottom) {
    return std::nullopt;
  }

  const auto pixel_x = static_cast<std::int64_t>(source.left) +
      static_cast<std::int64_t>(std::llround(event.x * (source.width - 1)));
  const auto pixel_y = static_cast<std::int64_t>(source.top) +
      static_cast<std::int64_t>(std::llround(event.y * (source.height - 1)));
  const auto absolute_x = static_cast<std::int64_t>(std::llround(
      static_cast<double>(pixel_x - virtual_desktop.left) * 65535.0 /
      (virtual_desktop.width - 1)));
  const auto absolute_y = static_cast<std::int64_t>(std::llround(
      static_cast<double>(pixel_y - virtual_desktop.top) * 65535.0 /
      (virtual_desktop.height - 1)));
  if (absolute_x < 0 || absolute_x > 65535 || absolute_y < 0 || absolute_y > 65535)
    return std::nullopt;
  return AbsolutePoint{static_cast<std::int32_t>(absolute_x),
                       static_cast<std::int32_t>(absolute_y)};
}

RemoteControlPolicy::RemoteControlPolicy(PolicyLimits limits) : limits_(limits) {}

bool RemoteControlPolicy::ValidBinding(const SessionBinding& binding) const {
  return ValidSessionBinding(binding);
}

bool RemoteControlPolicy::ValidRect(const DesktopRect& rect) const {
  if (rect.width <= 0 || rect.height <= 0) return false;
  const auto right = static_cast<std::int64_t>(rect.left) + rect.width;
  const auto bottom = static_cast<std::int64_t>(rect.top) + rect.height;
  return right >= std::numeric_limits<std::int32_t>::min() &&
      right <= std::numeric_limits<std::int32_t>::max() &&
      bottom >= std::numeric_limits<std::int32_t>::min() &&
      bottom <= std::numeric_limits<std::int32_t>::max();
}

RequestDecision RemoteControlPolicy::ObserveRequest(const SessionBinding& binding,
                                                    std::uint64_t now_ms) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (!ValidBinding(binding)) return RequestDecision::kInvalid;
  if (!(binding == request_binding_)) {
    request_binding_ = binding;
    request_count_ = 0;
    last_request_ms_ = 0;
  }
  if (request_count_ > 0 && now_ms >= last_request_ms_ &&
      now_ms - last_request_ms_ < limits_.request_dedupe_ms) {
    return RequestDecision::kDuplicate;
  }
  if (request_count_ >= limits_.max_requests_per_call) return RequestDecision::kCapped;
  ++request_count_;
  last_request_ms_ = now_ms;
  return RequestDecision::kPrompt;
}

std::optional<ActiveGrant> RemoteControlPolicy::Activate(
    const SessionBinding& binding,
    const DesktopRect& source,
    const DesktopRect& virtual_desktop,
    Capabilities capabilities,
    SecretSource& secrets) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (grant_.active || !ValidBinding(binding) || !ValidRect(source) ||
      !ValidRect(virtual_desktop) ||
      !MapToVirtualDesktop(MoveEvent{0, 0}, source, virtual_desktop) ||
      capabilities == 0 || (capabilities & ~kKnownCapabilities) != 0 ||
      !held_keys_.empty() || !held_buttons_.empty() ||
      !pending_key_releases_.empty() || !pending_button_releases_.empty() ||
      !adapter_release_complete_) {
    return std::nullopt;
  }
  const auto token = secrets.GenerateHex(16);
  if (!token || !ValidToken(*token) || ConstantTimeEqual(*token, last_token_))
    return std::nullopt;
  last_token_ = *token;
  // A fresh, locally consented session clears any stale kill intent — otherwise
  // an interrupt raised while idle would refuse to drain the new session.
  AcknowledgeInterruptLocked();
  grant_ = ActiveGrant{true, false, binding, source, virtual_desktop, capabilities,
                       *token, NextEpochLocked()};
  std::atomic_store_explicit(
      &scoped_interrupt_, std::make_shared<ScopedInterrupt>(grant_.epoch),
      std::memory_order_release);
  last_enqueued_sequence_ = 0;
  queue_.clear();
  rate_window_start_ms_ = 0;
  rate_messages_ = 0;
  rate_events_ = 0;
  return grant_;
}

std::uint64_t RemoteControlPolicy::NextEpochLocked() {
  if (next_epoch_ == std::numeric_limits<std::uint64_t>::max()) next_epoch_ = 0;
  return ++next_epoch_;
}

void RemoteControlPolicy::ClearSessionLocked() {
  std::atomic_store_explicit(&scoped_interrupt_,
                             std::shared_ptr<ScopedInterrupt>{},
                             std::memory_order_release);
  grant_.active = false;
  grant_.suspended = false;
  grant_.binding = {};
  grant_.source = {};
  grant_.virtual_desktop = {};
  grant_.capabilities = 0;
  grant_.token.clear();
  grant_.epoch = next_epoch_;
  queue_.clear();
  last_enqueued_sequence_ = 0;
  rate_window_start_ms_ = 0;
  rate_messages_ = 0;
  rate_events_ = 0;
}

bool RemoteControlPolicy::ReleaseHeldLocked(InputAdapter& adapter) {
  bool all_released = true;
  for (auto it = pending_key_releases_.begin(); it != pending_key_releases_.end();) {
    if (adapter.ReleaseKey(*it)) {
      it = pending_key_releases_.erase(it);
    } else {
      all_released = false;
      ++it;
    }
  }
  for (auto it = pending_button_releases_.begin();
       it != pending_button_releases_.end();) {
    if (adapter.ReleaseButton(*it)) {
      it = pending_button_releases_.erase(it);
    } else {
      all_released = false;
      ++it;
    }
  }
  adapter_release_complete_ = adapter.ReleasePending();
  return all_released && adapter_release_complete_;
}

bool RemoteControlPolicy::Revoke(InputAdapter& adapter) {
  std::lock_guard<std::mutex> lock(mutex_);
  // The revoke IS the answer to any outstanding kill intent.
  AcknowledgeInterruptLocked();
  const bool changed = grant_.active || grant_.suspended || !queue_.empty() ||
      !held_keys_.empty() || !held_buttons_.empty();
  if (changed) NextEpochLocked();
  pending_key_releases_.insert(held_keys_.begin(), held_keys_.end());
  pending_button_releases_.insert(held_buttons_.begin(), held_buttons_.end());
  held_keys_.clear();
  held_buttons_.clear();
  ClearSessionLocked();
  return ReleaseHeldLocked(adapter);
}

bool RemoteControlPolicy::Suspend() {
  std::lock_guard<std::mutex> lock(mutex_);
  if (!grant_.active || grant_.suspended) return false;
  grant_.suspended = true;
  pending_key_releases_.insert(held_keys_.begin(), held_keys_.end());
  pending_button_releases_.insert(held_buttons_.begin(), held_buttons_.end());
  held_keys_.clear();
  held_buttons_.clear();
  queue_.clear();
  return true;
}

bool RemoteControlPolicy::Resume(InputAdapter& adapter) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (!grant_.active || !grant_.suspended) return false;
  if (!ReleaseHeldLocked(adapter)) return false;
  grant_.suspended = false;
  return true;
}

bool RemoteControlPolicy::ReleasePending(InputAdapter& adapter) {
  std::lock_guard<std::mutex> lock(mutex_);
  return ReleaseHeldLocked(adapter);
}

void RemoteControlPolicy::RequestInterrupt() {
  interrupt_generation_.fetch_add(1, std::memory_order_release);
}

std::function<void()> RemoteControlPolicy::CaptureInterrupt(
    std::uint64_t expected_epoch) const {
  const auto target = std::atomic_load_explicit(&scoped_interrupt_,
                                               std::memory_order_acquire);
  if (!target || expected_epoch == 0 || target->epoch != expected_epoch)
    return {};
  return [target] { target->requested.store(true, std::memory_order_release); };
}


bool RemoteControlPolicy::InterruptPendingLocked() const {
  return InterruptPending();
}

bool RemoteControlPolicy::InterruptPending() const {
  const auto target = std::atomic_load_explicit(&scoped_interrupt_,
                                               std::memory_order_acquire);
  return interrupt_generation_.load(std::memory_order_acquire) !=
      interrupt_acknowledged_.load(std::memory_order_acquire) ||
      (target && target->requested.load(std::memory_order_acquire));
}

void RemoteControlPolicy::AcknowledgeInterruptLocked() {
  interrupt_acknowledged_.store(
      interrupt_generation_.load(std::memory_order_acquire),
      std::memory_order_release);
}

// Park the applied prefix's held input for release. Mirrors the adapter-failure
// path, minus the epoch bump and session teardown: an interrupt is not a policy
// failure, and the revoke (when one comes) owns the teardown.
void RemoteControlPolicy::TruncateForInterruptLocked() {
  pending_key_releases_.insert(held_keys_.begin(), held_keys_.end());
  pending_button_releases_.insert(held_buttons_.begin(), held_buttons_.end());
  held_keys_.clear();
  held_buttons_.clear();
  queue_.clear();
}

bool SameSurface(const ResolvedSurface& a, const ResolvedSurface& b) {
  const auto same_rect = [](const DesktopRect& x, const DesktopRect& y) {
    return x.left == y.left && x.top == y.top && x.width == y.width &&
        x.height == y.height;
  };
  return a.device == b.device && same_rect(a.source, b.source) &&
      same_rect(a.virtual_desktop, b.virtual_desktop);
}

bool RemoteControlPolicy::MessageCapabilitiesAllowed(const InputMessage& message) const {
  for (const auto& event : message.events) {
    const bool allowed = std::visit(
        [this](const auto& item) {
          using T = std::decay_t<decltype(item)>;
          if constexpr (std::is_same_v<T, MoveEvent> ||
                        std::is_same_v<T, ButtonEvent> ||
                        std::is_same_v<T, WheelEvent>)
            return HasCapability(grant_.capabilities, Capability::kMouse);
          if constexpr (std::is_same_v<T, KeyEvent>)
            return HasCapability(grant_.capabilities, Capability::kKeyboard);
          if constexpr (std::is_same_v<T, ActionEvent>) {
            const auto capability = item.action == GlobalAction::kBack
                ? Capability::kBack
                : (item.action == GlobalAction::kHome ? Capability::kHome
                                                      : Capability::kRecents);
            return HasCapability(grant_.capabilities, capability);
          }
          return HasCapability(grant_.capabilities, Capability::kText);
        },
        event);
    if (!allowed) return false;
  }
  return true;
}

QueueDecision RemoteControlPolicy::Queue(const SessionBinding& authenticated_sender,
                                         const InputMessage& message,
                                         std::uint64_t now_ms) {
  std::lock_guard<std::mutex> lock(mutex_);
  return QueueLocked(authenticated_sender, message, now_ms, false);
}

QueueDecision RemoteControlPolicy::ConsumeSuppressed(
    const SessionBinding& authenticated_sender,
    const InputMessage& message,
    std::uint64_t now_ms) {
  std::lock_guard<std::mutex> lock(mutex_);
  return QueueLocked(authenticated_sender, message, now_ms, true);
}

QueueDecision RemoteControlPolicy::QueueLocked(
    const SessionBinding& authenticated_sender,
    const InputMessage& message,
    std::uint64_t now_ms,
    bool suppressed) {
  if (!grant_.active) return QueueDecision::kInactive;
  // An unanswered kill intent makes this grant terminal: nothing will drain
  // again until an Activate or Revoke resolves it, so stop accumulating work
  // rather than letting a well-behaved controller keep a zombie queue alive
  // (the per-drain queue clear means the queue-full revoke can never fire).
  if (InterruptPendingLocked()) return QueueDecision::kInactive;
  if (grant_.suspended && !suppressed) return QueueDecision::kSuspended;
  if (!ValidBinding(authenticated_sender) || !(authenticated_sender == grant_.binding))
    return QueueDecision::kBindingMismatch;
  if (message.events.empty() || message.events.size() > kMaxInputEvents)
    return QueueDecision::kInvalid;
  if (!std::all_of(message.events.begin(), message.events.end(),
                   ValidTypedInputEvent))
    return QueueDecision::kInvalid;

  // Rate-limit every syntactically valid input attempt from the authenticated
  // bound device, not only packets that already know the live token. Otherwise
  // a compromised controller can bypass the DoS backstop simply by flooding
  // stale-token or duplicate packets.
  if (rate_messages_ == 0 || now_ms < rate_window_start_ms_ ||
      now_ms - rate_window_start_ms_ >= 1000) {
    rate_window_start_ms_ = now_ms;
    rate_messages_ = 0;
    rate_events_ = 0;
  }
  ++rate_messages_;
  // A text event can expand into hundreds of OS submissions. Charge actual
  // UTF-16 down/up work, not one cheap envelope. Cleanup bypasses this budget.
  for (const auto& event : message.events) {
    if (const auto* text = std::get_if<TextEvent>(&event)) {
      rate_events_ += 2 * *RemoteTextUtf16Units(text->utf8);
    } else {
      ++rate_events_;
    }
  }
  if (rate_messages_ > limits_.max_messages_per_second ||
      rate_events_ > limits_.max_events_per_second) {
    NextEpochLocked();
    pending_key_releases_.insert(held_keys_.begin(), held_keys_.end());
    pending_button_releases_.insert(held_buttons_.begin(), held_buttons_.end());
    held_keys_.clear();
    held_buttons_.clear();
    ClearSessionLocked();
    return QueueDecision::kRateExceededRevoke;
  }
  if (!ConstantTimeEqual(message.token, grant_.token))
    return QueueDecision::kTokenMismatch;
  if (message.epoch != grant_.epoch) return QueueDecision::kEpochMismatch;
  if (message.source_revision != grant_.binding.source_revision)
    return QueueDecision::kSourceMismatch;
  if (message.sequence == 0 || message.sequence <= last_enqueued_sequence_)
    return QueueDecision::kDuplicateOrOutOfOrder;
  if (message.sequence != last_enqueued_sequence_ + 1) {
    NextEpochLocked();
    pending_key_releases_.insert(held_keys_.begin(), held_keys_.end());
    pending_button_releases_.insert(held_buttons_.begin(), held_buttons_.end());
    held_keys_.clear();
    held_buttons_.clear();
    ClearSessionLocked();
    return QueueDecision::kSequenceGapRevoke;
  }
  if (!MessageCapabilitiesAllowed(message))
    return QueueDecision::kCapabilityMismatch;
  if (suppressed) {
    // Received and authenticated, so not a gap; dropped, so never applied.
    last_enqueued_sequence_ = message.sequence;
    return QueueDecision::kConsumedSuppressed;
  }
  if (queue_.size() >= limits_.max_queued_batches) {
    NextEpochLocked();
    pending_key_releases_.insert(held_keys_.begin(), held_keys_.end());
    pending_button_releases_.insert(held_buttons_.begin(), held_buttons_.end());
    held_keys_.clear();
    held_buttons_.clear();
    ClearSessionLocked();
    return QueueDecision::kQueueFullRevoke;
  }
  last_enqueued_sequence_ = message.sequence;
  queue_.push_back(QueuedBatch{authenticated_sender, message});
  return QueueDecision::kQueued;
}

bool RemoteControlPolicy::Revalidate(const QueuedBatch& batch) const {
  return grant_.active && !grant_.suspended && batch.sender == grant_.binding &&
      batch.message.epoch == grant_.epoch &&
      batch.message.source_revision == grant_.binding.source_revision &&
      ConstantTimeEqual(batch.message.token, grant_.token) &&
      MessageCapabilitiesAllowed(batch.message);
}

DrainDecision RemoteControlPolicy::DrainOne(InputAdapter& adapter) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (queue_.empty()) return DrainDecision::kEmpty;
  auto batch = std::move(queue_.front());
  queue_.pop_front();
  if (!Revalidate(batch)) return DrainDecision::kStale;

  // A kill intent raised at ANY time since the last Activate/Revoke acknowledged
  // one blocks injection — not merely one raised after this drain started. The
  // earlier snapshot-per-drain version was invisible to a raise that lost the
  // race for mutex_, which is exactly the case it was written for: Stop() raises
  // pre-lock, then contends with the daemon thread, and a lost handoff let the
  // whole batch inject. The watermark only advances in Activate and Revoke, so
  // an unacknowledged intent keeps refusing.
  if (InterruptPendingLocked()) {
    TruncateForInterruptLocked();
    return DrainDecision::kStale;
  }
  for (const auto& event : batch.message.events) {
    if (InterruptPendingLocked()) {
      // Raced in mid-batch. Inject nothing more, and hand every key/button the
      // applied prefix pressed to the pending-release set right here: the
      // batch's own key-ups were in the discarded tail and are gone, and a
      // revoke does NOT always follow (a WM_HOTKEY for the unregistered id of
      // the pair truncates without revoking). Relying on the caller left
      // VK_CONTROL physically latched on a live session.
      TruncateForInterruptLocked();
      return DrainDecision::kApplied;
    }
    if (!adapter.Apply(event, grant_.source, grant_.virtual_desktop)) {
      NextEpochLocked();
      pending_key_releases_.insert(held_keys_.begin(), held_keys_.end());
      pending_button_releases_.insert(held_buttons_.begin(), held_buttons_.end());
      held_keys_.clear();
      held_buttons_.clear();
      ClearSessionLocked();
      ReleaseHeldLocked(adapter);
      return DrainDecision::kAdapterFailureRevoke;
    }
    if (const auto* key = std::get_if<KeyEvent>(&event)) {
      if (key->down)
        held_keys_.insert(key->virtual_key);
      else
        held_keys_.erase(key->virtual_key);
    } else if (const auto* button = std::get_if<ButtonEvent>(&event)) {
      if (button->down)
        held_buttons_.insert(button->button);
      else
        held_buttons_.erase(button->button);
    }
  }
  return DrainDecision::kApplied;
}

ActiveGrant RemoteControlPolicy::Snapshot() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return grant_;
}

std::size_t RemoteControlPolicy::queued_batches() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return queue_.size();
}

std::size_t RemoteControlPolicy::held_keys() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return held_keys_.size();
}

std::size_t RemoteControlPolicy::held_buttons() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return held_buttons_.size();
}

bool RemoteControlPolicy::release_complete() const {
  std::lock_guard<std::mutex> lock(mutex_);
  // An active key hold is valid input. Revoke/Suspend move it to the pending
  // sets before acknowledging cleanup, so only those obligations belong here.
  return pending_key_releases_.empty() && pending_button_releases_.empty() &&
      adapter_release_complete_;
}

ClipboardConsentPolicy::ClipboardConsentPolicy(PolicyLimits limits) : limits_(limits) {}

void ClipboardConsentPolicy::BindCall(const SessionBinding& binding,
                                      Capabilities capabilities) {
  binding_ = ValidSessionBinding(binding) ? std::optional<SessionBinding>{binding}
                                          : std::nullopt;
  capabilities_ = binding_ ? capabilities : 0;
  pending_.reset();
  observed_ids_.clear();
}

void ClipboardConsentPolicy::EndCall() {
  binding_.reset();
  capabilities_ = 0;
  pending_.reset();
  observed_ids_.clear();
}

bool ClipboardConsentPolicy::Matches(const SessionBinding& sender) const {
  return binding_ && sender == *binding_;
}

ClipboardDecision ClipboardConsentPolicy::ObserveOffer(
    const SessionBinding& sender,
    const ClipboardOfferMessage& offer,
    std::uint64_t now_ms) {
  if (!Matches(sender)) return ClipboardDecision::kBindingMismatch;
  if (!HasCapability(capabilities_, Capability::kClipboard))
    return ClipboardDecision::kCapabilityMismatch;
  if (!ValidClipboardId(offer.id) || !ValidSha(offer.sha256) || offer.size == 0 ||
      offer.size > kMaxClipboardBytes) {
    return ClipboardDecision::kInvalid;
  }
  if (pending_ && now_ms >= pending_->expires_ms) pending_.reset();
  if (observed_ids_.count(offer.id)) return ClipboardDecision::kDuplicate;
  if (observed_ids_.size() >= 64) return ClipboardDecision::kBusy;
  observed_ids_.insert(offer.id);
  if (pending_) {
    if (pending_->offer.id == offer.id && pending_->offer.sha256 == offer.sha256 &&
        pending_->offer.size == offer.size) {
      return ClipboardDecision::kDuplicate;
    }
    return ClipboardDecision::kBusy;
  }
  pending_ = Pending{sender, offer, SaturatingAdd(now_ms, limits_.clipboard_timeout_ms),
                     std::nullopt};
  return ClipboardDecision::kPrompt;
}

ClipboardDecision ClipboardConsentPolicy::ReceiveData(
    const SessionBinding& sender,
    const ClipboardDataMessage& data,
    std::uint64_t now_ms,
    HashProvider& hashes) {
  if (!Matches(sender)) return ClipboardDecision::kBindingMismatch;
  if (!HasCapability(capabilities_, Capability::kClipboard))
    return ClipboardDecision::kCapabilityMismatch;
  if (!pending_) return ClipboardDecision::kInvalid;
  if (now_ms >= pending_->expires_ms) {
    pending_.reset();
    return ClipboardDecision::kExpired;
  }
  if (!(sender == pending_->sender))
    return ClipboardDecision::kBindingMismatch;
  // A crossed/late packet for a different id must not destroy the valid
  // consent transaction already on screen.
  if (data.id != pending_->offer.id)
    return ClipboardDecision::kInvalid;
  if (pending_->received_utf8) return ClipboardDecision::kDuplicate;
  if (!ConstantTimeEqual(data.sha256, pending_->offer.sha256) ||
      data.utf8.size() != pending_->offer.size || data.utf8.empty() ||
      data.utf8.size() > kMaxClipboardBytes) {
    pending_.reset();
    return ClipboardDecision::kInvalid;
  }
  const auto hash = hashes.Sha256Hex(data.utf8);
  if (!hash || !ConstantTimeEqual(*hash, pending_->offer.sha256)) {
    pending_.reset();
    return ClipboardDecision::kHashMismatch;
  }
  pending_->received_utf8 = data.utf8;
  return ClipboardDecision::kReady;
}

std::optional<std::string> ClipboardConsentPolicy::Preview(
    const std::string& id,
    std::uint64_t now_ms) const {
  if (!pending_ || pending_->offer.id != id ||
      now_ms >= pending_->expires_ms || !pending_->received_utf8) {
    return std::nullopt;
  }
  return pending_->received_utf8;
}

std::optional<AcceptedClipboard> ClipboardConsentPolicy::Accept(
    const std::string& id,
    std::uint64_t now_ms) {
  if (!pending_ || now_ms >= pending_->expires_ms || pending_->offer.id != id ||
      !pending_->received_utf8) {
    if (pending_ && now_ms >= pending_->expires_ms) pending_.reset();
    return std::nullopt;
  }
  AcceptedClipboard result{
      pending_->sender, pending_->offer.id,
      std::move(*pending_->received_utf8)};
  pending_.reset();
  return result;
}

ClipboardDecision ClipboardConsentPolicy::Reject(const std::string& id) {
  if (!pending_ || pending_->offer.id != id) return ClipboardDecision::kInvalid;
  pending_.reset();
  return ClipboardDecision::kRejected;
}

}  // namespace sybl::remote
