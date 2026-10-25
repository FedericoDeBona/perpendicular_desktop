/* SPDX-License-Identifier: GPL-2.0-only
 * Native macOS backing for virtio-mem. Guest ACKs and upstream block tracking
 * remain authoritative; requested-size alone never releases host memory.
 */
#include "system/hvf.h"
#include "system/cpus.h"
#include "hw/core/cpu.h"
#include "migration/blocker.h"

#if defined(__APPLE__) && defined(__aarch64__)
#include <Hypervisor/Hypervisor.h>
#include <sys/mman.h>

static bool perp_virtio_mem_enabled(void)
{
    const char *value = getenv("PERP_HVF_VIRTIO_MEM");
    return hvf_enabled() && value && !strcmp(value, "1");
}

static int perp_virtio_mem_discard(VirtIOMEM *vmem, uint64_t offset, size_t size)
{
    RAMBlock *rb = vmem->memdev->mr.ram_block;
    if (!perp_virtio_mem_enabled()) {
        return ram_block_discard_range(rb, offset, size);
    }
    size_t page_size = qemu_real_host_page_size();
    uint64_t total = memory_region_size(&vmem->memdev->mr);
    void *host = memory_region_get_ram_ptr(&vmem->memdev->mr) + offset;
    if (!size || offset > total || size > total - offset ||
        !QEMU_IS_ALIGNED(offset, page_size) ||
        !QEMU_IS_ALIGNED(size, page_size) ||
        qemu_ram_get_fd(rb) >= 0 || qemu_ram_is_shared(rb)) {
        return -EINVAL;
    }
    bool mapped = memory_region_is_mapped(&vmem->memdev->mr);
    bool resume = false;
    if (mapped && !vmem->perp_hvf_in_bh) {
        CPUState *cpu;
        CPU_FOREACH(cpu) {
            resume |= !cpu->stopped;
        }
        pause_all_vcpus();
    }
    uint64_t gpa = vmem->addr + offset;
    if (mapped) {
        hv_return_t status = hv_vm_unmap(gpa, size);
        if (status != HV_SUCCESS) {
            error_report("virtio-mem: HVF unmap failed: 0x%x", status);
            if (resume) {
                resume_all_vcpus();
            }
            return -EBUSY;
        }
    }
    /* Replace only anonymous private backing which the guest surrendered.
     * Unlike Darwin MADV_DONTNEED, this really drops the old physical pages
     * and guarantees fresh zero-filled contents on a later plug. The address
     * and RAMBlock stay stable. No file/shared/GPU backing is accepted.
     */
    void *fresh = mmap(host, size, PROT_READ | PROT_WRITE,
                       MAP_FIXED | MAP_PRIVATE | MAP_ANON, -1, 0);
    if (fresh == MAP_FAILED || fresh != host) {
        error_report("virtio-mem: cannot replace surrendered RAM: %s",
                     strerror(errno));
        abort();
    }
    if (mapped) {
        hv_return_t status = hv_vm_map(host, gpa, size,
                                       HV_MEMORY_READ | HV_MEMORY_WRITE |
                                       HV_MEMORY_EXEC);
        if (status != HV_SUCCESS) {
            error_report("virtio-mem: cannot restore HVF RAM: 0x%x", status);
            abort();
        }
        vmem->perp_hvf_discarded_bytes += size;
    }
    if (resume) {
        resume_all_vcpus();
    }
    return 0;
}
#else
static bool perp_virtio_mem_enabled(void) { return false; }
static int perp_virtio_mem_discard(VirtIOMEM *vmem, uint64_t offset, size_t size)
{
    return ram_block_discard_range(vmem->memdev->mr.ram_block, offset, size);
}
#endif

static char *perp_virtio_mem_stats(Object *obj, Error **errp)
{
    VirtIOMEM *vmem = VIRTIO_MEM(obj);
    return g_strdup_printf("{\"enabled\":%s,\"discardedBytes\":%" PRIu64
        ",\"pluggedBytes\":%" PRIu64 ",\"requestedBytes\":%" PRIu64 "}",
        perp_virtio_mem_enabled() ? "true" : "false",
        vmem->perp_hvf_discarded_bytes, vmem->size, vmem->requested_size);
}
