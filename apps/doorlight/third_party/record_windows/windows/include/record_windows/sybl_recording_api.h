#pragma once

#include <stdint.h>

#ifdef FLUTTER_PLUGIN_IMPL
#define SYBL_RECORDING_EXPORT __declspec(dllexport)
#else
#define SYBL_RECORDING_EXPORT __declspec(dllimport)
#endif

extern "C" {
SYBL_RECORDING_EXPORT void RecordWindowsSybLConfigure(bool (*current)(uint64_t), void (*released)(uint64_t));
SYBL_RECORDING_EXPORT bool RecordWindowsSybLOffer(uint64_t owner, const wchar_t* path);
SYBL_RECORDING_EXPORT bool RecordWindowsSybLRenew(const wchar_t* path);
SYBL_RECORDING_EXPORT void RecordWindowsSybLSetForeground(bool foreground);
SYBL_RECORDING_EXPORT bool RecordWindowsSybLRevokeAndWait(uint32_t timeout_ms);
}
