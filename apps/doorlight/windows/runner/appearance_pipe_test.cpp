#include "appearance_pipe.h"

#include <cassert>
#include <atomic>
#include <chrono>
#include <future>
#include <optional>
#include <string>
#include <thread>
#include <vector>
#include <mutex>

namespace {
class Client {
 public:
  explicit Client(const std::wstring& name) {
    const auto until = GetTickCount64() + 5000;
    do {
      handle = CreateFileW(name.c_str(), GENERIC_READ | GENERIC_WRITE, 0, nullptr,
                           OPEN_EXISTING, FILE_FLAG_OVERLAPPED, nullptr);
      if (handle != INVALID_HANDLE_VALUE) return;
      Sleep(10);
    } while (GetTickCount64() < until);
    assert(false && "test pipe did not become available");
  }
  ~Client() { if (handle != INVALID_HANDLE_VALUE) CloseHandle(handle); }
  bool Write(const std::string& text) {
    return Io(false, const_cast<char*>(text.data()), static_cast<DWORD>(text.size())).has_value();
  }
  std::optional<std::string> Read(size_t limit = sybl::appearance::kMaxFrameBytes) {
    std::string result;
    while (result.size() <= limit) {
      char next = 0;
      const auto count = Io(true, &next, 1);
      if (!count || !*count) return std::nullopt;
      if (next == '\n') return result;
      result += next;
    }
    return std::nullopt;
  }
  HANDLE handle = INVALID_HANDLE_VALUE;
 private:
  std::optional<DWORD> Io(bool read, char* data, DWORD size) {
    HANDLE event = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    assert(event);
    OVERLAPPED operation{};
    operation.hEvent = event;
    DWORD count = 0;
    bool ok = (read ? ReadFile(handle, data, size, &count, &operation)
                    : WriteFile(handle, data, size, &count, &operation)) != FALSE;
    if (!ok && GetLastError() == ERROR_IO_PENDING) {
      if (WaitForSingleObject(event, 5000) == WAIT_OBJECT_0) {
        ok = GetOverlappedResult(handle, &operation, &count, FALSE) != FALSE;
      } else {
        CancelIoEx(handle, &operation);
        GetOverlappedResult(handle, &operation, &count, TRUE);
      }
    }
    CloseHandle(event);
    return ok ? std::optional<DWORD>(count) : std::nullopt;
  }
};
std::wstring Name(const wchar_t* suffix) {
  return L"\\\\.\\pipe\\Doorlight.Appearance.Test." + std::to_wstring(GetCurrentProcessId()) + suffix;
}
// Synthetic fixtures carry no user settings; production uses its fixed package
// namespace/DACL plus VerifyWidgetClient, which is also exercised negatively.
constexpr wchar_t kFixtureSecurity[] = L"D:P(A;;GA;;;WD)";
}  // namespace

