#include "nearby_radio.h"
#include "nearby_radio_mailbox.h"
#include "nearby_radio_lifetime.h"

#include <flutter/encodable_value.h>
#include <flutter/event_channel.h>
#include <flutter/event_stream_handler_functions.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <windows.h>
#include <winrt/Windows.Devices.Bluetooth.h>
#include <winrt/Windows.Devices.Bluetooth.Advertisement.h>
#include <winrt/Windows.Devices.Bluetooth.GenericAttributeProfile.h>
#include <winrt/Windows.Devices.Enumeration.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Storage.Streams.h>

#include <atomic>
#include <deque>
#include <functional>
#include <map>
#include <mutex>
#include <utility>

namespace {
using namespace winrt;
using namespace Windows::Foundation;
using namespace Windows::Devices::Bluetooth;
using namespace Windows::Devices::Bluetooth::Advertisement;
using namespace Windows::Devices::Bluetooth::GenericAttributeProfile;
using namespace Windows::Storage::Streams;
using sybl::nearby_radio::Bytes;
using sybl::nearby_radio::Clock;
using sybl::nearby_radio::Cancel;
using sybl::nearby_radio::Close;
using Value = flutter::EncodableValue;
using Reply = std::unique_ptr<flutter::MethodResult<Value>>;
using namespace std::chrono_literals;

constexpr guid kService{0x6a5ed9b0, 0x067d, 0x4f88, {0xb2, 0x7c, 0x5f, 0x3f, 0x45, 0x23, 0x9e, 0xf0}};
constexpr guid kAnnouncement{0x6a5ed9b1, 0x067d, 0x4f88, {0xb2, 0x7c, 0x5f, 0x3f, 0x45, 0x23, 0x9e, 0xf0}};
constexpr guid kEvent{0x6a5ed9b2, 0x067d, 0x4f88, {0xb2, 0x7c, 0x5f, 0x3f, 0x45, 0x23, 0x9e, 0xf0}};
constexpr UINT kDispatch = WM_APP + 0x4a1;
constexpr UINT_PTR kTimer = 1;

// Fixed stage/status only: never log identities, addresses or packet contents.
void Trace(const char* stage, int status = 0) {
  OutputDebugStringA((std::string("[sybl/nearby] ") + stage + " " +
                     std::to_string(status) + "\n").c_str());
}

void Answer(Reply& reply, bool value) {
  if (reply) {
    auto owned = std::move(reply);
    owned->Success(Value(value));
  }
}

struct Peer {
  std::uint64_t address = 0;
  BluetoothAddressType address_type = BluetoothAddressType::Unspecified;
  bool alive = true;
  bool busy = true;
  Clock::time_point deadline;
  Clock::time_point next_read;
  BluetoothLEDevice device{nullptr};
  GattDeviceService service{nullptr};
  GattSession session{nullptr};
  GattCharacteristic announcement{nullptr};
  GattCharacteristic event{nullptr};
  IAsyncInfo operation{nullptr};

  void Stop() noexcept {
    if (!std::exchange(alive, false)) return;
    Cancel(operation);
    announcement = nullptr;
    event = nullptr;
    Close(session);
    Close(service);
    Close(device);
  }
};

struct RadioState : std::enable_shared_from_this<RadioState> {
  // UI-thread fields; callbacks reach them only through Post or captured apartment continuations.
  HWND window = nullptr;
  bool closed = false;
  bool running = false;
  bool peripheral = false;
  std::uint64_t generation = 0;
  std::uint64_t server_generation = 0;
  BluetoothLEAdvertisementWatcher watcher{nullptr};
  event_token received_token{};
  event_token stopped_token{};
  GattServiceProvider provider{nullptr};
  GattLocalCharacteristic local_announcement{nullptr};
  GattLocalCharacteristic local_event{nullptr};
  event_token announcement_token{};
  event_token event_token_{};
  event_token provider_token{};
  Reply start_reply;
  Reply server_reply;
  IAsyncInfo start_operation{nullptr};
  IAsyncInfo server_operation{nullptr};
  Clock::time_point start_deadline;
  Clock::time_point server_deadline;
  std::map<std::uint64_t, std::shared_ptr<Peer>> peers;
  std::map<std::uint64_t, Clock::time_point> history;
  std::unique_ptr<flutter::EventSink<Value>> sink;

