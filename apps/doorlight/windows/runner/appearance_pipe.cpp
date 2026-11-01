#include "appearance_pipe.h"

#include <appmodel.h>
#include <sddl.h>
#include <userenv.h>

#include <array>
#include <atomic>
#include <mutex>
#include <thread>
#include <utility>
#include <vector>

namespace sybl::appearance {
namespace {
constexpr wchar_t kPackage[] = L"DoorlightOverlayProto_ygmhnd3vvdymm";
struct Handle {
  HANDLE value = nullptr;
  explicit Handle(HANDLE h = nullptr) : value(h) {}
  ~Handle() { if (value && value != INVALID_HANDLE_VALUE) CloseHandle(value); }
  Handle(const Handle&) = delete;
  Handle& operator=(const Handle&) = delete;
};

std::vector<BYTE> TokenInfo(HANDLE token, TOKEN_INFORMATION_CLASS kind) {
  DWORD bytes = 0;
  GetTokenInformation(token, kind, nullptr, 0, &bytes);
  if (!bytes || bytes > 65536) return {};
  std::vector<BYTE> result(bytes);
  if (!GetTokenInformation(token, kind, result.data(), bytes, &bytes)) return {};
  return result;
}

std::wstring SidText(PSID sid) {
  LPWSTR text = nullptr;
  if (!sid || !ConvertSidToStringSidW(sid, &text)) return {};
  std::wstring result(text);
  LocalFree(text);
  return result;
}

bool ValidFrame(const std::string& frame, size_t limit) {
  return !frame.empty() && frame.size() <= limit &&
      frame.find_first_of("\r\n\0", 0, 3) == std::string::npos &&
      MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, frame.data(),
                          static_cast<int>(frame.size()), nullptr, 0) > 0;
}

// Cancellation is only a request. Join the completion before releasing its
// OVERLAPPED or buffer, including during app shutdown.
void Cancel(HANDLE pipe, OVERLAPPED& operation) {
  CancelIoEx(pipe, &operation);
  DWORD ignored = 0;
  GetOverlappedResult(pipe, &operation, &ignored, TRUE);
}
}  // namespace

bool VerifyWidgetClient(HANDLE pipe) {
  ULONG pid = 0, session = 0, own_session = 0;
  if (!GetNamedPipeClientProcessId(pipe, &pid) ||
      !GetNamedPipeClientSessionId(pipe, &session) ||
      !ProcessIdToSessionId(GetCurrentProcessId(), &own_session) ||
      session != own_session) return false;
  Handle process(OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid));
  if (!process.value) return false;
  std::array<wchar_t, PACKAGE_FAMILY_NAME_MAX_LENGTH + 1> family{};
  UINT32 length = static_cast<UINT32>(family.size());
  if (GetPackageFamilyName(process.value, &length, family.data()) != ERROR_SUCCESS ||
      std::wstring(family.data()) != kPackage) return false;
  ULONG confirmed_pid = 0;
  if (!GetNamedPipeClientProcessId(pipe, &confirmed_pid) || confirmed_pid != pid) return false;
  HANDLE client_token = nullptr, own_token = nullptr;
  if (!OpenProcessToken(process.value, TOKEN_QUERY, &client_token)) return false;
  Handle client(client_token);
  if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &own_token)) return false;
  Handle own(own_token);
  const auto client_user = TokenInfo(client.value, TokenUser);
  const auto own_user = TokenInfo(own.value, TokenUser);
  const auto token_session = TokenInfo(client.value, TokenSessionId);
  return !client_user.empty() && !own_user.empty() && token_session.size() == sizeof(DWORD) &&
      *reinterpret_cast<const DWORD*>(token_session.data()) == own_session &&
      EqualSid(reinterpret_cast<const TOKEN_USER*>(client_user.data())->User.Sid,
               reinterpret_cast<const TOKEN_USER*>(own_user.data())->User.Sid);
}

struct Pipe::Impl {
  struct Session {
    std::mutex mutex;
    bool active = true;
    bool awaiting = false;
    std::string reply;
    HANDLE changed = nullptr;  // owned independently of the pipe/runner lifetime
    Session() : changed(CreateEventW(nullptr, FALSE, FALSE, nullptr)) {}
    ~Session() { if (changed) CloseHandle(changed); }
  };
  std::wstring name;
  std::wstring security;
  Verify verify;
  Dispatch dispatch;
  size_t max_frame_bytes;
  Connection connection;
  Handle stopped{CreateEventW(nullptr, TRUE, FALSE, nullptr)};
  Handle changed{CreateEventW(nullptr, FALSE, FALSE, nullptr)};
  std::mutex mutex;
  std::string snapshot;
  uint64_t version = 0;
  // Disconnected peers must not accumulate unbounded platform-thread closures.
  std::shared_ptr<std::atomic<unsigned>> dispatches =
      std::make_shared<std::atomic<unsigned>>(0);
  std::thread worker;

  Impl(std::wstring n, std::wstring s, Verify v, Dispatch d, size_t limit, Connection c)
      : name(std::move(n)), security(std::move(s)), verify(std::move(v)), dispatch(std::move(d)),
        max_frame_bytes(limit), connection(std::move(c)) {}

