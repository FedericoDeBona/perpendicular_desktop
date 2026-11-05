/* Exercise the actual pinned pool implementation with a bounded fake renderer.
 * clang -std=c11 -DPERP_SHMEM_POOL_SOURCE='"/private/source/.../npt_shmem_pool.c"'
 *   tests/NativeShmemPoolChecks.c -o /private/pool-check && /private/pool-check
 * Single-threaded allocation/failure/ownership checks; not a GPU benchmark. */
#include <assert.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define NPT_SHMEM_POOL_H
#define PERP_TRITON_FAULT_TRACE_H
#define _WIN32 1
#define tritonTraceAllocation(...) ((void)0)
#define npt_log(...) ((void)0)
typedef int mtx_t;
#define mtx_plain 0
#define mtx_init(...) ((void)0)
#define mtx_destroy(...) ((void)0)
#define mtx_lock(...) ((void)0)
#define mtx_unlock(...) ((void)0)
struct npt_renderer {
   size_t limit;
   unsigned calls, live;
#ifdef PERP_ASYNC_POOL_RETIRE
   unsigned async_calls, deferred_count;
   struct npt_renderer_shmem *deferred[8];
#endif
};
struct npt_renderer_shmem { unsigned refs; size_t size; };
struct npt_shmem_pool {
   mtx_t mutex;
   size_t min_alloc_size;
   struct npt_renderer_shmem *shmem;
   size_t size, used;
};
static struct npt_renderer_shmem *
npt_renderer_shmem_create(struct npt_renderer *r, size_t size)
{
   ++r->calls;
   if (size > r->limit) return NULL;
   struct npt_renderer_shmem *s = malloc(sizeof(*s));
   assert(s);
   *s = (struct npt_renderer_shmem){1, size};
   ++r->live;
   return s;
}
static struct npt_renderer_shmem *
npt_renderer_shmem_ref(struct npt_renderer *r, struct npt_renderer_shmem *s)
{
   (void)r; ++s->refs; return s;
}
static void
npt_renderer_shmem_unref(struct npt_renderer *r, struct npt_renderer_shmem *s)
{
   if (!--s->refs) { --r->live; free(s); }
}
#ifdef PERP_ASYNC_POOL_RETIRE
/* Model the existing reaper's ownership boundary, without timing Windows. */
#define PERP_POOL_RETIRE_TIMING_H
struct npt_pool_timing { unsigned unused; };
#define npt_pool_timing_begin() ((struct npt_pool_timing){0})
#define npt_pool_timing_created(t) ((void)(t))
#define npt_pool_timing_end(t, ...) ((void)(t))
static void
npt_renderer_shmem_unref_async(struct npt_renderer *r,
                               struct npt_renderer_shmem *s)
{
   ++r->async_calls;
   if (!--s->refs) {
      assert(r->deferred_count < 8);
      r->deferred[r->deferred_count++] = s;
   }
}
static void drain(struct npt_renderer *r)
{
   while (r->deferred_count) {
      free(r->deferred[--r->deferred_count]);
      --r->live;
   }
}
#endif
#include PERP_SHMEM_POOL_SOURCE

int main(void)
{
   const size_t batch = 16u * 1024u * 1024u;
   struct npt_renderer r = {.limit = batch};
   struct npt_shmem_pool pool;
   npt_shmem_pool_init(&pool, batch);
   size_t off;
   struct npt_renderer_shmem *first = npt_shmem_pool_alloc(&r, &pool, 31920, &off);
   assert(first && first->size == batch && off == 0 && r.calls == 1);
   /* Exhaust the current chunk. Failed growth must preserve both references
    * and allocator position; a caller can still use the previous allocation. */
   pool.used = pool.size;
   r.limit = 0;
   unsigned before = r.calls;
   assert(!npt_shmem_pool_alloc(&r, &pool, 31920, &off));
   assert(r.calls == before + 2 && pool.shmem == first && pool.used == batch);
   assert(first->refs == 2 && r.live == 1);
   r.limit = 32768;
   before = r.calls;
   struct npt_renderer_shmem *small = npt_shmem_pool_alloc(&r, &pool, 31920, &off);
   assert(small && small->size == 32768 && off == 0 && r.calls == before + 2);
   assert(first->refs == 1 && pool.size == 32768 && pool.used == 31920);
#ifdef PERP_ASYNC_POOL_RETIRE
   assert(r.async_calls == 1 && !r.deferred_count);
#endif
   npt_renderer_shmem_unref(&r, first);
   /* A request as large as the batch must fail without a pointless retry. */
   before = r.calls;
   assert(!npt_shmem_pool_alloc(&r, &pool, batch, &off));
   assert(r.calls == before + 1 && pool.shmem == small && small->refs == 2);
   npt_shmem_pool_fini(&r, &pool);
   assert(small->refs == 1);
   npt_renderer_shmem_unref(&r, small);
   assert(!r.live);
#ifdef PERP_ASYNC_POOL_RETIRE
   /* When only the pool owns an exhausted chunk, growth transfers its last
    * reference to the reaper. It cannot reuse/free that chunk in the caller. */
   r.limit = batch;
   npt_shmem_pool_init(&pool, batch);
   first = npt_shmem_pool_alloc(&r, &pool, 4096, &off);
   npt_renderer_shmem_unref(&r, first);
   assert(first->refs == 1);
   pool.used = pool.size;
   small = npt_shmem_pool_alloc(&r, &pool, 4096, &off);
   assert(small != first && off == 0 && r.live == 2);
   assert(r.deferred_count == 1 && !first->refs && r.deferred[0] == first);
   drain(&r);
   assert(r.live == 1 && small->refs == 2);
   npt_shmem_pool_fini(&r, &pool);
   npt_renderer_shmem_unref(&r, small);
   assert(!r.live && !r.deferred_count);
   puts("PASS: retained caller refs, deferred last ref, fresh offsets and explicit drain");
#endif
   puts("PASS: ordinary batching, compact retry, failure retention and large request bound");
}
