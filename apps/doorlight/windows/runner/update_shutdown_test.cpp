#include "update_shutdown.h"

#include <cassert>
#include <condition_variable>
#include <mutex>
#include <thread>

int main() {
  using sybl::update::ShutdownReservation;
  ShutdownReservation update;
  int quits = 0;
  auto quit = [&] { ++quits; return true; };

  assert(!update.Begin("", 1));
  assert(update.Begin("account", 1));
  assert(update.pending() && !update.reserved());
  // An earlier queued user operation is allowed to finish before reservation;
  // an admitted call then makes preparation fail without terminating that call.
  assert(!update.Reserve(update.attempt(), "account", 1, false));
  assert(!update.Commit(update.attempt(), "account", 1, true, quit));
  assert(update.Cancel());
  assert(quits == 0 && !update.pending());

  assert(update.Begin("account", 1));
  assert(update.Reserve(update.attempt(), "account", 1, true));
  // Account A -> B -> A must not authorize the old shutdown reservation.
  assert(!update.Commit(update.attempt(), "account", 3, true, quit));
  assert(update.Cancel());

  assert(update.Begin("account", 3));
  assert(update.Reserve(update.attempt(), "account", 3, true));
  // A transfer which starts and finishes during the helper handoff still
  // revokes that attempt, even when the final idle snapshot is true again.
  update.Interrupt();
  assert(!update.Commit(update.attempt(), "account", 3, true, quit));
  assert(update.Cancel());

  assert(update.Begin("account", 3));
  assert(update.Reserve(update.attempt(), "account", 3, true));
  assert(!update.Commit(update.attempt(), "account", 3, true, [] { return false; }));
  assert(update.Cancel());

  // Exercise the production gate under the same shared admission mutex: an
  // incoming call which loses to reservation is not admitted; a transfer which
  // wins before commit prevents the quit callback from running.
  std::mutex mutex;
  std::condition_variable cv;
  bool signaled = false;
  bool call_admitted = false;
  assert(update.Begin("account", 3));
  assert(update.Reserve(update.attempt(), "account", 3, true));
  std::thread native_signal([&] {
    std::lock_guard lock(mutex);
    call_admitted = !update.reserved();
    update.Interrupt();
    signaled = true;
    cv.notify_one();
  });
  {
    std::unique_lock lock(mutex);
    cv.wait(lock, [&] { return signaled; });
    assert(!update.Commit(update.attempt(), "account", 3, true, quit));
  }
  native_signal.join();
  assert(!call_admitted && quits == 0);
  assert(update.Cancel());
  assert(!update.reserved());

  // Pause old FIFO work, cancel from the platform thread, then start another
  // attempt for the SAME account/revision before the old work resumes.
  assert(update.Begin("account", 3));
  const auto old_attempt = update.attempt();
  assert(update.Reserve(old_attempt, "account", 3, true));
  bool resume_old = false;
  std::thread old_worker([&] {
    std::unique_lock lock(mutex);
    cv.wait(lock, [&] { return resume_old; });
    // These model both delayed preparation and delayed commit, including the
    // preparation failure/exception cleanup after a daemon query returns.
    assert(!update.current(old_attempt));
    assert(update.pending() && !update.reserved());
    assert(!update.Reserve(old_attempt, "account", 3, true));
    assert(!update.Cancel(old_attempt));
    assert(update.Reserve(update.attempt(), "account", 3, true));
    assert(!update.Commit(old_attempt, "account", 3, true, quit));
  });
  {
    std::lock_guard lock(mutex);
    assert(update.Cancel());
    assert(update.Cancel());  // An already-cancelled attempt is not committed.
    assert(update.Begin("account", 3));
    assert(update.attempt() > old_attempt);
    assert(!update.Begin("account", 3));
    assert(!update.Reserve(update.attempt(), "other", 3, true));
    assert(!update.Reserve(update.attempt(), "account", 4, true));
    resume_old = true;
    cv.notify_one();
  }
  old_worker.join();
  assert(update.pending() && update.reserved() && quits == 0);
  assert(update.Cancel());

  assert(update.Begin("account", 3));
  assert(update.Reserve(update.attempt(), "account", 3, true));
  assert(update.Commit(update.attempt(), "account", 3, true, quit));
  assert(quits == 1);
  assert(!update.Cancel());
  assert(!update.Commit(update.attempt(), "account", 3, true, quit));
  assert(update.pending() && update.reserved());
  assert(quits == 1);
}
