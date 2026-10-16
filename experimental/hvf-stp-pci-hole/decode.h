/* SPDX-License-Identifier: GPL-2.0-or-later */
#ifndef PERP_HVF_STP_PCI_HOLE_DECODE_H
#define PERP_HVF_STP_PCI_HOLE_DECODE_H
#include <stdbool.h>
#include <stdint.h>

/* Only A64 STP Qt, Qt2, [Xn, #imm], signed-offset mode, no writeback.
 * The signed imm7 is scaled by the 16-byte SIMD element size. */
static inline bool perp_stp_q_decode(uint32_t word, unsigned *rt,
                                   unsigned *rt2, unsigned *rn,
                                   int64_t *offset)
{
    int immediate;

    if ((word & UINT32_C(0xffc00000)) != UINT32_C(0xad000000)) {
        return false;
    }
    *rt = word & 31;
    *rt2 = (word >> 10) & 31;
    *rn = (word >> 5) & 31;
    immediate = (word >> 15) & 127;
    if (immediate & 64) {
        immediate -= 128;
    }
    *offset = (int64_t)immediate * 16; /* No signed shift or narrowing cast. */
    return *rn != 31; /* SP and its alignment rules are deliberately excluded. */
}

/* Fail closed rather than wrapping a guest address. The original Xn is never
 * changed; cross-page qualification applies to the resulting access, not Xn. */
static inline bool perp_stp_q_address(uint64_t base, int64_t offset,
                                    uint64_t *address)
{
    uint64_t amount;

    if (offset < -1024 || offset > 1008 || offset % 16 != 0) {
        return false;
    }
    if (offset < 0) {
        amount = (uint64_t)-offset; /* Range above excludes INT64_MIN. */
        if (base < amount) {
            return false;
        }
        *address = base - amount;
    } else {
        amount = (uint64_t)offset;
        if (base > UINT64_MAX - amount) {
            return false;
        }
        *address = base + amount;
    }
    return true;
}

static inline bool perp_stp_q_fault(uint64_t syndrome, uint64_t va, uint64_t pa)
{
    unsigned fsc = syndrome & 63;
    /* Lower-EL A64 data abort, IL=1, ISV=0, write; no CM/S1PTW/FnV/EA. */
    return (syndrome >> 26) == 0x24 && (syndrome & (UINT64_C(1) << 25)) &&
           !(syndrome & ((UINT64_C(1) << 24) | (UINT64_C(1) << 10) |
                         (UINT64_C(1) << 9) | (UINT64_C(1) << 8) |
                         (UINT64_C(1) << 7))) && (syndrome & 64) &&
           fsc >= 4 && fsc <= 7 &&
           (va & 4095) == (pa & 4095) && (va & 4095) <= 4096 - 32 &&
           va <= UINT64_MAX - 31 && pa <= UINT64_MAX - 31;
}
#endif
