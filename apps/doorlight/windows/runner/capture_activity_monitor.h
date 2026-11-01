#ifndef RUNNER_CAPTURE_ACTIVITY_MONITOR_H_
#define RUNNER_CAPTURE_ACTIVITY_MONITOR_H_

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <filesystem>
#include <functional>
#include <mutex>
#include <optional>
#include <string>
#include <string_view>
#include <thread>
#include <vector>

namespace sybl::capture {

// Parses only complete host activity records from the current OS-owned process
// lifetime. Missing startup/history remains unknown, never assumed idle.
std::optional<bool> ParseStreamingHostLog(std::string_view bytes,
                                        std::uint64_t process_started);
std::optional<bool> QueryStreamingHostActivity();

inline constexpr std::uintmax_t kMaxObsLogBytes = 16 * 1024 * 1024;

class ObsCaptureLogState {
 public:
  explicit ObsCaptureLogState(bool allow_startup = true);
  void Observe(std::string_view line);
  std::optional<bool> known_activity() const;
  bool active() const { return known_activity() == true; }
  void Reset();

 private:
  std::optional<bool> recording_;
  std::optional<bool> streaming_;
  bool allow_startup_;
  bool output_seen_ = false;
};

struct ObsProcessIdentity {
  std::uint32_t pid = 0;
  std::uint64_t started = 0;  // Windows FILETIME, not a reusable PID alone.
  std::uint32_t session = 0;
  std::wstring user_sid;
  bool operator==(const ObsProcessIdentity& other) const;
};

struct ObsLogSource {
  ObsProcessIdentity process;
  std::filesystem::path path;
  bool operator==(const ObsLogSource& other) const;
};

struct ObsSourceSnapshot {
  std::uint32_t session = 0;
  std::wstring user_sid;
  std::vector<ObsProcessIdentity> processes;
  // Each association comes from the OS file-owner query, not file recency.
  std::vector<ObsLogSource> logs;
};

// Reads only OBS Studio's local process state and current text log. It does
// not enable OBS WebSocket, read its password, or change OBS configuration.
class ObsCaptureProbe {
 public:
  using SourceQuery = std::function<std::optional<ObsSourceSnapshot>()>;

  explicit ObsCaptureProbe(SourceQuery sources = {});
  std::optional<bool> Query();

 private:
  struct History {
    ObsLogSource source;
    std::uint64_t volume = 0;
    std::uint64_t file_id = 0;
    std::uint64_t created = 0;
    std::uint64_t size = 0;
    std::string digest;
    bool unbroken = true;
  };
  SourceQuery sources_;
  std::vector<History> histories_;
};

class CaptureActivityTransition {
 public:
  std::optional<bool> Observe(bool active);

 private:
  std::optional<bool> last_;
};

// Reports OBS recording and streaming transitions. The callback runs on the
// monitor thread. The owner must move it to the Flutter platform thread before
// it touches a channel.
class WindowsCaptureActivityMonitor {
 public:
  using Callback = std::function<void(bool)>;
  using Query = std::function<std::optional<bool>()>;

  explicit WindowsCaptureActivityMonitor(
      Callback callback,
      Query query = {},
      std::chrono::milliseconds interval = std::chrono::seconds(30),
      std::vector<std::filesystem::path> watch_paths = {});
  ~WindowsCaptureActivityMonitor();

  WindowsCaptureActivityMonitor(const WindowsCaptureActivityMonitor&) = delete;
  WindowsCaptureActivityMonitor& operator=(
      const WindowsCaptureActivityMonitor&) = delete;

  void Start();
  void Stop();

 private:
  void Run();

  Callback callback_;
  Query query_;
  const std::chrono::milliseconds interval_;
  std::vector<std::filesystem::path> watch_paths_;
  void* stop_event_ = nullptr;
  std::atomic<bool> stop_{false};
  std::mutex wait_mutex_;
  std::condition_variable wait_cv_;
  std::thread thread_;
};

}  // namespace sybl::capture

#endif  // RUNNER_CAPTURE_ACTIVITY_MONITOR_H_