  bool Write(HANDLE pipe, std::string frame) {
    frame += '\n';
    Handle done(CreateEventW(nullptr, TRUE, FALSE, nullptr));
    if (!done.value) return false;
    OVERLAPPED operation{};
    operation.hEvent = done.value;
    DWORD bytes = 0;
    if (!WriteFile(pipe, frame.data(), static_cast<DWORD>(frame.size()), &bytes, &operation)) {
      if (GetLastError() != ERROR_IO_PENDING) return false;
      HANDLE events[] = {stopped.value, done.value};
      if (WaitForMultipleObjects(2, events, FALSE, 2000) != WAIT_OBJECT_0 + 1) {
        Cancel(pipe, operation);
        return false;
      }
      if (!GetOverlappedResult(pipe, &operation, &bytes, FALSE)) return false;
    }
    return bytes == frame.size();
  }

  void Connected(HANDLE pipe) {
    auto session = std::make_shared<Session>();
    if (!session->changed) return;
    Handle read_done(CreateEventW(nullptr, TRUE, FALSE, nullptr));
    if (!read_done.value) return;
    OVERLAPPED read{};
    read.hEvent = read_done.value;
    std::vector<char> buffer(max_frame_bytes + 1);
    std::string frame;
    bool pending_read = false;
    bool awaiting = false;
    uint64_t sent_version = 0;
    ULONGLONG requested_at = 0;
    bool connected = true;
    std::weak_ptr<Session> lease = session;
    Current current = [lease] {
      const auto live = lease.lock();
      if (!live) return false;
      std::lock_guard<std::mutex> guard(live->mutex);
      return live->active;
    };
    if (connection) connection(true, current);
    while (connected && WaitForSingleObject(stopped.value, 0) != WAIT_OBJECT_0) {
      std::string update;
      {
        std::lock_guard<std::mutex> guard(mutex);
        if (sent_version != version) { update = snapshot; sent_version = version; }
      }
      if (!update.empty() && !Write(pipe, std::move(update))) break;
      std::string reply;
      {
        std::lock_guard<std::mutex> guard(session->mutex);
        reply.swap(session->reply);
      }
      if (!reply.empty()) {
        if (!Write(pipe, std::move(reply))) break;
        awaiting = false;
      }
      if (awaiting && GetTickCount64() - requested_at >= 15000) break;
      DWORD bytes = 0;
      bool received = false;
      if (!pending_read) {
        ResetEvent(read_done.value);
        if (ReadFile(pipe, buffer.data(), static_cast<DWORD>(buffer.size()), &bytes, &read)) {
          received = true;
        } else if (GetLastError() == ERROR_IO_PENDING) {
          pending_read = true;
        } else break;
      }
      if (!received) {
        HANDLE events[] = {stopped.value, changed.value, session->changed, read_done.value};
        const DWORD count = pending_read ? 4 : 3;
        const auto wait = WaitForMultipleObjects(count, events, FALSE, 500);
        if (wait == WAIT_OBJECT_0 || wait == WAIT_FAILED) break;
        if (pending_read && wait == WAIT_OBJECT_0 + 3) {
          pending_read = false;
          if (!GetOverlappedResult(pipe, &read, &bytes, FALSE)) break;
          received = true;
        }
      }
      if (!received) continue;
      if (!bytes) break;
      for (DWORD i = 0; i < bytes; ++i) {
        if (buffer[i] != '\n') {
          frame += buffer[i];
          if (frame.size() > max_frame_bytes) { connected = false; break; }
          continue;
        }
        const auto now = GetTickCount64();
        if (awaiting || !ValidFrame(frame, max_frame_bytes)) {
          connected = false;
          break;
        }
        if (dispatches->fetch_add(1) >= 8) {
          dispatches->fetch_sub(1);
          connected = false;
          break;
        }
        requested_at = now;
        awaiting = true;
        { std::lock_guard<std::mutex> guard(session->mutex); session->awaiting = true; }
        std::weak_ptr<Session> weak = session;
        const auto pending = dispatches;
        const auto settled = std::make_shared<std::atomic<bool>>(false);
        const auto limit = max_frame_bytes;
        dispatch(std::move(frame), [weak, pending, settled, limit](std::string response) {
          if (settled->exchange(true)) return;
          pending->fetch_sub(1);
          const auto live = weak.lock();
          if (!live) return;
          std::lock_guard<std::mutex> guard(live->mutex);
          if (!live->active || !live->awaiting) return;
          live->awaiting = false;
          // Invalid or absent Dart replies terminate the connection by deadline.
          if (ValidFrame(response, limit)) live->reply = std::move(response);
          SetEvent(live->changed);
        }, [weak] {
          const auto live = weak.lock();
          if (!live) return false;
          std::lock_guard<std::mutex> guard(live->mutex);
          return live->active;
        });
        frame.clear();
      }
    }
    if (pending_read) Cancel(pipe, read);
    {
      std::lock_guard<std::mutex> guard(session->mutex);
      session->active = false;
    }
    if (connection) connection(false, current);
  }

