/* SPDX-License-Identifier: MIT */
#ifndef PERP_LIVE_QEMU_H
#define PERP_LIVE_QEMU_H
#include "ui/console.h"
bool perp_live_qemu_select(void *owner,QemuConsole *console,unsigned output,uint32_t resource,
    uint32_t width,uint32_t height,uint32_t x,uint32_t y,uint32_t crop_width,uint32_t crop_height);
bool perp_live_qemu_flush(void *owner,unsigned output,uint32_t resource);
void perp_live_qemu_reset(void *owner);
char *perp_live_qemu_stats(void);
bool perp_live_qemu_hold_read(void);
void perp_live_qemu_set_hold_read(bool hold);
bool perp_live_qemu_delay_done(void);
void perp_live_qemu_set_delay_done(bool delay);
bool perp_live_qemu_hold_adapter(void);
void perp_live_qemu_set_hold_adapter(bool hold);
#endif
