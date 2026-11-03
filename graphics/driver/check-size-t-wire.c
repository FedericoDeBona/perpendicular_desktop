/* Compile as Win32 against the real protocol headers. The adjacent canaries
 * expose an eight-byte read/write through a four-byte Windows SIZE_T. */
#include "npt_cs.h"
#ifndef SIZE_T_PROTOCOL_HEADER
#define SIZE_T_PROTOCOL_HEADER "neptune-protocol/npt_protocol_common_types.h"
#endif
#include SIZE_T_PROTOCOL_HEADER
#include <inttypes.h>

int main(void) {
    struct { SIZE_T value; uint32_t guard; } input = {296, 0xa5a55a5a};
    struct { SIZE_T value; uint32_t guard; } output = {123, 0x12345678};
    uint8_t bytes[32] = {0};
    struct npt_cs_encoder enc = {bytes, bytes + sizeof(bytes)};
    npt_encode_SIZE_T(&enc, &input.value);
    uint64_t encoded = 0;
    memcpy(&encoded, bytes, sizeof(encoded));
    const uint64_t expected = 296;
    struct npt_cs_decoder dec = {0};
    dec.cur = (const uint8_t *)&expected;
    dec.end = dec.cur + sizeof(expected);
    npt_decode_SIZE_T(&dec, &output.value);
    int failures = sizeof(SIZE_T) != 4 || encoded != expected ||
                   enc.cur - bytes != 8 || output.value != expected || output.guard != 0x12345678;
    printf("SIZE_T=%u scalar_wire=%" PRIu64 " decoded=%u guard=%08x\n",
           (unsigned)sizeof(SIZE_T), encoded, (unsigned)output.value, output.guard);

    struct { SIZE_T values[3]; uint32_t guard; uint32_t tail[4]; }
        array = {{0, UINT32_MAX, 0x80000000u}, 0x76543210, {0}};
    uint64_t wire[3] = {0, UINT32_MAX, 0x80000000u};
    enc.cur = bytes;
    npt_encode_SIZE_T_array(&enc, array.values, 3);
    failures += memcmp(bytes, wire, sizeof(wire)) != 0 || enc.cur - bytes != sizeof(wire);
    dec.cur = (const uint8_t *)wire;
    dec.end = dec.cur + sizeof(wire);
    memset(array.values, 0, sizeof(array.values));
    npt_decode_SIZE_T_array(&dec, array.values, 3);
    failures += array.values[0] != 0 || array.values[1] != UINT32_MAX ||
                array.values[2] != 0x80000000u || array.guard != 0x76543210;

    uint64_t too_wide = UINT64_C(0x100000000);
    dec.cur = (const uint8_t *)&too_wide;
    dec.end = dec.cur + sizeof(too_wide);
    output.value = 123;
    npt_decode_SIZE_T(&dec, &output.value);
    failures += output.value != 123 || output.guard != 0x12345678;
    printf("array_guard=%08x rejected_overflow=%d failures=%d\n",
           array.guard, output.value == 123, failures);
    return failures ? 1 : 0;
}