  std::mutex queue_mutex;
  std::deque<std::function<void(RadioState&)>> queue;
  std::map<std::uint64_t, BluetoothAddressType> candidates;
  HWND post_window = nullptr;
  bool dispatch_pending = false;
  std::atomic<std::uint64_t> scan_generation{0};
  std::mutex mailbox_mutex;
  sybl::nearby_radio::Mailbox mailbox;
  std::uint64_t mailbox_generation = 0;
  std::atomic<unsigned> pending_reads{0};

  static LRESULT CALLBACK WindowProc(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) noexcept {
    if (message == WM_NCCREATE) {
      auto* create = reinterpret_cast<CREATESTRUCTW*>(lparam);
      SetWindowLongPtrW(hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(create->lpCreateParams));
    }
    auto* state = reinterpret_cast<RadioState*>(GetWindowLongPtrW(hwnd, GWLP_USERDATA));
    if (state) {
      try {
        if (message == kDispatch) { state->Drain(); return 0; }
        if (message == WM_TIMER && wparam == kTimer) { state->Tick(); return 0; }
      } catch (...) { state->Stop(); }
    }
    return DefWindowProcW(hwnd, message, wparam, lparam);
  }

  bool CreateDispatchWindow() {
    WNDCLASSW klass{};
    klass.lpfnWndProc = WindowProc;
    klass.hInstance = GetModuleHandleW(nullptr);
    klass.lpszClassName = L"SybLNearbyRadioDispatch";
    if (!RegisterClassW(&klass) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS) return false;
    window = CreateWindowExW(0, klass.lpszClassName, L"", 0, 0, 0, 0, 0,
                             HWND_MESSAGE, nullptr, klass.hInstance, this);
    if (!window) return false;
    post_window = window;
    if (!SetTimer(window, kTimer, 250, nullptr)) {
      post_window = nullptr;
      DestroyWindow(window);
      window = nullptr;
      return false;
    }
    return true;
  }

  void Post(std::function<void(RadioState&)> fn) {
    std::lock_guard lock(queue_mutex);
    if (!post_window || queue.size() >= 32) return;
    queue.push_back(std::move(fn));
    Wake();
  }

  // queue_mutex is held; one OS message covers the bounded pending work.
  void Wake() {
    if (dispatch_pending) return;
    dispatch_pending = PostMessageW(post_window, kDispatch, 0, 0) != FALSE;
    if (!dispatch_pending) { queue.clear(); candidates.clear(); }
  }

  void Candidate(std::uint64_t epoch, std::uint64_t address, BluetoothAddressType type) {
    std::lock_guard lock(queue_mutex);
    if (!post_window || scan_generation != epoch || candidates.size() >= 64) return;
    candidates.emplace(address, type);
    Wake();
  }

  void Drain() {
    std::deque<std::function<void(RadioState&)>> work;
    std::map<std::uint64_t, BluetoothAddressType> heard;
    {
      std::lock_guard lock(queue_mutex);
      dispatch_pending = false;
      work.swap(queue);
      heard.swap(candidates);
    }
    for (auto& fn : work) { if (!closed) fn(*this); }
    if (!running || closed) return;
    const auto now = Clock::now();
    for (const auto& [address, type] : heard) {
      if (peers.size() >= 4) break;
      if (peers.contains(address) || history.contains(address)) continue;
      if (history.size() >= 64) break;
      history.emplace(address, now);
      auto peer = std::make_shared<Peer>();
      peer->address = address;
      peer->address_type = type;
      // Windows queues GATT discovery; a single request can take seven seconds.
      peer->deadline = now + 30s;
      peers.emplace(address, peer);
      Connect(shared_from_this(), peer, generation);
    }
  }

  void Tick() {
    const auto now = Clock::now();
    if (start_reply && now >= start_deadline) {
      ++generation;
      Cancel(start_operation);
      Answer(start_reply, false);
    }
    if (server_reply && now >= server_deadline) Hide();
    for (auto it = history.begin(); it != history.end();) {
      if (now - it->second >= 6s) it = history.erase(it);
      else ++it;
    }
    for (auto it = peers.begin(); it != peers.end();) {
      auto peer = it->second;
      if (!peer->alive || (peer->busy && now >= peer->deadline)) {
        peer->Stop();
        it = peers.erase(it);
      } else {
        ++it;
        if (!peer->busy && now >= peer->next_read) {
          peer->busy = true;
          peer->deadline = now + 4s;
          Poll(shared_from_this(), peer, generation);
        }
      }
    }
  }