int main() {
  using namespace sybl::appearance;
  std::atomic<int> requests{0};
  {
    const auto name = Name(L".overlay");
    std::atomic<int> connections{0};
    Current lease;
    const std::string large(16384, 'a');
    Pipe pipe(name, kFixtureSecurity, [](HANDLE) { return true; },
      [&](std::string frame, Reply reply, Current current) {
        assert(current()); assert(frame == large); reply(large);
      }, kMaxOverlayFrameBytes, [&](bool connected, Current current) {
        if (connected) { assert(current()); lease = current; ++connections; }
        else { assert(!current()); ++connections; }
      });
    assert(pipe.Publish(large));
    assert(!pipe.Publish(std::string(kMaxOverlayFrameBytes + 1, 'x')));
    {
      Client client(name);
      assert(client.Read(kMaxOverlayFrameBytes) == large);
      assert(client.Write(large + '\n'));
      assert(client.Read(kMaxOverlayFrameBytes) == large);
    }
    pipe.Stop();
    assert(connections == 2);
    assert(lease && !lease());
  }
  {
    const auto name = Name(L".roundtrip");
    Pipe pipe(name, kFixtureSecurity, [](HANDLE) { return true; },
        [&](std::string frame, Reply reply, Current current) {
          assert(current());
          assert(frame == "{\"patch\":1}");
          ++requests;
          reply("{\"ok\":true}");
        });
    assert(pipe.Publish("{\"revision\":0}"));
    {
      Client client(name);
      assert(client.Read() == "{\"revision\":0}");
      assert(client.Write("{\"pat"));
      assert(client.Write("ch\":1}\n"));
      assert(client.Read() == "{\"ok\":true}");
      assert(pipe.Publish("{\"revision\":1}"));
      assert(client.Read() == "{\"revision\":1}");
    }
    {
      Client reconnect(name);
      assert(reconnect.Read() == "{\"revision\":1}");
      assert(reconnect.Write(std::string(kMaxFrameBytes + 1, 'x') + '\n'));
      assert(!reconnect.Read());
    }
    {
      Client invalid(name);
      assert(invalid.Read() == "{\"revision\":1}");
      assert(invalid.Write(std::string("\xff\n", 2)));
      assert(!invalid.Read());
    }
    assert(requests == 1);
    // Shutdown with a connected pending ReadFile must cancel and join.
    Client idle(name);
    assert(idle.Read() == "{\"revision\":1}");
    const auto started = GetTickCount64();
    pipe.Stop();
    assert(GetTickCount64() - started < 2000);
  }
  {
    const auto name = Name(L".admission");
    Pipe pipe(name, kFixtureSecurity, VerifyWidgetClient,
        [&](std::string, Reply, Current) { ++requests; });
    assert(pipe.Publish("{}"));
    Client unpackaged(name);
    assert(!unpackaged.Read());
    assert(requests == 1);
  }
  {
    const auto name = Name(L".late");
    std::promise<std::pair<Reply, Current>> dispatched;
    auto future = dispatched.get_future();
    Pipe pipe(name, kFixtureSecurity, [](HANDLE) { return true; },
        [&](std::string, Reply reply, Current current) {
          dispatched.set_value({std::move(reply), std::move(current)});
        });
    assert(pipe.Publish("{\"revision\":2}"));
    {
      Client old(name);
      assert(old.Read());
      assert(old.Write("{}\n"));
      assert(future.wait_for(std::chrono::seconds(5)) == std::future_status::ready);
    }
    assert(future.wait_for(std::chrono::seconds(5)) == std::future_status::ready);
    auto late = future.get();
    const auto until = GetTickCount64() + 5000;
    while (late.second() && GetTickCount64() < until) Sleep(5);
    assert(!late.second());
    late.first("{\"old\":true}");
    Client replacement(name);
    assert(replacement.Read() == "{\"revision\":2}");
    // Old completions cannot enter the replacement session; fresh publication can.
    assert(pipe.Publish("{\"revision\":3}"));
    assert(replacement.Read() == "{\"revision\":3}");
  }
  {
    Pipe idle(Name(L".connect"), kFixtureSecurity, [](HANDLE) { return true; },
              [](std::string, Reply, Current) {});
    assert(idle.Publish("{}"));
    Sleep(20);
    const auto started = GetTickCount64();
    idle.Stop();
    assert(GetTickCount64() - started < 2000);
  }
  {
    const auto name = Name(L".bounded");
    std::atomic<int> admitted{0};
    std::mutex guard;
    std::vector<Reply> held;
    Pipe pipe(name, kFixtureSecurity, [](HANDLE) { return true; },
        [&](std::string, Reply reply, Current) {
          std::lock_guard<std::mutex> lock(guard);
          held.push_back(std::move(reply));
          ++admitted;
        });
    assert(pipe.Publish("{}"));
    for (int i = 0; i < 8; ++i) {
      Client churn(name);
      assert(churn.Read() == "{}");
      assert(churn.Write("{}\n"));
      const auto until = GetTickCount64() + 5000;
      while (admitted.load() != i + 1 && GetTickCount64() < until) Sleep(5);
      assert(admitted == i + 1);
    }
    {
      Client limited(name);
      assert(limited.Read() == "{}");
      assert(limited.Write("{}\n"));
      assert(!limited.Read());
      assert(admitted == 8);
    }
    {
      std::lock_guard<std::mutex> lock(guard);
      for (auto& reply : held) reply({});
      held.clear();
    }
    Client recovered(name);
    assert(recovered.Read() == "{}");
    assert(recovered.Write("{}\n"));
    const auto until = GetTickCount64() + 5000;
    while (admitted.load() != 9 && GetTickCount64() < until) Sleep(5);
    assert(admitted == 9);
  }
  return 0;
}
