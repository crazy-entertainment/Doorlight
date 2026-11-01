// This observer contains failures at its polling boundary. Enable standard
// library exceptions here even when Flutter's runner disables them by default.
#ifdef _HAS_EXCEPTIONS
#undef _HAS_EXCEPTIONS
#endif
#define _HAS_EXCEPTIONS 1
#include "capture_activity_monitor.h"

#include <windows.h>
#include <tlhelp32.h>
#include <restartmanager.h>
#include <sddl.h>
#include <shlobj.h>
#include "uat_profile.h"
#include <bcrypt.h>

#include <algorithm>
#include <array>
#include <iterator>
#include <memory>
#include <string>
#include <cstdio>

namespace sybl::capture {
namespace {

constexpr std::string_view kRecordingStart = "==== Recording Start ";
constexpr std::string_view kRecordingStop = "==== Recording Stop ";
constexpr std::string_view kStreamingStart = "==== Streaming Start ";
constexpr std::string_view kStreamingStop = "==== Streaming Stop ";
constexpr std::string_view kStartup = "==== Startup complete ";

bool IsMarker(std::string_view message, std::string_view marker) {
  return message.size() > marker.size() &&
      message.substr(0, marker.size()) == marker &&
      message.substr(marker.size()).find_first_not_of('=') ==
          std::string_view::npos;
}

constexpr std::size_t kMaxObsProcesses = 16;
constexpr std::size_t kMaxLogCandidates = 128;
constexpr std::size_t kMaxLogLineBytes = 16 * 1024;

class ScopedHandle {
 public:
  explicit ScopedHandle(HANDLE handle) : handle_(handle) {}
  ~ScopedHandle() { if (valid()) CloseHandle(handle_); }
  ScopedHandle(const ScopedHandle&) = delete;
  ScopedHandle& operator=(const ScopedHandle&) = delete;
  bool valid() const { return handle_ && handle_ != INVALID_HANDLE_VALUE; }
  HANDLE get() const { return handle_; }
 private:
  HANDLE handle_;
};

std::uint64_t TimeValue(FILETIME value) {
  return (static_cast<std::uint64_t>(value.dwHighDateTime) << 32) | value.dwLowDateTime;
}

std::optional<std::wstring> ProcessUser(HANDLE process) {
  HANDLE raw = nullptr;
  if (!OpenProcessToken(process, TOKEN_QUERY, &raw)) return std::nullopt;
  ScopedHandle token(raw);
  DWORD needed = 0;
  GetTokenInformation(token.get(), TokenUser, nullptr, 0, &needed);
  if (needed == 0 || needed > 64 * 1024) return std::nullopt;
  std::vector<unsigned char> bytes(needed);
  if (!GetTokenInformation(token.get(), TokenUser, bytes.data(), needed, &needed))
    return std::nullopt;
  LPWSTR sid = nullptr;
  if (!ConvertSidToStringSidW(reinterpret_cast<TOKEN_USER*>(bytes.data())->User.Sid, &sid))
    return std::nullopt;
  const auto free_sid = [](WCHAR* value) { LocalFree(value); };
  const std::unique_ptr<WCHAR, decltype(free_sid)> owned_sid(sid, free_sid);
  return std::wstring(owned_sid.get());
}

struct FileIdentity {
  std::uint64_t volume, index, created, written, size;
  bool SameFile(const FileIdentity& other) const {
    return volume == other.volume && index == other.index && created == other.created;
  }
  bool operator==(const FileIdentity& other) const {
    return volume == other.volume && index == other.index && created == other.created &&
        written == other.written && size == other.size;
  }
};

std::optional<FileIdentity> FileInfo(HANDLE file) {
  BY_HANDLE_FILE_INFORMATION info{};
  if (GetFileType(file) != FILE_TYPE_DISK || !GetFileInformationByHandle(file, &info) ||
      (info.dwFileAttributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT)))
    return std::nullopt;
  return FileIdentity{info.dwVolumeSerialNumber,
      (static_cast<std::uint64_t>(info.nFileIndexHigh) << 32) | info.nFileIndexLow,
      TimeValue(info.ftCreationTime), TimeValue(info.ftLastWriteTime),
      (static_cast<std::uint64_t>(info.nFileSizeHigh) << 32) | info.nFileSizeLow};
}

HANDLE OpenLog(const std::filesystem::path& path) {
  return CreateFileW(path.c_str(), GENERIC_READ,
      FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr, OPEN_EXISTING,
      FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_SEQUENTIAL_SCAN, nullptr);
}

class FileOwnerSession {
 public:
  explicit FileOwnerSession(const std::filesystem::path& path) {
    WCHAR key[CCH_RM_SESSION_KEY + 1]{};
    active_ = RmStartSession(&session_, 0, key) == ERROR_SUCCESS;
    LPCWSTR file = path.c_str();
    registered_ = active_ &&
        RmRegisterResources(session_, 1, &file, 0, nullptr, 0, nullptr) == ERROR_SUCCESS;
  }
  ~FileOwnerSession() { if (active_) RmEndSession(session_); }
  FileOwnerSession(const FileOwnerSession&) = delete;
  FileOwnerSession& operator=(const FileOwnerSession&) = delete;