  void Hide() noexcept {
    ++server_generation;
    {
      std::lock_guard lock(mailbox_mutex);
      mailbox_generation = server_generation;
      mailbox.Hide();
    }
    Cancel(server_operation);
    Answer(server_reply, false);
    try { if (local_announcement) local_announcement.ReadRequested(announcement_token); } catch (...) {}
    try { if (local_event) local_event.ReadRequested(event_token_); } catch (...) {}
    try {
      if (provider) {
        provider.AdvertisementStatusChanged(provider_token);
        provider.StopAdvertising();
      }
    } catch (...) {}
    local_announcement = nullptr;
    local_event = nullptr;
    provider = nullptr;
  }

  void Stop() noexcept {
    running = false;
    scan_generation = 0;
    peripheral = false;
    ++generation;
    Cancel(start_operation);
    Answer(start_reply, false);
    Hide();
    try {
      if (watcher) {
        watcher.Received(received_token);
        watcher.Stopped(stopped_token);
        watcher.Stop();
      }
    } catch (...) {}
    watcher = nullptr;
    for (auto& [_, peer] : peers) peer->Stop();
    peers.clear();
    history.clear();
    {
      std::lock_guard lock(queue_mutex);
      candidates.clear();
      queue.clear();
    }
  }

  void Shutdown() noexcept {
    Stop();
    closed = true;
    sink.reset();
    {
      std::lock_guard lock(queue_mutex);
      post_window = nullptr;
      dispatch_pending = false;
      candidates.clear();
      queue.clear();
    }
    if (window) {
      KillTimer(window, kTimer);
      SetWindowLongPtrW(window, GWLP_USERDATA, 0);
      DestroyWindow(window);
      window = nullptr;
    }
  }

  bool Current(const std::shared_ptr<Peer>& peer, std::uint64_t epoch) const {
    return !closed && running && generation == epoch && peer->alive;
  }

  static fire_and_forget Start(std::shared_ptr<RadioState> state, std::uint64_t epoch) {
    try {
      auto operation = BluetoothAdapter::GetDefaultAsync();
      state->start_operation = operation;
      auto adapter = co_await operation;
      if (state->closed || state->generation != epoch) co_return;
      state->start_operation = nullptr;
      if (!adapter || !adapter.IsLowEnergySupported()) {
        Answer(state->start_reply, false);
        co_return;
      }
      state->peripheral = adapter.IsPeripheralRoleSupported();
      Trace("adapter_peripheral", state->peripheral);
      BluetoothLEAdvertisementWatcher watcher;
      watcher.ScanningMode(BluetoothLEScanningMode::Passive);
      watcher.AdvertisementFilter().Advertisement().ServiceUuids().Append(kService);
      const std::weak_ptr<RadioState> weak = state;
      state->received_token = watcher.Received([weak, epoch](auto const&, BluetoothLEAdvertisementReceivedEventArgs const& args) {
        try {
          if (auto owned = weak.lock()) {
            // Native filtering keeps unrelated advertising out of the bounded UI queue.
            owned->Candidate(epoch, args.BluetoothAddress(), args.BluetoothAddressType());
          }
        } catch (...) {}
      });
      state->stopped_token = watcher.Stopped([weak, epoch](auto const&, auto const& args) {
        Trace("scan_stopped", static_cast<int>(args.Error()));
        if (auto owned = weak.lock()) owned->Post([epoch](RadioState& current) {
          if (current.generation == epoch) current.Stop();
        });
      });
      state->watcher = watcher;
      state->running = true;
      state->scan_generation = epoch;
      watcher.Start();
      Trace("scan_started", static_cast<int>(watcher.Status()));
      Answer(state->start_reply, true);
    } catch (...) {
      Trace("scan_exception", to_hresult().value);
      if (state->generation == epoch) state->Stop();
    }
  }

