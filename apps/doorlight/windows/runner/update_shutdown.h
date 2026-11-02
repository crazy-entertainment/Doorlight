#pragma once

#include <cstdint>
#include <limits>
#include <string>

namespace sybl::update {

// The bridge supplies its existing state mutex. Begin closes user admission
// before the FIFO worker barrier; Reserve then closes native call admission.
// No identity/privacy flag is borrowed, so cancellation cannot undo other work.
class ShutdownReservation {
 public:
  bool Begin(const std::string& account, uint64_t revision) {
    if (pending_ || account.empty() || revision == std::numeric_limits<uint64_t>::max() ||
        attempt_ == std::numeric_limits<uint64_t>::max()) return false;
    ++attempt_;
    account_ = account;
    revision_ = revision;
    pending_ = true;
    return true;
  }

  uint64_t attempt() const { return attempt_; }
  bool current(uint64_t attempt) const { return pending_ && attempt == attempt_; }

  bool Reserve(uint64_t attempt, const std::string& account, uint64_t revision, bool idle) {
    if (!current(attempt) || reserved_ || interrupted_ || !Matches(account, revision) || !idle) return false;
    reserved_ = true;
    return true;
  }

  bool pending() const { return pending_; }
  bool reserved() const { return reserved_; }
  void Interrupt() { if (pending_) interrupted_ = true; }

  template <class PostQuit>
  bool Commit(uint64_t attempt, const std::string& account, uint64_t revision, bool idle, PostQuit post_quit) {
    if (!current(attempt) || !reserved_ || committed_ || interrupted_ || !Matches(account, revision) || !idle) return false;
    // The caller holds the same mutex used by admission and transfer signals.
    // Posting the ordinary quit is the shutdown linearization point.
    if (!post_quit()) return false;
    committed_ = true;
    return true;
  }

  bool Cancel() {
    if (committed_) return false;
    account_.clear();
    revision_ = 0;
    pending_ = reserved_ = interrupted_ = false;
    return true;
  }

  bool Cancel(uint64_t attempt) { return current(attempt) && Cancel(); }

 private:
  bool Matches(const std::string& account, uint64_t revision) const {
    return account == account_ && revision == revision_;
  }
  std::string account_;
  uint64_t revision_ = 0;
  uint64_t attempt_ = 0;
  bool pending_ = false;
  bool reserved_ = false;
  bool interrupted_ = false;
  bool committed_ = false;
};

}  // namespace sybl::update
