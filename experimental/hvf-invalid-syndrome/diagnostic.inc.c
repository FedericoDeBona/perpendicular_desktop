/* SPDX-License-Identifier: GPL-2.0-or-later */
        if (!isv) {
            /* Diagnostic only: retain the original assert and execution path. */
            uint64_t diag_pc = 0;
            hv_return_t diag_pc_result;
            MemoryRegionSection diag_section;
            MemoryRegion *diag_mr;
            char diag_name[97] = "unmapped";
            uint64_t diag_region_size = 0;
            unsigned diag_ram = 0, diag_rom = 0, diag_romd = 0;
            unsigned diag_readonly = 0, diag_dirty_raw = 0;

            diag_pc_result = hv_vcpu_get_reg(cpu->accel->fd, HV_REG_PC,
                                             &diag_pc);
            /* FlatView metadata lookup only. No guest read, IOMMU translation,
             * MMIO dispatch, instruction fetch or host pointer is exposed. */
            diag_section = memory_region_find(get_system_memory(),
                                hvf_exit->exception.physical_address, 1);
            diag_mr = diag_section.mr;
            if (diag_mr) {
                const char *diag_source_name = diag_mr->name;
                size_t diag_i;

                if (!diag_source_name) {
                    diag_source_name = "unnamed";
                }
                for (diag_i = 0; diag_i < sizeof(diag_name) - 1 &&
                     diag_source_name[diag_i]; diag_i++) {
                    unsigned char diag_ch = diag_source_name[diag_i];

                    diag_name[diag_i] =
                        (diag_ch >= 32 && diag_ch <= 126 &&
                         diag_ch != '"' && diag_ch != '\\') ? diag_ch : '_';
                }
                diag_name[diag_i] = 0;
                diag_region_size = memory_region_size(diag_mr);
                diag_ram = memory_region_is_ram(diag_mr);
                diag_rom = memory_region_is_rom(diag_mr);
                diag_romd = memory_region_is_romd(diag_mr);
                diag_readonly = diag_section.readonly;
                diag_dirty_raw = diag_mr->dirty_log_mask;
            }
            error_report("perpendicular-hvf-isv0-v1 cpu=%d"
                         " esr=0x%016" PRIx64 " pc=0x%016" PRIx64
                         " pc_valid=%u pc_hv_result=0x%x"
                         " ipa=0x%016" PRIx64 " far=0x%016" PRIx64
                         " far_valid=%u fsc=0x%02x write=%u s1ptw=%u cm=%u"
                         " region_found=%u region=\"%s\""
                         " region_offset=0x%016" PRIx64
                         " region_size=0x%016" PRIx64
                         " ram=%u rom=%u romd=%u readonly=%u dirty_raw=0x%x",
                         cpu->cpu_index, syndrome, diag_pc,
                         (unsigned)(diag_pc_result == HV_SUCCESS),
                         (unsigned)diag_pc_result,
                         hvf_exit->exception.physical_address,
                         hvf_exit->exception.virtual_address,
                         (unsigned)((syndrome & (1u << 10)) == 0),
                         (unsigned)(syndrome & 0x3f), (unsigned)iswrite,
                         (unsigned)s1ptw, cm, (unsigned)(diag_mr != NULL),
                         diag_name, (uint64_t)diag_section.offset_within_region,
                         diag_region_size, diag_ram, diag_rom, diag_romd,
                         diag_readonly, diag_dirty_raw);
            if (diag_mr) {
                memory_region_unref(diag_mr);
            }
        }