  static fire_and_forget Connect(std::shared_ptr<RadioState> state,
                                 std::shared_ptr<Peer> peer, std::uint64_t epoch) {
    try {
      Trace("connect");
      auto device_op = BluetoothLEDevice::FromBluetoothAddressAsync(peer->address, peer->address_type);
      peer->operation = device_op;
      auto device = co_await device_op;
      if (!state->Current(peer, epoch)) { Close(device); co_return; }
      peer->device = device;
      if (!device) { peer->Stop(); co_return; }
      auto service_op = device.GetGattServicesForUuidAsync(kService, BluetoothCacheMode::Uncached);
      peer->operation = service_op;
      auto services = co_await service_op;
      Trace("services", static_cast<int>(services.Status()));
      if (!state->Current(peer, epoch) || services.Status() != GattCommunicationStatus::Success ||
          services.Services().Size() != 1) {
        for (auto item : services.Services()) Close(item);
        peer->Stop();
        co_return;
      }
      peer->service = services.Services().GetAt(0);
      auto access_op = peer->service.RequestAccessAsync();
      peer->operation = access_op;
      const auto access = co_await access_op;
      Trace("service_access", static_cast<int>(access));
      if (!state->Current(peer, epoch) ||
          access != Windows::Devices::Enumeration::DeviceAccessStatus::Allowed) {
        peer->Stop(); co_return;
      }
      peer->session = peer->service.Session();
      auto announce_op = peer->service.GetCharacteristicsForUuidAsync(kAnnouncement, BluetoothCacheMode::Uncached);
      peer->operation = announce_op;
      auto announce_result = co_await announce_op;
      Trace("announcement_characteristic", static_cast<int>(announce_result.Status()));
      if (!state->Current(peer, epoch) || announce_result.Status() != GattCommunicationStatus::Success ||
          announce_result.Characteristics().Size() != 1) { peer->Stop(); co_return; }
      peer->announcement = announce_result.Characteristics().GetAt(0);
      auto event_op = peer->service.GetCharacteristicsForUuidAsync(kEvent, BluetoothCacheMode::Uncached);
      peer->operation = event_op;
      auto event_result = co_await event_op;
      Trace("event_characteristic", static_cast<int>(event_result.Status()));
      if (!state->Current(peer, epoch) || event_result.Status() != GattCommunicationStatus::Success ||
          event_result.Characteristics().Size() != 1) { peer->Stop(); co_return; }
      peer->event = event_result.Characteristics().GetAt(0);
      if ((peer->announcement.CharacteristicProperties() & GattCharacteristicProperties::Read) == GattCharacteristicProperties::None ||
          (peer->event.CharacteristicProperties() & GattCharacteristicProperties::Read) == GattCharacteristicProperties::None) {
        peer->Stop(); co_return;
      }
      peer->operation = nullptr;
      peer->busy = false;
      peer->next_read = Clock::now();
      Trace("connected");
    } catch (...) { Trace("connect_exception", to_hresult().value); peer->Stop(); }
  }

  static fire_and_forget Poll(std::shared_ptr<RadioState> state,
                              std::shared_ptr<Peer> peer, std::uint64_t epoch) {
    try {
      for (auto characteristic : {peer->announcement, peer->event}) {
        auto operation = characteristic.ReadValueAsync(BluetoothCacheMode::Uncached);
        peer->operation = operation;
        auto read = co_await operation;
        if (!state->Current(peer, epoch)) co_return;
        if (read.Status() != GattCommunicationStatus::Success) {
          Trace("read_failed", static_cast<int>(read.Status())); peer->Stop(); co_return;
        }
        const auto buffer = read.Value();
        if (!buffer || buffer.Length() == 0) continue;
        if (buffer.Length() < 5 || buffer.Length() > 512) { peer->Stop(); co_return; }
        Bytes frame(buffer.Length());
        DataReader::FromBuffer(buffer).ReadBytes(frame);
        if (state->sink) {
          state->sink->Success(Value(flutter::EncodableMap{
              {Value("source"), Value("ble:" + std::to_string(peer->address))},
              {Value("frame"), Value(std::move(frame))}}));
        }
      }
      peer->operation = nullptr;
      peer->busy = false;
      peer->next_read = Clock::now() + 750ms;
    } catch (...) { peer->Stop(); }
  }