  std::optional<std::vector<RM_PROCESS_INFO>> Query() const {
    if (!registered_) return std::nullopt;
    std::array<RM_PROCESS_INFO, 64> owners{};
    UINT count = static_cast<UINT>(owners.size());
    UINT needed = 0;
    DWORD reasons = 0;
    if (RmGetList(session_, &needed, &count, owners.data(), &reasons) != ERROR_SUCCESS ||
        count > owners.size()) return std::nullopt;
    return std::vector<RM_PROCESS_INFO>(owners.begin(), owners.begin() + count);
  }

 private:
  // Query bookkeeping only. Never call RmShutdown or RmRestart.
  DWORD session_ = 0;
  bool active_ = false;
  bool registered_ = false;
};

using LogCandidate = std::pair<std::filesystem::path, FileIdentity>;

struct FileOwnerCache {
  struct Entry {
    LogCandidate file;
    std::unique_ptr<FileOwnerSession> session;
  };
  std::vector<ObsProcessIdentity> processes;
  std::vector<Entry> entries;

  void Retain(const std::vector<ObsProcessIdentity>& current,
              const std::vector<LogCandidate>& candidates) {
    if (processes != current) entries.clear();
    processes = current;
    entries.erase(std::remove_if(entries.begin(), entries.end(), [&](const Entry& entry) {
      return std::none_of(candidates.begin(), candidates.end(), [&](const LogCandidate& candidate) {
        return entry.file.first == candidate.first && entry.file.second.SameFile(candidate.second);
      });
    }), entries.end());
  }

