/* SPDX-License-Identifier: MIT
 * Shared Python/C fixture ring accesses use the same C11 memory ordering as
 * the actual Neptune reader, rather than relying on Python store ordering. */
#include <stdatomic.h>
#include <stdint.h>
void perp_ring_publish(void *address,uint32_t value)
{ atomic_store_explicit((_Atomic uint32_t *)address,value,memory_order_release); }
uint32_t perp_ring_load(void *address)
{ return atomic_load_explicit((_Atomic uint32_t *)address,memory_order_acquire); }