  static fire_and_forget Read(std::shared_ptr<RadioState> state, std::uint64_t epoch,
                              bool announcement, GattReadRequestedEventArgs args) {
    if (state->pending_reads.fetch_add(1) >= 8) {
      --state->pending_reads;
      co_return;
    }
    struct Counter {
      std::atomic<unsigned>& count;
      ~Counter() { --count; }
    } counter{state->pending_reads};
    Deferral deferral{nullptr};
    try {
      deferral = args.GetDeferral();
      auto request = co_await args.GetRequestAsync();
      if (request) {
        const auto id = args.Session().DeviceId().Id();
        Bytes bytes;
        std::uint8_t error = 0x02;
        {
          std::lock_guard lock(state->mailbox_mutex);
          if (state->mailbox_generation == epoch) {
            error = state->mailbox.Read(std::wstring(id), announcement, request.Offset(),
                                       request.Length(), Clock::now(), bytes);
          }
          // Serialize the reply with Hide: no later callback can publish cleared identity data.
          if (error) request.RespondWithProtocolError(error);
          else {
            DataWriter writer;
            writer.WriteBytes(bytes);
            request.RespondWithValue(writer.DetachBuffer());
            state->mailbox.Served(std::wstring(id), Clock::now());
          }
        }
      }
    } catch (...) {}
    try { if (deferral) deferral.Complete(); } catch (...) {}
  }

  static fire_and_forget Publish(std::shared_ptr<RadioState> state,
                                 std::uint64_t epoch, std::uint64_t server_epoch) {
    auto current = [&] {
      return !state->closed && state->running && state->generation == epoch &&
             state->server_generation == server_epoch;
    };
    try {
      auto create_op = GattServiceProvider::CreateAsync(kService);
      state->server_operation = create_op;
      auto created = co_await create_op;
      Trace("server_created", static_cast<int>(created.Error()));
      if (!current()) co_return;
      if (created.Error() != BluetoothError::Success) { state->Hide(); co_return; }
      auto provider = created.ServiceProvider();
      GattLocalCharacteristicParameters parameters;
      parameters.CharacteristicProperties(GattCharacteristicProperties::Read);
      parameters.ReadProtectionLevel(GattProtectionLevel::Plain);
      auto announcement_op = provider.Service().CreateCharacteristicAsync(kAnnouncement, parameters);
      state->server_operation = announcement_op;
      auto announcement = co_await announcement_op;
      if (!current()) co_return;
      if (announcement.Error() != BluetoothError::Success) { state->Hide(); co_return; }
      auto event_op = provider.Service().CreateCharacteristicAsync(kEvent, parameters);
      state->server_operation = event_op;
      auto event = co_await event_op;
      if (!current()) co_return;
      if (event.Error() != BluetoothError::Success) { state->Hide(); co_return; }
      const std::weak_ptr<RadioState> weak = state;
      state->local_announcement = announcement.Characteristic();
      state->local_event = event.Characteristic();
      state->announcement_token = state->local_announcement.ReadRequested(
          [weak, server_epoch](auto const&, GattReadRequestedEventArgs const& args) {
            if (auto owned = weak.lock()) Read(std::move(owned), server_epoch, true, args);
          });
      state->event_token_ = state->local_event.ReadRequested(
          [weak, server_epoch](auto const&, GattReadRequestedEventArgs const& args) {
            if (auto owned = weak.lock()) Read(std::move(owned), server_epoch, false, args);
          });
      state->provider = provider;
      state->provider_token = provider.AdvertisementStatusChanged(
          [weak, server_epoch](auto const&, GattServiceProviderAdvertisementStatusChangedEventArgs const& args) {
            Trace("advertising_status", static_cast<int>(args.Status()));
            Trace("advertising_error", static_cast<int>(args.Error()));
            if (args.Status() != GattServiceProviderAdvertisementStatus::Aborted) return;
            if (auto owned = weak.lock()) owned->Post([server_epoch](RadioState& active) {
              if (active.server_generation == server_epoch) active.Hide();
            });
          });
      GattServiceProviderAdvertisingParameters advertising;
      // Reveal consent includes the Windows Bluetooth friendly name carried by this API.
      advertising.IsDiscoverable(true);
      advertising.IsConnectable(true);
      provider.StartAdvertising(advertising);
      state->server_operation = nullptr;
      Answer(state->server_reply, true);
    } catch (...) {
      Trace("advertising_exception", to_hresult().value);
      if (current()) state->Hide();
    }
  }
};
}  // namespace

