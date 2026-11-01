#include "nearby_radio_lifetime.h"
#include <cassert>
#include <functional>
#include <stdexcept>

struct Handle {
  std::function<void()>* callback = nullptr;
  Handle(std::nullptr_t = nullptr) {}
  explicit Handle(std::function<void()>& fn) : callback(&fn) {}
  explicit operator bool() const { return callback != nullptr; }
  void Cancel() { (*callback)(); }
  void Close() { (*callback)(); }
};

int main() {
  using namespace sybl::nearby_radio;
  Handle handle;
  int calls = 0;
  std::function<void()> close = [&] {
    ++calls;
    assert(!handle);
    Close(handle);
    throw std::runtime_error("device disappeared");
  };
  handle = Handle(close);
  Close(handle);
  assert(!handle && calls == 1);
  std::function<void()> cancel = [&] {
    ++calls;
    assert(!handle);
    Cancel(handle);
    throw std::runtime_error("operation already finished");
  };
  handle = Handle(cancel);
  Cancel(handle);
  assert(!handle && calls == 2);
}
