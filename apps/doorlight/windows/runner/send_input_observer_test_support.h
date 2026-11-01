#pragma once

// Test executables only. Intercept their own SendInput import; do not patch
// user32, another process, or the production runner. Join callback threads
// before destroying a scope. Nested scopes are sequential, not concurrent.
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>

#include <atomic>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <functional>
#include <utility>

namespace sybl::remote::test {

class ScopedSendInputObserver {
 public:
  using Function = UINT(WINAPI*)(UINT, LPINPUT, int);
  using Observer = std::function<UINT(UINT, LPINPUT, int)>;

  explicit ScopedSendInputObserver(Observer observer)
      : observer_(std::move(observer)), slot_(FindImport()) {
    Require(static_cast<bool>(observer_), "missing observer");
    previous_ = active_.load();
    original_ = previous_ ? previous_->original_
                         : reinterpret_cast<Function>(*slot_);
    Require(original_ != nullptr, "missing original SendInput");
    active_.store(this);
    previous_import_ = Replace(reinterpret_cast<void*>(&Dispatch));
    Require(*slot_ == reinterpret_cast<void*>(&Dispatch), "import not patched");
  }

  ~ScopedSendInputObserver() {
    Require(active_.load() == this, "observer scopes destroyed out of order");
    Require(Replace(previous_import_) == reinterpret_cast<void*>(&Dispatch),
            "SendInput import changed during test");
    Require(*slot_ == previous_import_, "SendInput import was not restored");
    active_.store(previous_);
  }

  ScopedSendInputObserver(const ScopedSendInputObserver&) = delete;
  ScopedSendInputObserver& operator=(const ScopedSendInputObserver&) = delete;

  Function original() const { return original_; }
  std::uint64_t calls() const { return calls_.load(); }
  static bool active() { return active_.load() != nullptr; }

 private:
  static void Require(bool condition, const char* message) {
    if (condition) return;
    std::fprintf(stderr, "SendInput observer: %s\n", message);
    std::abort();
  }

  static void** FindImport() {
    auto* base = reinterpret_cast<unsigned char*>(GetModuleHandleW(nullptr));
    Require(base != nullptr, "missing executable module");
    const auto* dos = reinterpret_cast<const IMAGE_DOS_HEADER*>(base);
    Require(dos->e_magic == IMAGE_DOS_SIGNATURE, "invalid executable DOS header");
    const auto* nt = reinterpret_cast<const IMAGE_NT_HEADERS*>(base + dos->e_lfanew);
    Require(nt->Signature == IMAGE_NT_SIGNATURE, "invalid executable PE header");
    const auto directory = nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT];
    Require(directory.VirtualAddress != 0 && directory.Size != 0,
            "executable has no import directory");
    auto* descriptor = reinterpret_cast<IMAGE_IMPORT_DESCRIPTOR*>(
        base + directory.VirtualAddress);
    for (; descriptor->Name != 0; ++descriptor) {
      const auto* library = reinterpret_cast<const char*>(base + descriptor->Name);
      if (_stricmp(library, "user32.dll") != 0) continue;
      Require(descriptor->OriginalFirstThunk != 0, "SendInput import has no names");
      auto* names = reinterpret_cast<IMAGE_THUNK_DATA*>(
          base + descriptor->OriginalFirstThunk);
      auto* addresses = reinterpret_cast<IMAGE_THUNK_DATA*>(
          base + descriptor->FirstThunk);
      for (; names->u1.AddressOfData != 0; ++names, ++addresses) {
        if (IMAGE_SNAP_BY_ORDINAL(names->u1.Ordinal)) continue;
        const auto* named = reinterpret_cast<const IMAGE_IMPORT_BY_NAME*>(
            base + names->u1.AddressOfData);
        if (std::strcmp(reinterpret_cast<const char*>(named->Name), "SendInput") == 0)
          return reinterpret_cast<void**>(&addresses->u1.Function);
      }
    }
    Require(false, "user32!SendInput import not found");
    return nullptr;
  }

  void* Replace(void* replacement) {
    DWORD previous_protection = 0;
    Require(VirtualProtect(slot_, sizeof(*slot_), PAGE_READWRITE,
                           &previous_protection) != FALSE,
            "cannot make import writable");
    void* previous = InterlockedExchangePointer(
        reinterpret_cast<PVOID volatile*>(slot_), replacement);
    DWORD ignored = 0;
    Require(VirtualProtect(slot_, sizeof(*slot_), previous_protection,
                           &ignored) != FALSE,
            "cannot restore import protection");
    return previous;
  }

  static UINT WINAPI Dispatch(UINT count, LPINPUT inputs, int size) {
    auto* scope = active_.load();
    Require(scope != nullptr, "input outside an observer scope");
    Require(count == 1 && inputs != nullptr && size == sizeof(INPUT),
            "unexpected SendInput arguments");
    ++scope->calls_;
    // There is no default forwarding. A physical probe must opt in itself.
    return scope->observer_(count, inputs, size);
  }

  Observer observer_;
  void** slot_ = nullptr;
  void* previous_import_ = nullptr;
  ScopedSendInputObserver* previous_ = nullptr;
  Function original_ = nullptr;
  std::atomic<std::uint64_t> calls_{0};
  inline static std::atomic<ScopedSendInputObserver*> active_{nullptr};
};

}  // namespace sybl::remote::test
