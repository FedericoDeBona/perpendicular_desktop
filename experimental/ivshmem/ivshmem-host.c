/*
 * Isolated plain IVSHMEM experiment for Perpendicular / QEMU 10.0.12.
 * PCI layout and backing-store setup derived from QEMU hw/misc/ivshmem-pci.c
 * (Cam Macdonell and QEMU contributors). GPL-2.0-or-later.
 * No eventfd server, guest interrupts or graphics-driver dependencies.
 */
#include "qemu/osdep.h"
#include "qapi/error.h"
#include "qemu/module.h"
#include "hw/pci/pci.h"
#include "hw/pci/pci_device.h"
#include "hw/qdev-properties.h"
#include "hw/qdev-properties-system.h"
#include "system/hostmem.h"
#include "chardev/char-fe.h"
#include "migration/vmstate.h"

#define TYPE_PERP_IVSHMEM "perp-ivshmem-plain"
OBJECT_DECLARE_SIMPLE_TYPE(PerpIVShmem, PERP_IVSHMEM)

struct PerpIVShmem {
    PCIDevice parent_obj;
    HostMemoryBackend *memdev;
    MemoryRegion registers;
    CharBackend notify;
    guint watch;
    bool pending;
    bool connected;
};

static void notify_flush(PerpIVShmem *s);

static gboolean notify_writable(void *channel, GIOCondition condition,
                                 void *opaque)
{
    PerpIVShmem *s = opaque;
    s->watch = 0;
    if (condition & (G_IO_HUP | G_IO_ERR)) {
        s->connected = false;
    } else {
        notify_flush(s);
    }
    return G_SOURCE_REMOVE;
}

static void notify_flush(PerpIVShmem *s)
{
    static const uint8_t wake = 1;
    if (!s->pending || !s->connected || s->watch) {
        return;
    }
    /* One byte at most; never wait for the frontend from an MMIO handler. */
    if (qemu_chr_fe_write(&s->notify, &wake, 1) == 1) {
        s->pending = false;
    } else {
        s->watch = qemu_chr_fe_add_watch(&s->notify,
            G_IO_OUT | G_IO_HUP | G_IO_ERR, notify_writable, s);
    }
}

static void notify_event(void *opaque, QEMUChrEvent event)
{
    PerpIVShmem *s = opaque;
    if (event == CHR_EVENT_OPENED || event == CHR_EVENT_CLOSED) {
        if (s->watch) {
            g_source_remove(s->watch);
            s->watch = 0;
        }
        s->connected = event == CHR_EVENT_OPENED;
        /* Opening always wakes the consumer to scan the shared queue. */
        s->pending = true;
        notify_flush(s);
    }
}

static uint64_t registers_read(void *opaque, hwaddr offset, unsigned size)
{
    PerpIVShmem *s = opaque;
    /* Local extension signature; zero when notifications are not configured. */
    return offset == 16 && qemu_chr_fe_backend_connected(&s->notify)
        ? 0x50525001 : 0;
}

static void registers_write(void *opaque, hwaddr offset, uint64_t value,
                            unsigned size)
{
    PerpIVShmem *s = opaque;
    if (offset == 12 && qemu_chr_fe_backend_connected(&s->notify)) {
        s->pending = true;
        notify_flush(s);
    }
}

static const MemoryRegionOps register_ops = {
    .read = registers_read,
    .write = registers_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
    .valid = { .min_access_size = 4, .max_access_size = 4, .unaligned = false },
    .impl = { .min_access_size = 4, .max_access_size = 4 },
};

static void realize(PCIDevice *dev, Error **errp)
{
    PerpIVShmem *s = PERP_IVSHMEM(dev);
    MemoryRegion *memory;
    uint64_t size;
    if (!s->memdev || host_memory_backend_is_mapped(s->memdev)) {
        error_setg(errp, "memdev must be present and unused");
        return;
    }
    memory = host_memory_backend_get_memory(s->memdev);
    size = memory_region_size(memory);
    if (!memory_region_is_ram(memory) || !size || (size & (size - 1))) {
        error_setg(errp, "memdev must be RAM with power-of-two size");
        return;
    }
    memory_region_init_io(&s->registers, OBJECT(s), &register_ops, s,
                          "perp-ivshmem-registers", 256);
    pci_register_bar(dev, 0, PCI_BASE_ADDRESS_SPACE_MEMORY, &s->registers);
    pci_register_bar(dev, 2, PCI_BASE_ADDRESS_SPACE_MEMORY |
        PCI_BASE_ADDRESS_MEM_PREFETCH | PCI_BASE_ADDRESS_MEM_TYPE_64, memory);
    host_memory_backend_set_mapped(s->memdev, true);
    dev->config[PCI_COMMAND] = PCI_COMMAND_MEMORY;
    qemu_chr_fe_set_handlers(&s->notify, NULL, NULL, notify_event,
                             NULL, s, NULL, true);
}

static void device_exit(PCIDevice *dev)
{
    PerpIVShmem *s = PERP_IVSHMEM(dev);
    qemu_chr_fe_set_handlers(&s->notify, NULL, NULL, NULL, NULL, NULL, NULL, false);
    if (s->watch) {
        g_source_remove(s->watch);
        s->watch = 0;
    }
    host_memory_backend_set_mapped(s->memdev, false);
}

static const Property properties[] = {
    DEFINE_PROP_LINK("memdev", PerpIVShmem, memdev, TYPE_MEMORY_BACKEND,
                     HostMemoryBackend *),
    DEFINE_PROP_CHR("host-notify", PerpIVShmem, notify),
};

static const VMStateDescription vmstate = {
    .name = TYPE_PERP_IVSHMEM,
    .unmigratable = true,
};

static void class_init(ObjectClass *klass, void *data)
{
    DeviceClass *dc = DEVICE_CLASS(klass);
    PCIDeviceClass *pc = PCI_DEVICE_CLASS(klass);
    pc->realize = realize;
    pc->exit = device_exit;
    pc->vendor_id = 0x1af4;
    pc->device_id = 0x1110;
    pc->revision = 1;
    pc->class_id = PCI_CLASS_MEMORY_RAM;
    dc->desc = "Perpendicular IVSHMEM host-notify experiment";
    dc->vmsd = &vmstate;
    device_class_set_props(dc, properties);
}

static const TypeInfo device_type = {
    .name = TYPE_PERP_IVSHMEM,
    .parent = TYPE_PCI_DEVICE,
    .instance_size = sizeof(PerpIVShmem),
    .class_init = class_init,
    .interfaces = (InterfaceInfo[]) { { INTERFACE_CONVENTIONAL_PCI_DEVICE }, {} },
};

static void register_types(void)
{
    type_register_static(&device_type);
}
type_init(register_types)
