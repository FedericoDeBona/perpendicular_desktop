/* SPDX-License-Identifier: GPL-2.0-or-later */
#ifndef PERP_HVF_STP_PCI_HOLE_H
#define PERP_HVF_STP_PCI_HOLE_H
#include "exec/ioport.h"
#include "exec/cpu-common.h"
#include "exec/memory.h"
#include "exec/target_page.h"
#include "decode.h"

/* Debug translation is for instruction observation only. Intermediate page
 * table reads may dispatch MMIO, as in the separate observation diagnostic. */
static bool perp_stp_q_code(CPUState *cpu, uint32_t *word)
{
    CPUARMState *env = &ARM_CPU(cpu)->env;
    MemTxAttrs attrs = MEMTXATTRS_UNSPECIFIED;
    hwaddr page, offset;
    AddressSpace *as;
    MemoryRegionSection section;
    MemoryRegion *mr;
    uint8_t code[4];
    int index;
    bool ok = false;
    if (env->pc & 3) {
        return false;
    }
    page = cpu_get_phys_page_attrs_debug(cpu, env->pc & TARGET_PAGE_MASK, &attrs);
    offset = env->pc & ~TARGET_PAGE_MASK;
    if (page == (hwaddr)-1 || page > UINT64_MAX - offset) {
        return false;
    }
    index = cpu_asidx_from_attrs(cpu, attrs);
    if (index < 0 || index >= cpu->num_ases) {
        return false;
    }
    as = cpu_get_address_space(cpu, index);
    if (!as || !as->root) {
        return false;
    }
    section = memory_region_find(as->root, page + offset, 4);
    mr = section.mr;
    if (mr && memory_region_is_ram(mr) && !memory_region_is_ram_device(mr) &&
        !mr->rom_device && mr->ram_block &&
        !memory_region_has_ram_discard_manager(mr) &&
        int128_ge(section.size, int128_make64(4))) {
        const uint8_t *backing = memory_region_get_ram_ptr(mr);
        if (backing) {
            memcpy(code, backing + section.offset_within_region, 4);
            *word = ldl_le_p(code);
            ok = true;
        }
    }
    if (mr) {
        memory_region_unref(mr);
    }
    return ok;
}

static bool perp_hvf_stp_q_pci_hole(CPUState *cpu, uint64_t syndrome,
                                    uint64_t va, uint64_t pa)
{
    const char *option = getenv("PERP_HVF_STP_Q_PCI_HOLE");
    CPUARMState *env;
    MemoryRegionSection section;
    MemoryRegion *mr;
    hv_simd_fp_uchar16_t first, second;
    uint8_t bytes[32];
    uint32_t word;
    uint64_t effective_address;
    int64_t offset;
    unsigned rt, rt2, rn;
    MemTxResult result;
    static unsigned logged;
    bool hole;

    if (!option || strcmp(option, "1") || !bql_locked() ||
        !perp_stp_q_fault(syndrome, va, pa) ||
        !cpu || !cpu->cpu_ases || cpu->num_ases <= 0) {
        return false;
    }
    cpu_synchronize_state(cpu);
    env = &ARM_CPU(cpu)->env;
    if (!env->aarch64 || arm_current_el(env) != 0 ||
        arm_cpu_data_is_big_endian(env) ||
        ((arm_sctlr(env, 0) & SCTLR_A) && (va & 15)) ||
        !perp_stp_q_code(cpu, &word) ||
        !perp_stp_q_decode(word, &rt, &rt2, &rn, &offset) ||
        !perp_stp_q_address(env->xregs[rn], offset, &effective_address) ||
        effective_address != va) {
        return false;
    }
    /* The hardware FAR must equal checked Xn + signed imm7 * 16; Xn is never
     * written back. The fault supplies the first operand's VA/IPA. The complete
     * access must stay in one minimum 4K page; no debugger operand translation
     * or assumption across stage1/stage2 page boundaries is used. */
    section = memory_region_find(address_space_memory.root, pa, sizeof(bytes));
    mr = section.mr;
    hole = mr && mr->ops == &unassigned_io_ops &&
           !strcmp(memory_region_name(mr), "gpex_mmio_window") &&
           !memory_region_is_ram(mr) && !mr->rom_device &&
           int128_ge(section.size, int128_make64(sizeof(bytes)));
    if (!hole) {
        if (mr) {
            memory_region_unref(mr);
        }
        return false;
    }
    if (hv_vcpu_get_simd_fp_reg(cpu->accel->fd, HV_SIMD_FP_REG_Q0 + rt,
                               &first) != HV_SUCCESS ||
        hv_vcpu_get_simd_fp_reg(cpu->accel->fd, HV_SIMD_FP_REG_Q0 + rt2,
                               &second) != HV_SUCCESS) {
        memory_region_unref(mr);
        return false;
    }
    memcpy(bytes, &first, 16);
    memcpy(bytes + 16, &second, 16);
    /* Dispatch all 32 bytes using the same bus semantics as scalar ISV writes.
     * The referenced FlatView overlap is entirely the GPEX unassigned handler,
     * whose write callback ignores writes. No GPU mapping is kept or invented. */
    result = address_space_write(&address_space_memory, pa,
                                 MEMTXATTRS_UNSPECIFIED, bytes, sizeof(bytes));
    memory_region_unref(mr);
    if (result != MEMTX_OK) {
        return false;
    }
    if (logged++ < 64) {
        error_report("perpendicular-hvf-stp-hole-v1 emulated=1 bytes=32");
    }
    return true;
}
#endif
