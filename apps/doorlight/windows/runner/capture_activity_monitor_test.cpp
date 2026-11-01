#ifdef NDEBUG
#undef NDEBUG
#endif

#include "capture_activity_monitor.h"

#include <cassert>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

#include <windows.h>

namespace {

sybl::capture::ObsSourceSnapshot Sources(const std::filesystem::path& path,
                                        std::uint64_t started = 1) {
  sybl::capture::ObsSourceSnapshot value;
  value.session = 7;
  value.user_sid = L"synthetic-user";
  const sybl::capture::ObsProcessIdentity process{11, started, 7, value.user_sid};
  value.processes.push_back(process);
  value.logs.push_back({process, path});
  return value;
}

void TestRewrittenLog(const std::filesystem::path& scratch, bool replace) {
  const auto path = scratch /
      ("capture-rewrite-" + std::to_string(GetCurrentProcessId()) + ".txt");
  const auto write = [&](const std::string& message) {
    std::ofstream file(path, std::ios::binary | std::ios::trunc);
    file << message << std::string(512, 'x') << '\n';
    file.close();
    assert(file.good());
  };
  write("12:00:00: ==== Recording Start ===\n");
  sybl::capture::ObsCaptureProbe probe(
      [&] { return std::optional(Sources(path)); });
  assert(probe.Query() == true);
  if (replace) assert(std::filesystem::remove(path));
  // The replacement is longer than the previous observed offset. An offset
  // cache must not carry old recording state across rewrite or replacement.
  write("12:00:01: ==== Recording Stop ================\n"
        "12:00:01: ==== Streaming Stop ================\n");
  assert(probe.Query() == false);
  assert(std::filesystem::remove(path));
}

void TestQueryExceptionIsUnknown() {
  sybl::capture::ObsCaptureProbe probe(
      []() -> std::optional<sybl::capture::ObsSourceSnapshot> {
        throw std::runtime_error("fixture query failure");
      });
  bool escaped = false;
  std::optional<bool> value;
  try { value = probe.Query(); } catch (...) { escaped = true; }
  assert(!escaped && !value.has_value());
}

void TestFreshProbeLostHistory(const std::filesystem::path& scratch) {
  const auto path = scratch /
      ("capture-fresh-history-" + std::to_string(GetCurrentProcessId()) + ".txt");
  {
    std::ofstream file(path, std::ios::binary | std::ios::trunc);
    file << "12:00:00: ==== Recording Start ===\n";
  }
  const auto source = [&] { return std::optional(Sources(path)); };
  sybl::capture::ObsCaptureProbe first(source);
  assert(first.Query() == true);
  {
    std::ofstream file(path, std::ios::binary | std::ios::trunc);
    file << "12:00:01: idle\n";
  }
  // The same OBS process still owns this file. A newly created observer has no
  // prior size/digest, but absence of a start marker does not prove inactivity.
  sybl::capture::ObsCaptureProbe fresh(source);
  assert(!fresh.Query().has_value());
  assert(std::filesystem::remove(path));
}

void TestSameSizeRewrite(const std::filesystem::path& scratch) {
  const auto path = scratch /
      ("capture-same-size-" + std::to_string(GetCurrentProcessId()) + ".txt");
  const auto write = [&](const std::string& message) {
    std::ofstream file(path, std::ios::binary | std::ios::trunc);
    file << message << std::string(256 - message.size(), 'x') << '\n';
    file.close();
    assert(file.good());
  };
  write("12:00:00: ==== Recording Start ===\n");
  sybl::capture::ObsCaptureProbe probe([&] { return std::optional(Sources(path)); });
  assert(probe.Query() == true);
  write("12:00:01: idle\n");
  assert(!probe.Query().has_value());  // Equal size and identity do not prove append-only history.
  write("12:00:02: ==== Recording Stop ===\n");
  assert(!probe.Query().has_value());  // Lost streaming history has no proved stop.
  write("12:00:02: ==== Recording Stop ===\n12:00:02: ==== Streaming Stop ===\n");
  assert(probe.Query() == false);
  assert(std::filesystem::remove(path));
}

void TestLogReadBound(const std::filesystem::path& scratch) {
  const auto path = scratch /
      ("capture-oversized-" + std::to_string(GetCurrentProcessId()) + ".txt");
  {
    std::ofstream file(path, std::ios::binary | std::ios::trunc);
    const std::string line = "12:00:00: " + std::string(1012, 'x') + "\n";
    for (std::uintmax_t written = 0; written <= sybl::capture::kMaxObsLogBytes;
         written += line.size()) file << line;
    file << "12:00:01: ==== Recording Start ===\n";
    file.close();
    assert(file.good());
  }
  sybl::capture::ObsCaptureProbe probe(
      [&] { return std::optional(Sources(path)); });
  assert(!probe.Query().has_value());
  assert(std::filesystem::remove(path));
}

void TestProcessOwnership(const std::filesystem::path& scratch) {
  const auto path = scratch /
      ("capture-ownership-" + std::to_string(GetCurrentProcessId()) + ".txt");
  {
    std::ofstream file(path, std::ios::binary | std::ios::trunc);
    file << "12:00:00: ==== Recording Start ===\n";
  }
  auto observation = Sources(path);
  sybl::capture::ObsCaptureProbe probe([&] { return std::optional(observation); });
  assert(probe.Query() == true);
  // PID reuse, unmatched log owner, and wrong user cannot borrow an old log.
  observation.processes[0].started = 2;
  assert(!probe.Query().has_value());
  observation.logs[0].process = observation.processes[0];
  assert(probe.Query() == true);
  observation.logs[0].process.pid = 99;
  assert(!probe.Query().has_value());
  observation = Sources(path);
  observation.processes[0].user_sid = L"another-user";
  observation.logs[0].process = observation.processes[0];
  assert(!probe.Query().has_value());
  observation = Sources(path);
  observation.processes[0].session = 8;
  observation.logs[0].process = observation.processes[0];
  assert(probe.Query() == false);  // A different desktop session is outside this observer.
  observation = Sources(path);
  observation.logs.push_back(observation.logs[0]);
  assert(!probe.Query().has_value());  // One process with two candidate logs is ambiguous.
  assert(std::filesystem::remove(path));
}

void TestMultipleInstances(const std::filesystem::path& scratch) {
  const auto prefix = "capture-multiple-" + std::to_string(GetCurrentProcessId());
  const auto first = scratch / (prefix + "-1.txt");
  const auto second = scratch / (prefix + "-2.txt");
  const auto write = [](const std::filesystem::path& path, const std::string& value, bool append) {
    std::ofstream file(path, std::ios::binary | (append ? std::ios::app : std::ios::trunc));
    file << value;
    file.close();
    assert(file.good());
  };
  write(first, "12:00:00: ==== Startup complete ===\n12:00:00: ==== Recording Start ===\n", false);
  write(second, "12:00:00: ==== Startup complete ===\n12:00:00: idle\n", false);
  auto observation = Sources(first);
  auto process = observation.processes[0];
  process.pid = 12;
  observation.processes.push_back(process);
  observation.logs.push_back({process, second});
  sybl::capture::ObsCaptureProbe probe([&] { return std::optional(observation); });
  assert(probe.Query() == true);  // A newer idle log does not conceal another recording instance.
  write(first, "12:00:01: ==== Recording Stop ===\n", true);
  assert(probe.Query() == false);
  write(second, "12:00:02: ==== Streaming Start ===\n", true);
  assert(probe.Query() == true);
  observation.logs[1].path = first;
  assert(!probe.Query().has_value());  // A shared log cannot identify two writers' output states.
  assert(std::filesystem::remove(first));
  assert(std::filesystem::remove(second));
}

void TestObservationChangesDuringRead(const std::filesystem::path& scratch) {
  const auto path = scratch /
      ("capture-interleaving-" + std::to_string(GetCurrentProcessId()) + ".txt");
  {
    std::ofstream file(path, std::ios::binary | std::ios::trunc);
    file << "12:00:00: ==== Recording Start ===\n";
  }
  auto observation = Sources(path);
  int samples = 0;
  sybl::capture::ObsCaptureProbe replaced([&] {
    auto result = observation;
    if (++samples == 2) {
      result.processes[0].started = 2;
      result.logs[0].process = result.processes[0];
    }
    return std::optional(result);
  });
  assert(!replaced.Query().has_value());
  samples = 0;
  sybl::capture::ObsCaptureProbe rewritten([&] {
    if (++samples == 2) {
      std::ofstream file(path, std::ios::binary | std::ios::app);
      file << "12:00:01: ==== Recording Stop ===\n";
    }
    return std::optional(observation);
  });
  assert(!rewritten.Query().has_value());
  assert(std::filesystem::remove(path));
}

void TestProbe(const std::filesystem::path& scratch) {
  using sybl::capture::ObsCaptureProbe;
  const auto directory = scratch /
      ("capture-probe-" + std::to_string(GetCurrentProcessId()));
  std::filesystem::create_directories(directory);
  const auto log = directory / "synthetic.txt";
  const auto rotated = directory / "rotated.txt";
  auto write = [](const std::filesystem::path& path, const char* text,
                  bool append = false) {
    std::ofstream file(path, std::ios::binary |
        (append ? std::ios::app : std::ios::trunc));
    file << text;
    file.close();
    assert(file.good());
  };
  std::optional<bool> running = true;
  std::optional<std::filesystem::path> latest = log;
  std::uint64_t started = 1;
  ObsCaptureProbe probe([&]() -> std::optional<sybl::capture::ObsSourceSnapshot> {
    if (!running.has_value()) return std::nullopt;
    auto sources = Sources(latest.value_or(log), started);
    if (!*running) {
      sources.processes.clear();
      sources.logs.clear();
    } else if (!latest) {
      sources.logs.clear();
    }
    return sources;
  });
  write(log, "12:00:00: ==== Startup complete ===\n12:00:00: ==== Recording Start ===\n");
  assert(probe.Query() == true);
  running = std::nullopt;
  assert(!probe.Query().has_value());
  running = true;
  latest = std::nullopt;
  assert(!probe.Query().has_value());
  latest = log;
  assert(probe.Query() == true);

  // A writer can stop at any byte. Neither half alone is a complete marker.
  write(log, "12:00:01: ==== Recording St", true);
  assert(probe.Query() == true);
  write(log, "op ===\n", true);
  assert(probe.Query() == false);
  write(log, "12:00:02: ==== Streaming St", true);
  assert(probe.Query() == false);
  write(log, "art ===\n", true);
  assert(probe.Query() == true);

  write(rotated, "12:00:03: ==== Startup complete ===\n12:00:03: idle\n");
  latest = rotated;
  assert(!probe.Query().has_value());  // No standard same-process log rotation contract.
  ++started;  // A new proved process owns the fresh log, so initial idle is meaningful.
  assert(probe.Query() == false);
  write(rotated, "12:00:04: ==== Recording Start ===\n", true);
  assert(probe.Query() == true);
  write(rotated, "idle\n");  // Truncation removes output history; it does not prove a stop.
  assert(!probe.Query().has_value());
  write(rotated, "12:00:05: ==== Recording Start ===\n", true);
  assert(probe.Query() == true);
  std::filesystem::remove(rotated);
  assert(!probe.Query().has_value());
  running = false;
  assert(probe.Query() == false);  // A proved process exit is a stop.
  std::filesystem::remove(log);
  std::filesystem::remove(directory);
}

void TestDirectoryWake(const std::filesystem::path& scratch) {
  const auto directory = scratch / ("capture-watch-" + std::to_string(GetCurrentProcessId()));
  std::filesystem::create_directories(directory);
  std::mutex mutex;
  std::condition_variable changed;
  int queries = 0;
  sybl::capture::WindowsCaptureActivityMonitor monitor([](bool) {}, [&] {
    std::lock_guard<std::mutex> lock(mutex);
    ++queries;
    changed.notify_all();
    return std::optional(false);
  }, std::chrono::seconds(30), {directory});
  monitor.Start();
  {
    std::unique_lock<std::mutex> lock(mutex);
    assert(changed.wait_for(lock, std::chrono::seconds(5), [&] { return queries == 1; }));
    assert(!changed.wait_for(lock, std::chrono::milliseconds(1200), [&] { return queries > 1; }));
  }
  { std::ofstream file(directory / "activity.log"); file << "changed\n"; }
  {
    std::unique_lock<std::mutex> lock(mutex);
    assert(changed.wait_for(lock, std::chrono::seconds(5), [&] { return queries > 1; }));
  }
  const auto before = std::chrono::steady_clock::now();
  monitor.Stop();
  assert(std::chrono::steady_clock::now() - before < std::chrono::seconds(2));
  std::filesystem::remove_all(directory);
}

void TestMonitor() {
  using namespace std::chrono_literals;
  std::mutex mutex;
  std::condition_variable changed;
  std::vector<bool> events;
  const std::vector<std::optional<bool>> samples{
      false, false, true, std::nullopt, true, false};
  size_t next = 0;
  bool threw = false;
  sybl::capture::WindowsCaptureActivityMonitor monitor(
      [&](bool active) {
        std::lock_guard<std::mutex> lock(mutex);
        events.push_back(active);
        changed.notify_all();
      },
      [&]() -> std::optional<bool> {
        if (next == 4 && !threw) {
          threw = true;
          throw std::runtime_error("fixture monitor query failure");
        }
        return next < samples.size() ? samples[next++] : std::nullopt;
      }, 1ms);
  monitor.Start();
  {
    std::unique_lock<std::mutex> lock(mutex);
    assert(changed.wait_for(lock, 5s, [&] { return events.size() == 3; }));
  }
  monitor.Stop();
  monitor.Stop();
  assert((events == std::vector<bool>{false, true, false}));
}

void TestCallbackFailureRetries() {
  using namespace std::chrono_literals;
  std::mutex mutex;
  std::condition_variable changed;
  int attempts = 0;
  bool delivered = false;
  sybl::capture::WindowsCaptureActivityMonitor monitor(
      [&](bool active) {
        std::lock_guard<std::mutex> lock(mutex);
        assert(active);
        if (++attempts == 1) throw std::runtime_error("fixture delivery failure");
        delivered = true;
        changed.notify_all();
      }, [] { return std::optional(true); }, 1ms);
  monitor.Start();
  {
    std::unique_lock<std::mutex> lock(mutex);
    assert(changed.wait_for(lock, 5s, [&] { return delivered; }));
  }
  monitor.Stop();
  assert(attempts == 2);
}

}  // namespace