  void Run() {
    PSECURITY_DESCRIPTOR descriptor = nullptr;
    if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(security.c_str(), SDDL_REVISION_1,
                                                             &descriptor, nullptr)) return;
    SECURITY_ATTRIBUTES attributes{sizeof(SECURITY_ATTRIBUTES), descriptor, FALSE};
    while (WaitForSingleObject(stopped.value, 0) != WAIT_OBJECT_0) {
      Handle pipe(CreateNamedPipeW(name.c_str(), PIPE_ACCESS_DUPLEX | FILE_FLAG_OVERLAPPED |
          FILE_FLAG_FIRST_PIPE_INSTANCE, PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT |
          PIPE_REJECT_REMOTE_CLIENTS, 1, 8192, 8192, 0, &attributes));
      if (pipe.value == INVALID_HANDLE_VALUE) {
        if (WaitForSingleObject(stopped.value, 1000) == WAIT_OBJECT_0) break;
        continue;
      }
      Handle connected(CreateEventW(nullptr, TRUE, FALSE, nullptr));
      if (!connected.value) break;
      OVERLAPPED operation{};
      operation.hEvent = connected.value;
      bool admitted = ConnectNamedPipe(pipe.value, &operation) != FALSE;
      if (!admitted) {
        const auto error = GetLastError();
        admitted = error == ERROR_PIPE_CONNECTED;
        if (error == ERROR_IO_PENDING) {
          HANDLE events[] = {stopped.value, connected.value};
          if (WaitForMultipleObjects(2, events, FALSE, INFINITE) != WAIT_OBJECT_0 + 1) {
            Cancel(pipe.value, operation);
            break;
          }
          DWORD ignored = 0;
          admitted = GetOverlappedResult(pipe.value, &operation, &ignored, FALSE) != FALSE;
        }
      }
      if (admitted && verify(pipe.value)) Connected(pipe.value);
      DisconnectNamedPipe(pipe.value);
    }
    LocalFree(descriptor);
  }
};

Pipe::Pipe(std::wstring name, std::wstring security, Verify verify, Dispatch dispatch,
           size_t max_frame_bytes, Connection connection)
    : impl_(std::make_unique<Impl>(std::move(name), std::move(security),
                                 std::move(verify), std::move(dispatch),
                                 max_frame_bytes, std::move(connection))) {}
Pipe::~Pipe() { Stop(); }

bool Pipe::Publish(std::string snapshot) {
  if (!ValidFrame(snapshot, impl_->max_frame_bytes) || !impl_->stopped.value || !impl_->changed.value ||
      WaitForSingleObject(impl_->stopped.value, 0) == WAIT_OBJECT_0) return false;
  {
    std::lock_guard<std::mutex> guard(impl_->mutex);
    if (impl_->snapshot == snapshot) return true;
    impl_->snapshot = std::move(snapshot);
    ++impl_->version;
  }
  if (!impl_->worker.joinable()) impl_->worker = std::thread([this] { impl_->Run(); });
  SetEvent(impl_->changed.value);
  return true;
}

void Pipe::Stop() {
  if (impl_->stopped.value) SetEvent(impl_->stopped.value);
  if (impl_->worker.joinable()) impl_->worker.join();
}

namespace {
std::unique_ptr<Pipe> CreateFixedPipe(Dispatch dispatch, const wchar_t* endpoint,
                                    size_t limit, Pipe::Connection connection) {
  PSID package_sid = nullptr;
  if (FAILED(DeriveAppContainerSidFromAppContainerName(kPackage, &package_sid)) || !package_sid) return nullptr;
  const auto package = SidText(package_sid);
  FreeSid(package_sid);
  HANDLE token = nullptr;
  if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) return nullptr;
  Handle own(token);
  const auto user = TokenInfo(own.value, TokenUser);
  if (package.empty() || user.empty()) return nullptr;
  const auto owner = SidText(reinterpret_cast<const TOKEN_USER*>(user.data())->User.Sid);
  DWORD session = 0;
  if (owner.empty() || !ProcessIdToSessionId(GetCurrentProcessId(), &session)) return nullptr;
  const auto name = L"\\\\.\\pipe\\Sessions\\" + std::to_wstring(session) +
      L"\\AppContainerNamedObjects\\" + package + L"\\" + endpoint;
  const auto security = L"D:P(A;;GA;;;SY)(A;;GA;;;" + owner + L")(A;;GRGW;;;" + package +
      L")S:(ML;;NW;;;LW)";
  return std::make_unique<Pipe>(name, security, VerifyWidgetClient, std::move(dispatch),
                               limit, std::move(connection));
}
}  // namespace
std::unique_ptr<Pipe> CreateWidgetPipe(Dispatch dispatch) {
  return CreateFixedPipe(std::move(dispatch), L"doorlight-appearance-v1", kMaxFrameBytes, {});
}
std::unique_ptr<Pipe> CreateOverlayPipe(Dispatch dispatch, Pipe::Connection connection) {
  return CreateFixedPipe(std::move(dispatch), L"doorlight-overlay-v1", kMaxOverlayFrameBytes,
                         std::move(connection));
}
}  // namespace sybl::appearance