  std::optional<std::vector<RM_PROCESS_INFO>> Query(const LogCandidate& candidate) {
    auto entry = std::find_if(entries.begin(), entries.end(), [&](const Entry& value) {
      return value.file.first == candidate.first;
    });
    if (entry == entries.end()) {
      // Restart Manager has a per-user-session quota shared with other software.
      // Keep at most 16 registrations; normal polls only query existing sessions.
      if (entries.size() >= kMaxObsProcesses) return std::nullopt;
      entries.push_back({candidate, std::make_unique<FileOwnerSession>(candidate.first)});
      entry = std::prev(entries.end());
    }
    const auto result = entry->session->Query();
    if (!result) entries.erase(entry);  // A later sample may recover from an OS query failure.
    return result;
  }
};

std::optional<ObsSourceSnapshot> ObserveObsSources(FileOwnerCache& cache) {
  ObsSourceSnapshot result;
  DWORD own_session = 0;
  const auto own_user = ProcessUser(GetCurrentProcess());
  if (!own_user || !ProcessIdToSessionId(GetCurrentProcessId(), &own_session)) return std::nullopt;
  result.session = own_session;
  result.user_sid = *own_user;
  ScopedHandle snapshot(CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0));
  if (!snapshot.valid()) return std::nullopt;
  PROCESSENTRY32W entry{};
  entry.dwSize = sizeof(entry);
  if (!Process32FirstW(snapshot.get(), &entry))
    return GetLastError() == ERROR_NO_MORE_FILES ? std::optional(result) : std::nullopt;
  std::size_t enumerated = 0;
  do {
    if (++enumerated > 8192) return std::nullopt;
    if (_wcsicmp(entry.szExeFile, L"obs64.exe") != 0) continue;
    DWORD process_session = 0;
    if (!ProcessIdToSessionId(entry.th32ProcessID, &process_session)) return std::nullopt;
    if (process_session != own_session) continue;
    ScopedHandle process(OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE,
                                      FALSE, entry.th32ProcessID));
    if (!process.valid() || WaitForSingleObject(process.get(), 0) != WAIT_TIMEOUT)
      return std::nullopt;
    FILETIME created{}, exited{}, kernel{}, user{};
    std::array<WCHAR, 32768> image{};
    DWORD image_length = static_cast<DWORD>(image.size());
    const auto process_user = ProcessUser(process.get());
    if (!process_user || *process_user != *own_user ||
        !GetProcessTimes(process.get(), &created, &exited, &kernel, &user) ||
        !QueryFullProcessImageNameW(process.get(), 0, image.data(), &image_length) ||
        _wcsicmp(std::filesystem::path(image.data()).filename().c_str(), L"obs64.exe") != 0)
      return std::nullopt;
    result.processes.push_back({entry.th32ProcessID, TimeValue(created), process_session, *process_user});
    if (result.processes.size() > kMaxObsProcesses) return std::nullopt;
  } while (Process32NextW(snapshot.get(), &entry));
  if (GetLastError() != ERROR_NO_MORE_FILES) return std::nullopt;
  std::sort(result.processes.begin(), result.processes.end(),
      [](const ObsProcessIdentity& a, const ObsProcessIdentity& b) { return a.pid < b.pid; });
  if (cache.processes != result.processes) cache.Retain(result.processes, {});
  if (result.processes.empty()) {
    cache.Retain({}, {});
    return result;
  }

  PWSTR roaming = nullptr;
  const auto path_result = sybl::uat::KnownFolderPath(FOLDERID_RoamingAppData, 0, nullptr, &roaming);
  const auto free_path = [](WCHAR* value) { CoTaskMemFree(value); };
  const std::unique_ptr<WCHAR, decltype(free_path)> owned_path(roaming, free_path);
  if (FAILED(path_result) || !owned_path) return std::nullopt;
  const auto root = std::filesystem::path(owned_path.get()) / L"obs-studio";
  const auto directory = root / L"logs";
  for (const auto& path : {root, directory}) {
    const DWORD attributes = GetFileAttributesW(path.c_str());
    if (attributes == INVALID_FILE_ATTRIBUTES || !(attributes & FILE_ATTRIBUTE_DIRECTORY) ||
        (attributes & FILE_ATTRIBUTE_REPARSE_POINT)) return std::nullopt;
  }
  std::error_code error;
  std::filesystem::directory_iterator files(directory, error), end;
  if (error) return std::nullopt;
  std::size_t count = 0;
  std::vector<LogCandidate> candidates;
  while (files != end) {
    if (++count > kMaxLogCandidates) return std::nullopt;
    const auto path = files->path();
    if (path.extension() == L".txt") {
      ScopedHandle file(OpenLog(path));
      const auto info = file.valid() ? FileInfo(file.get()) : std::nullopt;
      if (!info) return std::nullopt;
      const bool possibly_current = std::any_of(result.processes.begin(), result.processes.end(),
          [&](const ObsProcessIdentity& process) { return info->created >= process.started; });
      if (possibly_current) {
        candidates.push_back({path, *info});
        if (candidates.size() > kMaxObsProcesses) {
          cache.Retain(result.processes, {});
          return std::nullopt;
        }
      }
    }
    files.increment(error);
    if (error) return std::nullopt;
  }
  cache.Retain(result.processes, candidates);
  for (const auto& candidate : candidates) {
    const auto owners = cache.Query(candidate);
    if (!owners) return std::nullopt;
    for (const auto& process : result.processes) {
      if (candidate.second.created < process.started) continue;
      const auto owner = std::find_if(owners->begin(), owners->end(),
              [&](const RM_PROCESS_INFO& value) {
                return value.Process.dwProcessId == process.pid &&
                    TimeValue(value.Process.ProcessStartTime) == process.started &&
                    value.TSSessionId == process.session;
              });
      if (owner != owners->end()) result.logs.push_back({process, candidate.first});
    }
  }
  return result;
}

