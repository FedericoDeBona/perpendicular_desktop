/* Compare the actual cursor with QEMU's unmodified iov_to_buf_full body.
 * The private reference header is extracted from the pinned util/iov.c. */
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/uio.h>
#define MIN(a, b) ((a) < (b) ? (a) : (b))
#include PERP_IOV_REFERENCE
#define iov_to_buf iov_to_buf_full
#include "../graphics/qemu/transfer-2d-cursor.h"

static void check(const struct iovec *iov, unsigned count,
                  const size_t *offsets, size_t rows, size_t width)
{
    unsigned char before[512], after[512];
    memset(before, 0xcd, sizeof(before));
    memset(after, 0xcd, sizeof(after));
    PerpIovCursor cursor = {0};
    for (size_t row = 0; row < rows; row++) {
        size_t old = iov_to_buf_full(iov, count, offsets[row],
                                     before + 16 + row * 48, width);
        size_t next = perp_iov_to_buf(iov, count, &cursor, offsets[row],
                                      after + 16 + row * 48, width);
        assert(old == next);
    }
    /* Includes row padding and surrounding guards, not just copied pixels. */
    assert(memcmp(before, after, sizeof(before)) == 0);
}

int main(void)
{
    unsigned char backing[8][128];
    size_t sizes[] = {3, 0, 5, 1, 7, 0, 31, 81};
    struct iovec fragmented[8];
    size_t position = 0;
    for (unsigned i = 0; i < 8; i++) {
        fragmented[i] = (struct iovec){backing[i], sizes[i]};
        for (size_t byte = 0; byte < sizes[i]; byte++) {
            backing[i][byte] = (unsigned char)(position++ * 37 + 11);
        }
    }
    const size_t rows[] = {4, 16, 28, 40, 52, 64, 76, 88, 100, 112};
    const size_t edges[] = {100, 2, 120, 128, 0};
    const size_t outside[] = {128, 140};
    const size_t repeated[] = {7, 7, 7};
    check(fragmented, 8, rows, 10, 10);       /* partial-width, padded */
    check(fragmented, 8, rows, 10, 24);       /* short last row */
    check(fragmented, 8, edges, 5, 16);       /* rewind and exhausted cursor */
    check(fragmented, 8, outside, 2, 6);      /* no backing at offset */
    check(fragmented, 8, repeated, 3, 0);     /* empty rows */
    check(NULL, 0, repeated, 3, 16);          /* no iovec */
    puts("2D cursor: six differential byte/length/guard checks passed");
}
