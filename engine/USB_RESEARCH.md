# USB passthrough investigation

Read-only investigation on 2026-10-15. No physical USB device was opened, claimed, detached, reset or assigned to a VM. The installed Windows VM and installed application were not modified. No USB engine commands or app controls have been added because the current capture path does not meet the project's permission and explicit-selection requirements.

## Runtime and inventory

The provisioned QEMU 11.1.2 executable links libusb 1.0.30 and exposes the `usb-host` device. Its available selector properties include `hostbus`, `hostaddr`, `vendorid`, `productid` and `hostport`. The signed QEMU executable currently has `com.apple.security.hypervisor` and `com.apple.security.cs.allow-jit`; it does not have `com.apple.vm.device-access`.

A direct libusb descriptor probe succeeded as the ordinary user. It enumerated nine devices on two buses, including bus zero, without calling device open, claim, detach or reset APIs. Only descriptor identities and port topology were read; no serial-number strings were requested. This establishes inventory feasibility, not device capture or guest-driver compatibility.

A future inventory implementation can use `libusb_init`, `libusb_get_device_list`, `libusb_get_device_descriptor`, `libusb_get_bus_number`, `libusb_get_device_address`, `libusb_get_port_numbers`, and cached configuration descriptors. It must examine every interface and alternate setting: a device-level class of zero or composite class does not rule out a keyboard or mouse interface. Hubs, host input devices and devices with unknown interface descriptors must be ineligible for passthrough. Bus/address are temporary identities and must be revalidated alongside VID/PID and physical port before any explicit attach. Names from IOKit can enrich inventory without opening devices for USB string requests.

## macOS capture permission

Apple's [deviceCapture documentation](https://developer.apple.com/documentation/iousbhost/iousbhostobjectinitoptions/devicecapture) requires either the capture entitlement plus device authorization, or root privileges. The [libusb 1.0.30 Darwin backend](https://github.com/libusb/libusb/blob/v1.0.30/libusb/os/darwin_usb.c) checks its own process entitlement through `SecTaskCopyValueForEntitlement`. Its detach function calls `IOServiceAuthorize` when entitled; without that entitlement and without root it returns `LIBUSB_ERROR_ACCESS`. Capture affects the entire physical device, including its other interfaces.

Devices without an existing macOS driver may work without capture. That narrower possibility does not establish support for ordinary storage, audio, camera or composite peripherals. The [libusb project FAQ](https://github.com/libusb/libusb/wiki/FAQ#how-can-i-run-libusb-applications-under-macos-if-there-is-already-a-kernel-extension-installed-for-the-device-and-claim-exclusive-access) also documents limitations around provisioning this entitlement for command-line helpers. Merely adding a key to an ad-hoc entitlements file is not a verified authorization solution.

No entitlement, root helper, driver override or permission bypass was added. A future implementation needs an authorized capture architecture in the process that owns the USB device, followed by testing with an explicitly chosen nonessential peripheral.

## QEMU behavior that needs resolution

The local upstream source is `.tools/src/qemu-11.1.2/hw/usb/host-libusb.c`. The important functions are `usb_host_realize`, `usb_host_open`, `usb_host_detach_kernel`, `usb_host_claim_interfaces` and `usb_host_auto_check`.

- `usb_host_open` attempts kernel-driver detach. Actual interface claiming happens later when the guest configures the USB device. A successful QMP `device_add` response therefore does not prove the guest can use the device or that all interfaces were acquired.
- `usb_host_realize` takes the immediate, non-autoscan route only when both bus and address are nonzero and VID, PID and port selectors are absent. Supplying bus/address together with VID/PID enables its persistent autoscan route instead. Bus zero is real on this Mac, so treating zero as an invalid bus is not a complete solution.
- The immediate route reports a generic QMP open error. Detach and claim errors are not all propagated as specific access/busy failures in the QMP response. The app must not turn `device_add` acceptance into an assertion of successful capture.

The current upstream path therefore cannot provide all three guarantees together: exact bus/address plus VID/PID identity, no persistent automatic attachment, and verified acquisition/error reporting. A narrowly scoped upstream QEMU change or a separately verified USB backend is needed before exposing this operation. It should support a one-shot selector including bus zero, atomically validate descriptor identity before opening, forbid automatic rediscovery, and surface capture/claim errors.

## Future QMP ownership contract

Before any device mutation, use the existing application lock, owned VM metadata, QMP UUID and per-launch name verification. USB host devices need their own recorded QEMU IDs tied to the current launch. Detach must accept only those recorded IDs, verify that the object is a `usb-host` device, and observe asynchronous removal completion before dropping its record. `device_del` acceptance alone is insufficient; the completion event is defined in the upstream `qapi/qdev.json` `DEVICE_DELETED` contract.

No public CLI or JSON schema is promised at this stage. Inventory can be implemented independently, but attach/detach must remain unavailable until the permission and one-shot selection requirements above are resolved. Windows USB compatibility will still require a separate, explicitly authorized physical-device test.
