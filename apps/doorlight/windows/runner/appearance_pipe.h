#ifndef RUNNER_APPEARANCE_PIPE_H_
#define RUNNER_APPEARANCE_PIPE_H_

#include <windows.h>

#include <functional>
#include <memory>
#include <string>

namespace sybl::appearance {
constexpr size_t kMaxFrameBytes = 4096;
constexpr size_t kMaxOverlayFrameBytes = 256 * 1024;
using Reply = std::function<void(std::string)>;
using Current = std::function<bool()>;
using Dispatch = std::function<void(std::string, Reply, Current)>;

// Transport only. Dart owns protocol validation and canonical settings writes.
class Pipe {
 public:
  using Verify = std::function<bool(HANDLE)>;
  using Connection = std::function<void(bool, Current)>;
  Pipe(std::wstring name, std::wstring security, Verify verify, Dispatch dispatch,
       size_t max_frame_bytes = kMaxFrameBytes, Connection connection = {});
  ~Pipe();
  Pipe(const Pipe&) = delete;
  Pipe& operator=(const Pipe&) = delete;
  bool Publish(std::string snapshot);
  void Stop();

 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

// Fixed package/namespace; neither the widget nor Dart can select another peer.
std::unique_ptr<Pipe> CreateWidgetPipe(Dispatch dispatch);
std::unique_ptr<Pipe> CreateOverlayPipe(Dispatch dispatch, Pipe::Connection connection);
bool VerifyWidgetClient(HANDLE pipe);
}  // namespace sybl::appearance
#endif
