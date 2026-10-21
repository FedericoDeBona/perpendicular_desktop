/* SPDX-License-Identifier: MIT
 * Checked metadata for the one primary Mac monitor selected at VM startup.
 * This carries physical size and a stable EDID identity, never a DPI override.
 */
#ifndef PERP_PRIMARY_MONITOR_H
#define PERP_PRIMARY_MONITOR_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

typedef struct PerpPrimaryMonitor {
    uint16_t width_mm, height_mm;
    uint32_t serial;
} PerpPrimaryMonitor;

static inline bool perp_primary_monitor_mm(const char *text, uint16_t *value)
{
    unsigned parsed = 0, digits = 0;
    if (!text || !*text) return false;
    for (; *text; text++) {
        if (*text < '0' || *text > '9' || ++digits > 4) return false;
        parsed = parsed * 10 + (unsigned)(*text - '0');
    }
    /* EDID's base physical size fields hold at most 255 centimetres. */
    if (parsed < 10 || parsed > 2550) return false;
    *value = (uint16_t)parsed;
    return true;
}

static inline bool perp_primary_monitor_read(PerpPrimaryMonitor *result)
{
    PerpPrimaryMonitor monitor = {0};
    const char *id = getenv("PERP_PRIMARY_MONITOR_ID");
    if (!perp_primary_monitor_mm(getenv("PERP_PRIMARY_MONITOR_WIDTH_MM"), &monitor.width_mm) ||
        !perp_primary_monitor_mm(getenv("PERP_PRIMARY_MONITOR_HEIGHT_MM"), &monitor.height_mm) ||
        !id || strlen(id) != 36) return false;
    /* Public UUID -> stable 32-bit numeric EDID serial. Not a security token;
     * EDID's serial field cannot preserve a full UUID or promise no collisions. */
    uint32_t hash = 2166136261u;
    for (unsigned i = 0; i < 36; i++) {
        unsigned char ch = (unsigned char)id[i];
        if (i == 8 || i == 13 || i == 18 || i == 23) {
            if (ch != '-') return false;
        } else {
            if (ch >= 'A' && ch <= 'F') ch = (unsigned char)(ch + ('a' - 'A'));
            if (!((ch >= '0' && ch <= '9') || (ch >= 'a' && ch <= 'f'))) return false;
        }
        hash = (hash ^ ch) * 16777619u;
    }
    monitor.serial = hash ? hash : 1;
    *result = monitor;
    return true;
}

static inline void perp_primary_monitor_seed_size(uint16_t *width_mm, uint16_t *height_mm)
{
    PerpPrimaryMonitor monitor;
    if ((!*width_mm || !*height_mm) && perp_primary_monitor_read(&monitor)) {
        *width_mm = monitor.width_mm;
        *height_mm = monitor.height_mm;
    }
}

static inline void perp_primary_monitor_edid_serial(uint8_t *edid, size_t size, uint32_t serial)
{
    if (size < 128) return;
    /* Preserve the descriptor slots: the flexible-mode patch needs 0xf7/0xfd.
     * qemu_edid_info.serial would consume one of those slots with text. */
    for (unsigned i = 0; i < 4; i++) edid[12 + i] = (uint8_t)(serial >> (8 * i));
    unsigned sum = 0;
    for (unsigned i = 0; i < 127; i++) sum += edid[i];
    edid[127] = (uint8_t)(0 - sum);
}
#endif
