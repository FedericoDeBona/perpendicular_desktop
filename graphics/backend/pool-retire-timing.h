/* SPDX-License-Identifier: MIT
 * Candidate-only bounded timing of pool creation and retirement. */
#ifndef PERP_POOL_RETIRE_TIMING_H
#define PERP_POOL_RETIRE_TIMING_H
#include <stdbool.h>
#include "map-timing.h"
struct npt_pool_timing {
   struct npt_map_timing event;
   LONGLONG created;
};
static inline struct npt_pool_timing npt_pool_timing_begin(void)
{
   struct npt_pool_timing t = { .event = npt_map_timing_begin() };
   return t;
}
static inline void npt_pool_timing_created(struct npt_pool_timing *t)
{
   LARGE_INTEGER now;
   if (!t->event.handle) return;
   QueryPerformanceCounter(&now);
   t->created = now.QuadPart;
}
static inline void npt_pool_timing_end(struct npt_pool_timing *t,
                                     size_t request, size_t bytes, bool success)
{
   static volatile LONG emitted;
   LARGE_INTEGER end, frequency;
   if (!t->event.handle) return;
   QueryPerformanceCounter(&end);
   QueryPerformanceFrequency(&frequency);
   LONG n = InterlockedIncrement(&emitted);
   if (n <= 32) {
      WCHAR text[384];
      _snwprintf_s(text, 384, _TRUNCATE,
         L"Perpendicular pool retirement v18: n=%ld request=%llu bytes=%llu success=%u frequency=%lld start=%lld created=%lld end=%lld",
         n, (unsigned long long)request, (unsigned long long)bytes,
         (unsigned)success, frequency.QuadPart, t->event.start.QuadPart,
         t->created, end.QuadPart);
      EventWriteString(t->event.handle, 4, 2, text);
   } else if (n == 33) {
      EventWriteString(t->event.handle, 4, 2,
                       L"Perpendicular pool retirement v18: budget exhausted");
   }
   EventUnregister(t->event.handle);
   t->event.handle = 0;
}
#endif
