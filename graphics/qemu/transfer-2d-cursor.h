/* SPDX-License-Identifier: GPL-2.0-or-later */
#ifndef PERP_TRANSFER_2D_CURSOR_H
#define PERP_TRANSFER_2D_CURSOR_H

/* A transfer's rows advance through the same immutable backing iovec. Keep
 * the row-start position instead of rescanning all preceding guest pages.
 * iov_to_buf still handles fragmented rows, short backing and the copy. */
typedef struct PerpIovCursor {
    unsigned int index;
    size_t base;
} PerpIovCursor;

static inline size_t perp_iov_to_buf(const struct iovec *iov,
                                   unsigned int count, PerpIovCursor *cursor,
                                   size_t offset, void *destination, size_t bytes)
{
    if (offset < cursor->base) {
        cursor->index = 0;
        cursor->base = 0;
    }
    while (cursor->index < count &&
           offset - cursor->base >= iov[cursor->index].iov_len) {
        cursor->base += iov[cursor->index].iov_len;
        cursor->index++;
    }
    if (cursor->index == count) {
        return 0;
    }
    return iov_to_buf(iov + cursor->index, count - cursor->index,
                      offset - cursor->base, destination, bytes);
}
#endif
