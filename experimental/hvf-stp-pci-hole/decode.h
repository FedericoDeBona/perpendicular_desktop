/* SPDX-License-Identifier: GPL-2.0-or-later */
#ifndef PERP_HVF_STP_PCI_HOLE_DECODE_H
#define PERP_HVF_STP_PCI_HOLE_DECODE_H
#include <stdbool.h>
#include <stdint.h>

/* Only A64 STP Qt, Qt2, [Xn, #0], signed-offset mode, no writeback. */
static inline bool perp_stp_q_decode(uint32_t word, unsigned *rt,
                                   unsigned *rt2, unsigned *rn)
{
    if ((word & UINT32_C(0xffff8000)) != UINT32_C(0xad000000)) {
        return false;
    }
    *rt = word & 31;
    *rt2 = (word >> 10) & 31;
    *rn = (word >> 5) & 31;
    return *rn != 31; /* SP and its alignment rules are deliberately excluded. */
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