struct NearbyRadio::Impl {
  std::shared_ptr<RadioState> state = std::make_shared<RadioState>();
  flutter::MethodChannel<Value> methods;
  flutter::EventChannel<Value> events;

  explicit Impl(flutter::BinaryMessenger* messenger)
      : methods(messenger, "syb.l/nearby_radio", &flutter::StandardMethodCodec::GetInstance()),
        events(messenger, "syb.l/nearby_radio_events", &flutter::StandardMethodCodec::GetInstance()) {
    state->CreateDispatchWindow();
    const std::weak_ptr<RadioState> weak = state;
    events.SetStreamHandler(std::make_unique<flutter::StreamHandlerFunctions<Value>>(
        [weak](const Value*, std::unique_ptr<flutter::EventSink<Value>>&& sink)
            -> std::unique_ptr<flutter::StreamHandlerError<Value>> {
          if (auto owned = weak.lock()) owned->sink = std::move(sink);
          return nullptr;
        },
        [weak](const Value*) -> std::unique_ptr<flutter::StreamHandlerError<Value>> {
          if (auto owned = weak.lock()) { owned->Stop(); owned->sink.reset(); }
          return nullptr;
        }));
    methods.SetMethodCallHandler([weak](const flutter::MethodCall<Value>& call, Reply result) {
      const auto state = weak.lock();
      if (!state || state->closed || !state->window) { result->Success(Value(false)); return; }
      try {
        if (call.method_name() == "stop") {
          state->Stop();
          result->Success(Value(true));
          return;
        }
        if (call.method_name() == "start") {
          if (state->running) { result->Success(Value(true)); return; }
          state->Stop();
          state->start_reply = std::move(result);
          state->start_deadline = Clock::now() + 4s;
          RadioState::Start(state, state->generation);
          return;
        }
        if (call.method_name() != "send") { result->NotImplemented(); return; }
        const auto* args = call.arguments() ? std::get_if<flutter::EncodableMap>(call.arguments()) : nullptr;
        if (!args || args->size() != 2) { result->Success(Value(false)); return; }
        const auto data_it = args->find(Value("data"));
        const auto kind_it = args->find(Value("kind"));
        const auto* bytes = data_it != args->end() ? std::get_if<Bytes>(&data_it->second) : nullptr;
        const auto* kind = kind_it != args->end() ? std::get_if<std::string>(&kind_it->second) : nullptr;
        if (!bytes || !kind || bytes->empty() || bytes->size() > 508 ||
            (*kind != "announce" && *kind != "ping" && *kind != "missile" && *kind != "bye")) {
          result->Success(Value(false)); return;
        }
        if (*kind == "bye") { state->Hide(); result->Success(Value(true)); return; }
        if (!state->running || !state->peripheral) { result->Success(Value(false)); return; }
        bool accepted;
        {
          std::lock_guard lock(state->mailbox_mutex);
          accepted = state->mailbox.Put(*bytes, *kind == "announce" || *kind == "ping", Clock::now(), *kind == "ping");
        }
        if (!accepted) { result->Success(Value(false)); return; }
        if (state->provider || state->server_reply) { result->Success(Value(true)); return; }
        state->server_reply = std::move(result);
        state->server_deadline = Clock::now() + 4s;
        RadioState::Publish(state, state->generation, state->server_generation);
      } catch (...) {
        state->Hide();
        if (result) result->Success(Value(false));
      }
    });
  }

  ~Impl() {
    methods.SetMethodCallHandler(nullptr);
    events.SetStreamHandler(nullptr);
    state->Shutdown();
  }
};

NearbyRadio::NearbyRadio(flutter::BinaryMessenger* messenger)
    : impl_(std::make_unique<Impl>(messenger)) {}
NearbyRadio::~NearbyRadio() = default;
void NearbyRadio::Stop() noexcept { if (impl_) impl_->state->Stop(); }
