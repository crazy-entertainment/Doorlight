#ifndef RUNNER_NEARBY_RADIO_H_
#define RUNNER_NEARBY_RADIO_H_

#include <memory>

namespace flutter { class BinaryMessenger; }

class NearbyRadio {
 public:
  explicit NearbyRadio(flutter::BinaryMessenger* messenger);
  ~NearbyRadio();
  NearbyRadio(const NearbyRadio&) = delete;
  NearbyRadio& operator=(const NearbyRadio&) = delete;
  void Stop() noexcept;

 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

#endif
