/* SPDX-License-Identifier: MIT
 * Opt-in diagnostic build only. Each registration is owned by this call;
 * no callback or provider handle survives a DLL unload. No pixel data. */
#ifndef PERP_MAP_TIMING_H
#define PERP_MAP_TIMING_H
#if defined(_WIN32)
#include <windows.h>
#include <evntprov.h>
#include <stdio.h>
struct npt_map_timing {
   REGHANDLE handle;
   LARGE_INTEGER start;
   LONGLONG phase[4];
};
static inline struct npt_map_timing npt_map_timing_begin(void)
{
   struct npt_map_timing t = {0};
   static const GUID provider = {0x48dce1b6,0xe965,0x4e8a,
      {0xb5,0xfa,0xd9,0xcb,0x52,0x65,0x72,0x12}};
   if (EventRegister(&provider, NULL, NULL, &t.handle) != ERROR_SUCCESS)
      t.handle = 0;
   if (t.handle && !EventProviderEnabled(t.handle, 4, 2)) {
      EventUnregister(t.handle);
      t.handle = 0;
   }
   if (t.handle) QueryPerformanceCounter(&t.start);
   return t;
}
static inline void npt_map_timing_mark(struct npt_map_timing *t, unsigned phase)
{
   LARGE_INTEGER now;
   if (!t->handle) return;
   QueryPerformanceCounter(&now);
   t->phase[phase] = now.QuadPart;
}
static inline void npt_map_timing_end(struct npt_map_timing *t, void *resource,
      unsigned subresource, unsigned type, unsigned flags, HRESULT result,
      unsigned width, unsigned height, unsigned format)
{
   static volatile LONG emitted;
   LARGE_INTEGER end, frequency;
   if (!t->handle) return;
   QueryPerformanceCounter(&end);
   QueryPerformanceFrequency(&frequency);
   /* Three early records qualify the loaded candidate even if no slow Map
    * occurs. Afterwards only >=2ms calls, at most64 total per process/TU.
    * The budget is independent of the existing first-fault records. */
   LONG current = InterlockedCompareExchange(&emitted, 0, 0);
   if (current < 3 || (end.QuadPart - t->start.QuadPart) * 1000 >= frequency.QuadPart * 2) {
      LONG count = InterlockedIncrement(&emitted);
      if (count <= 64) {
         WCHAR text[512];
         _snwprintf_s(text, 512, _TRUNCATE,
            L"Perpendicular map timing v18: n=%ld resource=%p sub=%u map=%u flags=0x%x hr=0x%08x size=%ux%u fmt=%u frequency=%lld start=%lld shmem=%lld slot=%lld visible=%lld dispatch=%lld end=%lld",
            count, resource, subresource, type, flags, (UINT)result,
            width, height, format, frequency.QuadPart, t->start.QuadPart,
            t->phase[0], t->phase[1], t->phase[2], t->phase[3], end.QuadPart);
         EventWriteString(t->handle, 4, 2, text);
      } else if (count == 65) {
         EventWriteString(t->handle, 4, 2, L"Perpendicular map timing v18: budget exhausted");
      }
   }
   EventUnregister(t->handle);
   t->handle = 0;
}
#else
struct npt_map_timing { int unused; };
static inline struct npt_map_timing npt_map_timing_begin(void)
{ struct npt_map_timing t = {0}; return t; }
static inline void npt_map_timing_mark(struct npt_map_timing *t, unsigned p) { (void)t; (void)p; }
#define npt_map_timing_end(...) ((void)0)
#endif
#endif
