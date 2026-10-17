/* SPDX-License-Identifier: MIT */
#ifndef PERP_NATIVE_METAL_HEADLESS_H
#define PERP_NATIVE_METAL_HEADLESS_H
/* QEMU main/BQL thread only; caller frees the JSON string. */
char *perp_native_headless_stats(void);
#endif
