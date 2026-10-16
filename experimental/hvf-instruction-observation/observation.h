/* SPDX-License-Identifier: GPL-2.0-or-later */
#ifndef PERP_HVF_INSTRUCTION_OBSERVATION_H
#define PERP_HVF_INSTRUCTION_OBSERVATION_H

#include "exec/cpu-common.h"
#include "exec/memory.h"
#include "exec/target_page.h"
#include "system/cpus.h"
#include "target/arm/cpu.h"

/*
 * Optional pre-abort observation, NOT instruction emulation. Debug translation
 * reads page tables and may dispatch MMIO. The final code read is restricted
 * to exactly four bytes of ordinary RAM/RAM-backed ROM. No instruction runs.
 */
static void perp_hvf_observe_instruction(CPUState *cpu, uint64_t syndrome)
{
    const char *option;
    const char *status = "cpu_unavailable";
    CPUARMState *observation_env;
    MemTxAttrs attrs = MEMTXATTRS_UNSPECIFIED;
    MemoryRegionSection section = { .mr = NULL };
    MemoryRegion *mr = NULL;
    AddressSpace *as;
    hwaddr code_page, code_pa, page_offset;
    uint64_t pc;
    uint8_t code[4] = { 0 };
    uint32_t instruction = 0;
    uint8_t *backing;
    int asidx;
    bool observed = false;

    if (syndrome & ARM_EL_ISV) {
        return;
    }
    option = getenv("PERP_HVF_OBSERVE_INSN");
    if (!option || strcmp(option, "1") != 0) {
        return;
    }
    if (!cpu || !cpu->cpu_ases || cpu->num_ases <= 0) {
        goto report;
    }

    cpu_synchronize_state(cpu);
    observation_env = &ARM_CPU(cpu)->env;
    status = "not_aarch64";
    if (!observation_env->aarch64) {
        goto report;
    }
    pc = observation_env->pc;
    status = "unaligned_pc";
    if (pc & (sizeof(code) - 1)) {
        goto report;
    }

    /* This established debugger page walk is NOT a pure metadata operation.
     * Its intermediate PTE reads may invoke device callbacks. */
    code_page = cpu_get_phys_page_attrs_debug(cpu, pc & TARGET_PAGE_MASK,
                                              &attrs);
    status = "translation_failed";
    if (code_page == (hwaddr)-1) {
        goto report;
    }
    page_offset = pc & ~TARGET_PAGE_MASK;
    if (code_page > UINT64_MAX - page_offset) {
        goto report;
    }
    code_pa = code_page + page_offset;
    asidx = cpu_asidx_from_attrs(cpu, attrs);
    status = "address_space_unavailable";
    if (asidx < 0 || asidx >= cpu->num_ases) {
        goto report;
    }
    as = cpu_get_address_space(cpu, asidx);
    if (!as || !as->root) {
        goto report;
    }

    section = memory_region_find(as->root, code_pa, sizeof(code));
    mr = section.mr;
    status = "code_not_plain_memory";
    if (!mr || !memory_region_is_ram(mr) ||
        memory_region_is_ram_device(mr) || mr->rom_device) {
        goto report;
    }
    status = "code_range_unavailable";
    if (int128_lt(section.size, int128_make64(sizeof(code)))) {
        goto report;
    }
    status = "code_backing_unavailable";
    if (!mr->ram_block || memory_region_has_ram_discard_manager(mr)) {
        goto report;
    }
    backing = memory_region_get_ram_ptr(mr);
    if (!backing) {
        goto report;
    }

    /* Plain ROM is RAM-backed and allowed; ROMD/device regions were rejected.
     * PC alignment ensures this four-byte instruction does not cross a page. */
    memcpy(code, backing + section.offset_within_region, sizeof(code));
    instruction = ldl_le_p(code);
    status = "observed";
    observed = true;

report:
    if (mr) {
        memory_region_unref(mr);
    }
    if (observed) {
        error_report("perpendicular-hvf-insn-v1 status=%s instruction=0x%08x",
                     status, instruction);
    } else {
        error_report("perpendicular-hvf-insn-v1 status=%s", status);
    }
}

#endif