std::optional<std::vector<ObsLogSource>> SelectSources(const ObsSourceSnapshot& snapshot) {
  if (snapshot.user_sid.empty() || snapshot.processes.size() > kMaxObsProcesses ||
      snapshot.logs.size() > kMaxLogCandidates) return std::nullopt;
  std::vector<ObsLogSource> sources;
  for (const auto& process : snapshot.processes) {
    if (process.session != snapshot.session) continue;
    if (process.pid == 0 || process.started == 0 || process.user_sid != snapshot.user_sid)
      return std::nullopt;
    const ObsLogSource* match = nullptr;
    for (const auto& log : snapshot.logs) {
      if (!(log.process == process)) continue;
      if (match || log.path.empty()) return std::nullopt;
      match = &log;
    }
    if (!match || std::any_of(sources.begin(), sources.end(), [&](const ObsLogSource& prior) {
          return prior.path == match->path || prior.process.pid == process.pid;
        })) return std::nullopt;
    sources.push_back(*match);
  }
  std::sort(sources.begin(), sources.end(), [](const ObsLogSource& a, const ObsLogSource& b) {
    return a.process.pid < b.process.pid;
  });
  return sources;
}

std::optional<std::string> Digest(std::string_view bytes) {
  std::string hash(32, '\0');
  BCRYPT_ALG_HANDLE algorithm = nullptr;
  if (BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_SHA256_ALGORITHM, nullptr, 0) < 0)
    return std::nullopt;
  const auto status = BCryptHash(algorithm, nullptr, 0,
      reinterpret_cast<PUCHAR>(const_cast<char*>(bytes.data())), static_cast<ULONG>(bytes.size()),
      reinterpret_cast<PUCHAR>(hash.data()), static_cast<ULONG>(hash.size()));
  BCryptCloseAlgorithmProvider(algorithm, 0);
  return status >= 0 ? std::optional(std::move(hash)) : std::nullopt;
}

}  // namespace

bool ObsProcessIdentity::operator==(const ObsProcessIdentity& other) const {
  return pid == other.pid && started == other.started && session == other.session &&
      user_sid == other.user_sid;
}

bool ObsLogSource::operator==(const ObsLogSource& other) const {
  return process == other.process && path == other.path;
}

ObsCaptureLogState::ObsCaptureLogState(bool allow_startup) : allow_startup_(allow_startup) {}

std::optional<bool> ObsCaptureLogState::known_activity() const {
  if (recording_ == true || streaming_ == true) return true;
  if (recording_ == false && streaming_ == false) return false;
  return std::nullopt;
}

void ObsCaptureLogState::Observe(std::string_view line) {
  // OBS prefixes each record with HH:MM:SS[.mmm]: . A marker inside a
  // scene name or other log message is not an output-state record.
  if (!line.empty() && line.back() == '\r') line.remove_suffix(1);
  const auto separator = line.find(": ");
  if (separator != 8 && separator != 12) return;
  for (size_t i = 0; i < separator; ++i) {
    const char expected = (i == 2 || i == 5) ? ':' : (i == 8 ? '.' : '\0');
    if (expected ? line[i] != expected : (line[i] < '0' || line[i] > '9')) {
      return;
    }
  }
  line.remove_prefix(separator + 2);
  if (IsMarker(line, kStartup)) {
    // Standard OBS logs this before creating its streaming/recording outputs.
    // A duplicate/later marker cannot erase an output record already observed.
    if (allow_startup_ && !output_seen_) Reset();
    allow_startup_ = false;
    return;
  }
  if (IsMarker(line, kRecordingStart)) {
    recording_ = true;
    output_seen_ = true;
  } else if (IsMarker(line, kRecordingStop)) {
    recording_ = false;
    output_seen_ = true;
  }
  if (IsMarker(line, kStreamingStart)) {
    streaming_ = true;
    output_seen_ = true;
  } else if (IsMarker(line, kStreamingStop)) {
    streaming_ = false;
    output_seen_ = true;
  }
}

void ObsCaptureLogState::Reset() {
  recording_ = false;
  streaming_ = false;
}

ObsCaptureProbe::ObsCaptureProbe(SourceQuery sources)
    : sources_(std::move(sources)) {
  if (!sources_) {
    auto cache = std::make_shared<FileOwnerCache>();
    sources_ = [cache] { return ObserveObsSources(*cache); };
  }
}

