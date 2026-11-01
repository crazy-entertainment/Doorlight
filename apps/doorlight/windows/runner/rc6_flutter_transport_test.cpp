#include <flutter/dart_project.h>
#include <flutter/encodable_value.h>
#include <flutter/flutter_engine.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <windows.h>

#include <algorithm>
#include <chrono>
#include <filesystem>
#include <iostream>
#include <memory>
#include <string>

#include "jami_channels.h"

// This target runs the production channels in a real headless Flutter engine.
// It does not use the application runner, start libjami, create an account,
// create a consent request, or submit OS input. The default host stays inactive.
int wmain(int argc, wchar_t** argv) {
  if (argc != 3) {
    std::cerr << "Usage: rc6_flutter_transport_test <asset-output> <icudtl.dat>\n";
    return 2;
  }
  const auto output = std::filesystem::absolute(argv[1]);
  const auto icu = std::filesystem::absolute(argv[2]);
  const auto assets = output / L"flutter_assets";
  const auto aot = output / L"windows" / L"app.so";
  if (!std::filesystem::is_directory(assets) ||
      !std::filesystem::is_regular_file(aot) ||
      !std::filesystem::is_regular_file(icu)) {
    std::cerr << "The isolated Flutter AOT bundle is incomplete.\n";
    return 2;
  }
  if (!SetDefaultDllDirectories(LOAD_LIBRARY_SEARCH_APPLICATION_DIR |
                               LOAD_LIBRARY_SEARCH_SYSTEM32)) {
    std::cerr << "DLL search setup failed.\n";
    return 2;
  }
  const HRESULT com = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  if (FAILED(com)) {
    std::cerr << "COM initialization failed.\n";
    return 2;
  }

  int exit_code = 1;
  {
    flutter::DartProject project(assets.wstring(), icu.wstring(), aot.wstring());
    flutter::FlutterEngine engine(project);
    auto channels = std::make_unique<JamiChannels>(
        engine.messenger(), nullptr, nullptr);
    bool complete = false;
    flutter::MethodChannel<flutter::EncodableValue> report(
        engine.messenger(), "syb.l/rc6-transport-test",
        &flutter::StandardMethodCodec::GetInstance());
    report.SetMethodCallHandler(
        [&](const flutter::MethodCall<flutter::EncodableValue>& call,
            std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
          if (call.method_name() == "destroyChannels") {
            channels.reset();
            result->Success();
            return;
          }
          if (call.method_name() == "createChannels") {
            if (channels) {
              result->Error("already_attached", "Channels are already attached.");
            } else {
              channels = std::make_unique<JamiChannels>(
                  engine.messenger(), nullptr, nullptr);
              result->Success();
            }
            return;
          }
          if (call.method_name() != "complete") {
            result->NotImplemented();
            return;
          }
          const auto* arguments = call.arguments();
          const auto* values = arguments
              ? std::get_if<flutter::EncodableMap>(arguments) : nullptr;
          bool passed = false;
          if (values) {
            const auto ok = values->find(flutter::EncodableValue("ok"));
            passed = ok != values->end() &&
                std::holds_alternative<bool>(ok->second) &&
                std::get<bool>(ok->second);
            const auto checks = values->find(flutter::EncodableValue("checks"));
            if (checks != values->end()) {
              if (const auto* list =
                      std::get_if<flutter::EncodableList>(&checks->second)) {
                for (const auto& item : *list) {
                  if (const auto* check = std::get_if<std::string>(&item))
                    std::cout << "PASS: " << *check << '\n';
                }
              }
            }
            const auto events =
                values->find(flutter::EncodableValue("authorityEvents"));
            if (events != values->end()) {
              if (const auto* count = std::get_if<int32_t>(&events->second))
                std::cout << "Authority events received: " << *count << '\n';
              else if (const auto* count = std::get_if<int64_t>(&events->second))
                std::cout << "Authority events received: " << *count << '\n';
            }
            const auto failure = values->find(flutter::EncodableValue("failure"));
            if (failure != values->end()) {
              if (const auto* text = std::get_if<std::string>(&failure->second))
                std::cerr << *text << '\n';
            }
          }
          exit_code = passed ? 0 : 1;
          complete = true;
          result->Success();
        });

    if (engine.Run()) {
      const auto deadline = std::chrono::steady_clock::now() +
          std::chrono::seconds(45);
      while (!complete && std::chrono::steady_clock::now() < deadline) {
        MSG message;
        while (PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE)) {
          TranslateMessage(&message);
          DispatchMessageW(&message);
        }
        const auto next = std::chrono::duration_cast<std::chrono::milliseconds>(
            engine.ProcessMessages());
        const auto wait_ms = std::clamp<int64_t>(next.count(), 0, 20);
        MsgWaitForMultipleObjects(0, nullptr, FALSE,
                                 static_cast<DWORD>(wait_ms), QS_ALLINPUT);
      }
      if (!complete) std::cerr << "Flutter transport test timed out.\n";
    } else {
      std::cerr << "Flutter engine startup failed.\n";
    }
    // Match production ownership: channels leave before their engine messenger.
    channels.reset();
    report.SetMethodCallHandler(nullptr);
    engine.ShutDown();
  }
  CoUninitialize();
  std::cout << (exit_code == 0 ? "PASS" : "FAIL")
            << ": RC6 actual Flutter engine transport; inactive host only.\n";
  return exit_code;
}
