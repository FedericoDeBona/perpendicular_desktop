/* SPDX-License-Identifier: GPL-2.0-or-later
 * Included in copied GPU and PCI translation units only. */
#include "hw/pci/pci.h"
#include "hw/pci/pci_device.h"
#include "diagnostic.h"

static bool perp_gpu_map_diag_target(PCIDevice *device)
{
    return device && pci_get_word(device->config + PCI_VENDOR_ID) == 0x1af4 &&
           pci_get_word(device->config + PCI_DEVICE_ID) == 0x1050;
}

static void perp_gpu_map_diag_fields(PerpGpuMapRecord *record, PCIDevice *device)
{
    const PCIIORegion *bar = &device->io_regions[4];

    record->bdf = (pci_dev_bus_num(device) << 8) | device->devfn;
    record->bar_start = bar->size ? bar->addr : PCI_BAR_UNMAPPED;
    record->bar_size = bar->size;
    record->bar_config = pci_get_quad(device->config + PCI_BASE_ADDRESS_4) &
                         ~UINT64_C(0xf);
    record->bar_mapped = bar->size && bar->addr != PCI_BAR_UNMAPPED;
    record->command = pci_get_word(device->config + PCI_COMMAND);
    record->pm = device->cap_present & QEMU_PCI_CAP_PM ?
        pci_get_word(device->config + device->pm_cap + PCI_PM_CTRL) &
        PCI_PM_CTRL_STATE_MASK : 0;
    record->old_bar = record->new_bar = bar->addr;
    record->vstatus = UINT32_MAX; /* not sampled by generic PCI hooks */
}