std::optional<bool> ObsCaptureProbe::Query() {
  try {
    const auto observation = sources_();
    if (!observation) return std::nullopt;
    const auto selected = SelectSources(*observation);
    if (!selected) return std::nullopt;
    if (selected->empty()) {
      histories_.clear();
      return false;
    }
    std::vector<History> next;
    std::vector<FileIdentity> identities;
    std::uint64_t total_bytes = 0;
    bool active = false;
    bool unknown = false;
    for (const auto& source : *selected) {
      ScopedHandle file(OpenLog(source.path));
      const auto before = file.valid() ? FileInfo(file.get()) : std::nullopt;
      if (!before || before->created < source.process.started ||
          before->size > kMaxObsLogBytes - total_bytes) return std::nullopt;
      total_bytes += before->size;
      std::string bytes(static_cast<std::size_t>(before->size), '\0');
      DWORD read = 0;
      if (!bytes.empty() &&
          (!ReadFile(file.get(), bytes.data(), static_cast<DWORD>(bytes.size()), &read, nullptr) ||
           read != bytes.size())) return std::nullopt;
      const auto after = FileInfo(file.get());
      if (!after || !(*before == *after)) return std::nullopt;
      const auto old = std::find_if(histories_.begin(), histories_.end(),
          [&](const History& history) { return history.source.process == source.process; });
      bool unbroken = true;
      if (old != histories_.end()) {
        unbroken = old->unbroken && old->source.path == source.path &&
            old->volume == before->volume && old->file_id == before->index &&
            old->created == before->created && old->size <= before->size;
        if (unbroken) {
          const auto prefix = Digest(std::string_view(bytes).substr(0, static_cast<std::size_t>(old->size)));
          if (!prefix) return std::nullopt;
          unbroken = *prefix == old->digest;
        }
      }
      ObsCaptureLogState state(unbroken);
      std::size_t offset = 0;
      for (;;) {
        const auto end = bytes.find('\n', offset);
        if (end == std::string::npos) break;  // An incomplete final record has no state effect.
        if (end - offset > kMaxLogLineBytes) return std::nullopt;
        state.Observe(std::string_view(bytes).substr(offset, end - offset));
        offset = end + 1;
      }
      if (bytes.size() - offset > kMaxLogLineBytes) return std::nullopt;
      const auto value = state.known_activity();
      active = active || value == true;
      unknown = unknown || !value.has_value();
      const auto hash = Digest(bytes);
      if (!hash) return std::nullopt;
      next.push_back({source, before->volume, before->index, before->created,
                     before->size, *hash, unbroken});
      identities.push_back(*before);
    }
    // No cached process name or reused PID can authorize a later observation.
    const auto final_observation = sources_();
    const auto final_sources = final_observation ? SelectSources(*final_observation) : std::nullopt;
    if (!final_sources || *final_sources != *selected) return std::nullopt;
    for (std::size_t i = 0; i < selected->size(); ++i) {
      ScopedHandle current(OpenLog((*selected)[i].path));
      const auto identity = current.valid() ? FileInfo(current.get()) : std::nullopt;
      if (!identity || !(*identity == identities[i])) return std::nullopt;
    }
    histories_ = std::move(next);
    return active ? std::optional(true) : unknown ? std::nullopt : std::optional(false);
  } catch (...) {
    return std::nullopt;
  }
}

std::optional<bool> CaptureActivityTransition::Observe(bool active) {
  if (last_.has_value() && *last_ == active) return std::nullopt;
  last_ = active;
  return active;
}