int main(int argc, char** argv) {
  if (argc == 2 && std::string(argv[1]) == "--stream-host-probe") {
    const auto activity = sybl::capture::QueryStreamingHostActivity();
    std::cout << (activity == true ? "active" : activity == false ? "inactive" : "unknown") << '\n';
    return activity.has_value() ? 0 : 2;
  }
  {
    using sybl::capture::ParseStreamingHostLog;
    const std::string start = "[2026-09-13 08:40:26.495]: Info: Apollo version: test\n";
    const std::string connect = "[2026-09-13 08:41:26.495]: Info: CLIENT CONNECTED\n";
    const std::string disconnect = "[2026-09-13 08:42:26.495]: Info: CLIENT DISCONNECTED\n";
    assert(ParseStreamingHostLog(start, 0) == false);
    assert(ParseStreamingHostLog(start + connect, 0) == true);
    assert(ParseStreamingHostLog(start + connect + connect + disconnect, 0) == true);
    assert(ParseStreamingHostLog(start + connect + disconnect, 0) == false);
    assert(!ParseStreamingHostLog(connect + disconnect, 0).has_value());
    assert(!ParseStreamingHostLog(start + connect, UINT64_MAX).has_value());
    assert(ParseStreamingHostLog(start + connect.substr(0, connect.size() - 1), 0) == false);
    assert(ParseStreamingHostLog(start + "[2026-09-13 08:41:26.495]: Info: title CLIENT CONNECTED\n", 0) == false);
    assert(!ParseStreamingHostLog("", 0).has_value());
  }
  if (argc < 2 || argc > 3) return 2;
  if (argc == 3) {
    const std::string selected = argv[2];
    if (selected == "rewrite") TestRewrittenLog(argv[1], false);
    else if (selected == "replacement") TestRewrittenLog(argv[1], true);
    else if (selected == "query-exception") TestQueryExceptionIsUnknown();
    else if (selected == "fresh-history") TestFreshProbeLostHistory(argv[1]);
    else if (selected == "same-size") TestSameSizeRewrite(argv[1]);
    else if (selected == "read-bound") TestLogReadBound(argv[1]);
    else if (selected == "ownership") TestProcessOwnership(argv[1]);
    else if (selected == "multiple") TestMultipleInstances(argv[1]);
    else if (selected == "interleaving") TestObservationChangesDuringRead(argv[1]);
    else return 2;
    std::cout << "Capture activity case passed: " << selected << '\n';
    return 0;
  }
  using sybl::capture::CaptureActivityTransition;
  using sybl::capture::ObsCaptureLogState;

  ObsCaptureLogState obs;
  assert(!obs.known_activity().has_value());
  obs.Observe("12:00:00.000: ==== Startup complete ===============================================");
  assert(obs.known_activity() == false);
  assert(!obs.active());
  obs.Observe("12:00:00.000: - scene '==== Recording Start':");
  assert(!obs.active());
  obs.Observe("12:00:00.000: ==== Recording Start ================");
  assert(obs.active());
  obs.Observe("12:00:00.000: ==== Startup complete ===============================================");
  assert(obs.active());  // A duplicate startup record cannot clear an output.
  obs.Observe("12:00:00.000: User added scene '==== Recording Stop'");
  assert(obs.active());
  obs.Observe("12:00:00.000: ==== Recording Stop === trailing text");
  obs.Observe("bad: ==== Recording Stop ===");
  assert(obs.active());
  obs.Observe("12:00:01.000: unrelated log line");
  assert(obs.active());
  obs.Observe("12:00:02.000: ==== Recording Stop ================================================\r");
  assert(!obs.active());

  obs.Observe("12:00:03.000: ==== Streaming Start ================");
  assert(obs.active());
  obs.Observe("12:00:04.000: ==== Recording Start ================");
  obs.Observe("12:00:05.000: ==== Streaming Stop =================");
  assert(obs.active());
  obs.Observe("12:00:06.000: ==== Recording Stop =================");
  assert(!obs.active());

  CaptureActivityTransition transition;
  const auto initial = transition.Observe(false);
  assert(initial.has_value() && !*initial);
  assert(!transition.Observe(false).has_value());

  const auto started = transition.Observe(true);
  assert(started.has_value() && *started);
  assert(!transition.Observe(true).has_value());

  const auto stopped = transition.Observe(false);
  assert(stopped.has_value() && !*stopped);

  TestProbe(argv[1]);
  TestMonitor();
  TestDirectoryWake(argv[1]);
  TestCallbackFailureRetries();
  TestRewrittenLog(argv[1], false);
  TestRewrittenLog(argv[1], true);
  TestQueryExceptionIsUnknown();
  TestFreshProbeLostHistory(argv[1]);
  TestSameSizeRewrite(argv[1]);
  TestLogReadBound(argv[1]);
  TestProcessOwnership(argv[1]);
  TestMultipleInstances(argv[1]);
  TestObservationChangesDuringRead(argv[1]);
  std::cout << "Capture activity tests passed.\n";
  return 0;
}
