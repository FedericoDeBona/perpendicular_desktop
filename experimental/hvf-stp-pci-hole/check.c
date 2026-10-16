/* SPDX-License-Identifier: GPL-2.0-or-later */
#include <assert.h>
#include <stdio.h>
#include "decode.h"
int main(void)
{
    unsigned rt, rt2, rn;
    unsigned count = 0;
    for (uint32_t fields = 0; fields < 32768; fields++) {
        bool accepted = perp_stp_q_decode(0xad000000 | fields, &rt, &rt2, &rn);
        assert(accepted == (((fields >> 5) & 31) != 31));
        assert(rt == (fields & 31) && rt2 == ((fields >> 10) & 31));
        count++;
    }
    assert(perp_stp_q_decode(0xad000400, &rt, &rt2, &rn));
    assert(rt == 0 && rt2 == 1 && rn == 0);
    /* No adjacent addressing form or immediate/sign bit is accepted. */
    for (unsigned bit = 15; bit < 32; bit++) {
        assert(!perp_stp_q_decode(0xad000400 ^ (1u << bit), &rt, &rt2, &rn));
        count++;
    }
    assert(!perp_stp_q_decode(0xad400400, &rt, &rt2, &rn)); /* LDP */
    assert(!perp_stp_q_decode(0xa9000400, &rt, &rt2, &rn)); /* integer STP */
    assert(perp_stp_q_fault(0x92000045, 0x1748, 0x2748));
    assert(perp_stp_q_fault(0x92000046, 0x1fe0, 0x2fe0));
    assert(!perp_stp_q_fault(0x92000045, 0x1fe1, 0x2fe1));
    assert(!perp_stp_q_fault(0x92000045, 0x1748, 0x2740));
    assert(!perp_stp_q_fault(0x92000045, UINT64_MAX - 15, UINT64_MAX - 15));
    assert(!perp_stp_q_fault(0x92000041, 0x1748, 0x2748)); /* alignment */
    assert(!perp_stp_q_fault(0x9200004d, 0x1748, 0x2748)); /* permission */
    assert(!perp_stp_q_fault(0x96000045, 0x1748, 0x2748)); /* same EL */
    for (unsigned bit = 7; bit <= 10; bit++) {
        assert(!perp_stp_q_fault(0x92000045 | (1u << bit), 0x1748, 0x2748));
    }
    assert(!perp_stp_q_fault(0x93000045, 0x1748, 0x2748)); /* ISV */
    assert(!perp_stp_q_fault(0x90000045, 0x1748, 0x2748)); /* IL */
    assert(!perp_stp_q_fault(0x92000005, 0x1748, 0x2748)); /* read */
    printf("STP Q decode/range negative checks passed (%u field/encoding cases).\n", count);
    return 0;
}