std::optional<bool> ParseStreamingHostLog(std::string_view bytes,
                                        std::uint64_t process_started) {
  unsigned connected = 0;
  bool complete = false, output_seen = false;
  std::size_t offset = 0;
  while (offset < bytes.size()) {
    const auto end = bytes.find('\n', offset);
    if (end == std::string_view::npos) break;
    auto line = bytes.substr(offset, end - offset);
    offset = end + 1;
    if (line.size() > kMaxLogLineBytes) return std::nullopt;
    if (!line.empty() && line.back() == '\r') line.remove_suffix(1);
    if (line.size() < 33 || line[0] != '[' || line.substr(24, 9) != "]: Info: ") continue;
    SYSTEMTIME local{}, utc{};
    const auto stamp = std::string(line.substr(1, 23));
    if (sscanf_s(stamp.c_str(), "%hu-%hu-%hu %hu:%hu:%hu.%hu",
        &local.wYear, &local.wMonth, &local.wDay, &local.wHour,
        &local.wMinute, &local.wSecond, &local.wMilliseconds) != 7) continue;
    FILETIME time{};
    if (!TzSpecificLocalTimeToSystemTime(nullptr, &local, &utc) ||
        !SystemTimeToFileTime(&utc, &time) || TimeValue(time) < process_started) continue;
    const auto message = line.substr(33);
    if (!output_seen && (message.substr(0, 16) == "Apollo version: " ||
                         message.substr(0, 18) == "Sunshine version: ")) complete = true;
    if (message == "CLIENT CONNECTED") {
      if (++connected > 1024) return std::nullopt;
      output_seen = true;
    } else if (message == "CLIENT DISCONNECTED") {
      if (connected) --connected;
      else complete = false;
      output_seen = true;
    }
  }
  return connected ? std::optional(true) : complete ? std::optional(false) : std::nullopt;
}

std::optional<bool> QueryStreamingHostActivity() {
  try {
    DWORD session = 0;
    if (!ProcessIdToSessionId(GetCurrentProcessId(), &session)) return std::nullopt;
    // Product logs are signals; process presence alone never reports capture.
    ScopedHandle snapshot(CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0));
    if (!snapshot.valid()) return std::nullopt;
    PROCESSENTRY32W entry{}; entry.dwSize = sizeof(entry);
    std::vector<DWORD> hosts;
    if (!Process32FirstW(snapshot.get(), &entry)) return std::nullopt;
    do {
      // A service-owned host may deny process queries to a normal desktop app.
      // Restart Manager below supplies its session and lifetime without elevation.
      if (_wcsicmp(entry.szExeFile, L"sunshine.exe") == 0)
        hosts.push_back(entry.th32ProcessID);
    } while (Process32NextW(snapshot.get(), &entry));
    if (GetLastError() != ERROR_NO_MORE_FILES) return std::nullopt;
    if (hosts.empty()) return false;
    PWSTR root = nullptr;
    if (FAILED(sybl::uat::KnownFolderPath(FOLDERID_ProgramFiles, 0, nullptr, &root))) return std::nullopt;
    const std::filesystem::path program_files(root);
    CoTaskMemFree(root);
    bool active = false;
    std::vector<DWORD> observed;
    for (const auto product : {L"Sunshine", L"Apollo"}) {
      const auto path = program_files / product / L"config" / L"sunshine.log";
      ScopedHandle file(OpenLog(path));
      const auto before = file.valid() ? FileInfo(file.get()) : std::nullopt;
      if (!before || before->size > kMaxObsLogBytes) continue;
      FileOwnerSession owner(path);
      const auto owners = owner.Query();
      if (!owners) continue;
      for (const auto& process : *owners) {
        const auto pid = process.Process.dwProcessId;
        if (process.TSSessionId != session ||
            std::find(hosts.begin(), hosts.end(), pid) == hosts.end()) continue;
        LARGE_INTEGER zero{};
        if (!SetFilePointerEx(file.get(), zero, nullptr, FILE_BEGIN)) return std::nullopt;
        std::string bytes(static_cast<std::size_t>(before->size), '\0');
        DWORD read = 0;
        if (!ReadFile(file.get(), bytes.data(), static_cast<DWORD>(bytes.size()), &read, nullptr) ||
            read != bytes.size()) return std::nullopt;
        const auto after = FileInfo(file.get());
        ScopedHandle current_file(OpenLog(path));
        const auto current_info = current_file.valid() ? FileInfo(current_file.get()) : std::nullopt;
        const auto final_owners = owner.Query();
        if (!after || !(*after == *before) || !current_info || !(*current_info == *before) || !final_owners ||
            std::none_of(final_owners->begin(), final_owners->end(), [&](const RM_PROCESS_INFO& current) {
              return current.Process.dwProcessId == pid && current.TSSessionId == session &&
                  TimeValue(current.Process.ProcessStartTime) == TimeValue(process.Process.ProcessStartTime);
            })) return std::nullopt;
        const auto value = ParseStreamingHostLog(bytes, TimeValue(process.Process.ProcessStartTime));
        if (value == true) active = true;
        if (value.has_value()) observed.push_back(pid);
      }
    }
    if (active) return true;
    for (const auto host : hosts)
      if (std::find(observed.begin(), observed.end(), host) == observed.end()) return std::nullopt;
    return false;
  } catch (...) { return std::nullopt; }
}

