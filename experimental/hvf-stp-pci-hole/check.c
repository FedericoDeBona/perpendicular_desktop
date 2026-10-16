/* SPDX-License-Identifier: GPL-2.0-or-later */
#include <assert.h>
#include <stdio.h>
#include "decode.h"

static void check_word(uint32_t word, unsigned want_rt, unsigned want_rt2,
                       unsigned want_rn, int64_t want_offset)
{
    unsigned rt, rt2, rn;
    int64_t offset;

    assert(perp_stp_q_decode(word, &rt, &rt2, &rn, &offset));
    assert(rt == want_rt && rt2 == want_rt2 && rn == want_rn);
    assert(offset == want_offset);
}

int main(void)
{
    unsigned rt, rt2, rn;
    uint64_t address;
    int64_t offset;
    unsigned count = 0;

    /* Exhaust every register field and all 128 signed immediates. SP is the
     * only rejected register encoding; all addressing/type bits stay fixed. */
    for (uint32_t immediate = 0; immediate < 128; immediate++) {
        int64_t expected = (immediate < 64 ? (int64_t)immediate :
                            (int64_t)immediate - 128) * 16;
        for (uint32_t fields = 0; fields < 32768; fields++) {
            uint32_t word = UINT32_C(0xad000000) | (immediate << 15) | fields;
            bool accepted = perp_stp_q_decode(word, &rt, &rt2, &rn, &offset);
            assert(accepted == (((fields >> 5) & 31) != 31));
            assert(rt == (fields & 31) && rt2 == ((fields >> 10) & 31));
            assert(offset == expected);
            count++;
        }
    }
    check_word(0xad000400, 0, 1, 0, 0);    /* Observed first fault. */
    check_word(0xad011404, 4, 5, 0, 32);   /* Observed next PC+4 fault. */
    check_word(0xad200400, 0, 1, 0, -1024);
    check_word(0xad3f8400, 0, 1, 0, -16);
    check_word(0xad1f8400, 0, 1, 0, 1008);
    check_word(0xad00f7df, 31, 29, 30, 16);
    /* Every fixed encoding bit is mandatory: no load, integer pair,
     * pre/post writeback, non-temporal pair or D/S pair is accepted. */
    for (unsigned bit = 22; bit < 32; bit++) {
        assert(!perp_stp_q_decode(0xad011404 ^ (1u << bit), &rt, &rt2, &rn, &offset));
        count++;
    }
    const uint32_t rejected[] = {
        0xad400400, 0xa9000400, 0xad800400, 0xac800400,
        0xac000400, 0x6d000400, 0x2d000400, 0xad0007e0,
        0xad000000 | (127u << 15) | (31u << 5)
    };
    for (unsigned i = 0; i < sizeof(rejected) / sizeof(rejected[0]); i++) {
        assert(!perp_stp_q_decode(rejected[i], &rt, &rt2, &rn, &offset));
    }
    /* Failed calculations must not publish a partially computed address.
     * A base on another page is valid if the effective access stays in one. */
    assert(perp_stp_q_address(0x1748, 32, &address) && address == 0x1768);
    assert(perp_stp_q_address(0x2400, -1024, &address) && address == 0x2000);
    assert(perp_stp_q_address(0x1000, 1008, &address) && address == 0x13f0);
    assert(perp_stp_q_address(1024, -1024, &address) && address == 0);
    assert(perp_stp_q_address(UINT64_MAX - 1008, 1008, &address) && address == UINT64_MAX);
    assert(perp_stp_q_address(UINT64_MAX, 0, &address) && address == UINT64_MAX);
    address = 0xabc;
    assert(!perp_stp_q_address(1023, -1024, &address) && address == 0xabc);
    assert(!perp_stp_q_address(UINT64_MAX - 1007, 1008, &address) && address == 0xabc);
    assert(!perp_stp_q_address(0, -16, &address) && address == 0xabc);
    assert(!perp_stp_q_address(UINT64_MAX, 16, &address) && address == 0xabc);
    assert(!perp_stp_q_address(0x2000, -1040, &address));
    assert(!perp_stp_q_address(0x2000, 1024, &address));
    assert(!perp_stp_q_address(0x2000, 1, &address));
    assert(!perp_stp_q_address(0x2000, -1, &address));
    assert(!perp_stp_q_address(0x2000, INT64_MIN, &address));
    assert(!perp_stp_q_address(0x2000, INT64_MAX, &address));

    assert(perp_stp_q_fault(0x92000045, 0x1748, 0x2748));
    assert(perp_stp_q_fault(0x92000045, 0x1768, 0x2768));
    assert(perp_stp_q_fault(0x92000046, 0x1fe0, 0x2fe0));
    assert(!perp_stp_q_fault(0x92000045, 0x1fe1, 0x2fe1));
    assert(!perp_stp_q_fault(0x92000045, 0x1748, 0x2740));
    assert(!perp_stp_q_fault(0x92000045, UINT64_MAX - 15, UINT64_MAX - 15));
    assert(!perp_stp_q_fault(0x92000041, 0x1748, 0x2748));
    assert(!perp_stp_q_fault(0x9200004d, 0x1748, 0x2748));
    assert(!perp_stp_q_fault(0x96000045, 0x1748, 0x2748));
    for (unsigned bit = 7; bit <= 10; bit++) {
        assert(!perp_stp_q_fault(0x92000045 | (1u << bit), 0x1748, 0x2748));
    }
    assert(!perp_stp_q_fault(0x93000045, 0x1748, 0x2748));
    assert(!perp_stp_q_fault(0x90000045, 0x1748, 0x2748));
    assert(!perp_stp_q_fault(0x92000005, 0x1748, 0x2748));
    /* A valid effective sum may still make the 32-byte access cross or wrap. */
    assert(perp_stp_q_address(0x1fc0, 32, &address) && address == 0x1fe0);
    assert(perp_stp_q_fault(0x92000045, address, 0x2fe0));
    assert(perp_stp_q_address(0x1fd0, 32, &address) && address == 0x1ff0);
    assert(!perp_stp_q_fault(0x92000045, address, 0x2ff0));
    assert(perp_stp_q_address(UINT64_MAX - 16, 16, &address));
    assert(!perp_stp_q_fault(0x92000045, address, address));
    printf("STP Q signed-offset decode/address/fault checks passed (%u field/encoding cases).\n", count);
    return 0;
}
