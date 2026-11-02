#pragma once
#include <stdint.h>
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
/* All calls except dl_post run on the creating UI thread. Caller owns callback
   lifetime through dl_destroy. Font buffers are copied by dl_create. */
typedef int (__cdecl *dl_callback)(void* context, int event, intptr_t argument);
enum { DL_STARTED=1, DL_CLOSE_REQUESTED=2, DL_ACTION=3, DL_CANCEL=4,
       DL_LICENSES=5, DL_TIMER=6, DL_DISPATCH=7, DL_DESTROYED=8 };
enum { DL_HEADING=1, DL_STATUS=2, DL_FILENAME=3, DL_ACTION_BUTTON=4, DL_CANCEL_BUTTON=5 };
void* dl_create(dl_callback callback, void* context, int motion,
    const void* hanken, int hanken_length, const void* fraunces, int fraunces_length);
void* dl_hwnd(void* window);
void dl_show(void* window, int command);
int dl_run(void* window);
void dl_destroy(void* window);
void dl_set_text(void* window, int slot, const wchar_t* text);
void dl_set_button(void* window, int slot, int visible, int enabled);
void dl_progress(void* window, double fraction, int active);
int dl_post(void* window, uint64_t token);
void dl_timer(void* window, uint32_t id, uint32_t interval);
void dl_stop_timer(void* window, uint32_t id);
void dl_close(void* window);
#ifdef __cplusplus
}
#endif