WindowsCaptureActivityMonitor::WindowsCaptureActivityMonitor(
    Callback callback,
    Query query,
    std::chrono::milliseconds interval,
    std::vector<std::filesystem::path> watch_paths)
    : callback_(std::move(callback)),
      query_(std::move(query)),
      interval_(interval),
      watch_paths_(std::move(watch_paths)) {
  if (!query_) {
    PWSTR root = nullptr;
    if (SUCCEEDED(sybl::uat::KnownFolderPath(FOLDERID_RoamingAppData, 0, nullptr, &root))) {
      watch_paths_.push_back(std::filesystem::path(root) / L"obs-studio" / L"logs");
      CoTaskMemFree(root);
    }
    root = nullptr;
    if (SUCCEEDED(sybl::uat::KnownFolderPath(FOLDERID_ProgramFiles, 0, nullptr, &root))) {
      for (const auto product : {L"Sunshine", L"Apollo"})
        watch_paths_.push_back(std::filesystem::path(root) / product / L"config");
      CoTaskMemFree(root);
    }
    auto probe = std::make_shared<ObsCaptureProbe>();
    query_ = [probe]() -> std::optional<bool> {
      const auto obs = probe->Query();
      const auto host = QueryStreamingHostActivity();
      if (obs == true || host == true) return true;
      if (!obs.has_value() || !host.has_value()) return std::nullopt;
      return false;
    };
  }
}

WindowsCaptureActivityMonitor::~WindowsCaptureActivityMonitor() { Stop(); }

void WindowsCaptureActivityMonitor::Start() {
  if (thread_.joinable()) return;
  stop_ = false;
  stop_event_ = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  thread_ = std::thread([this]() { Run(); });
}

void WindowsCaptureActivityMonitor::Stop() {
  stop_ = true;
  if (stop_event_) SetEvent(stop_event_);
  wait_cv_.notify_all();
  if (thread_.joinable()) thread_.join();
  if (stop_event_) CloseHandle(stop_event_);
  stop_event_ = nullptr;
}

void WindowsCaptureActivityMonitor::Run() {
  CaptureActivityTransition transition;
  while (!stop_) {
    // Arm before querying so a write during the query cannot be missed.
    // Watch only supported log directories, never the whole user profile.
    std::vector<HANDLE> notifications;
    if (stop_event_) {
      for (const auto& path : watch_paths_) {
        if (notifications.size() >= MAXIMUM_WAIT_OBJECTS - 1) break;
        const auto handle = FindFirstChangeNotificationW(path.c_str(), FALSE,
            FILE_NOTIFY_CHANGE_FILE_NAME | FILE_NOTIFY_CHANGE_SIZE |
            FILE_NOTIFY_CHANGE_LAST_WRITE);
        if (handle != INVALID_HANDLE_VALUE) notifications.push_back(handle);
      }
    }
    try {
      const auto active = query_();
      if (active.has_value()) {
        auto candidate = transition;
        const auto changed = candidate.Observe(*active);
        if (changed.has_value()) {
          callback_(*changed);
          transition = candidate;
        }
      }
    } catch (...) {}  // A failed observer cannot terminate the monitor thread or change protection.
    if (stop_event_) {
      std::vector<HANDLE> handles{stop_event_};
      handles.insert(handles.end(), notifications.begin(), notifications.end());
      const auto result = WaitForMultipleObjects(static_cast<DWORD>(handles.size()),
          handles.data(), FALSE, static_cast<DWORD>(interval_.count()));
      for (const auto handle : notifications) FindCloseChangeNotification(handle);
      if (result != WAIT_FAILED) continue;
    }
    // Recovery for unavailable watchers, new directories and host restarts.
    std::unique_lock<std::mutex> lock(wait_mutex_);
    wait_cv_.wait_for(lock, interval_, [this]() { return stop_.load(); });
  }
}

}  // namespace sybl::capture
