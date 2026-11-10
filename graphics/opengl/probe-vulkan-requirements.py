#!/usr/bin/env python3
"""Enumerate actual NX2navi prerequisites from an explicit ICD; no device changes.

Run with matching Python/ICD architecture in Windows, or with MoltenVK on Mac.
An ICD manifest's api_version is not a physical-device capability report.
"""
import argparse
import ctypes as c
import json
import struct
import sys


class Application(c.Structure):
    _fields_ = [('sType', c.c_uint32), ('pNext', c.c_void_p),
                ('name', c.c_char_p), ('version', c.c_uint32),
                ('engine', c.c_char_p), ('engineVersion', c.c_uint32),
                ('apiVersion', c.c_uint32)]


class InstanceInfo(c.Structure):
    _fields_ = [('sType', c.c_uint32), ('pNext', c.c_void_p),
                ('flags', c.c_uint32), ('app', c.POINTER(Application)),
                ('layerCount', c.c_uint32), ('layers', c.c_void_p),
                ('extensionCount', c.c_uint32), ('extensions', c.c_void_p)]


def probe(path, minor):
    windows = sys.platform == 'win32'
    library = (c.WinDLL if windows else c.CDLL)(path)
    get = getattr(library, 'vk_icdGetInstanceProcAddr', None)
    if get is None:
        get = library.vkGetInstanceProcAddr
    get.argtypes, get.restype = [c.c_void_p, c.c_char_p], c.c_void_p
    prototype = c.WINFUNCTYPE if windows else c.CFUNCTYPE

    def function(name, result, arguments, instance=None):
        address = get(instance, name.encode())
        if not address:
            raise RuntimeError('Missing entry point: ' + name)
        return prototype(result, *arguments)(address)

    def extensions(enumerate_call):
        count = c.c_uint32()
        result = enumerate_call(c.byref(count), None)
        if result != 0:
            raise RuntimeError('Extension count failed: ' + str(result))
        data = c.create_string_buffer(max(count.value, 1) * 260)
        result = enumerate_call(c.byref(count), data)
        if result != 0:
            raise RuntimeError('Extension enumeration failed: ' + str(result))
        return [data.raw[i * 260:i * 260 + 256].split(b'\0')[0].decode()
                for i in range(count.value)]

    enumerate_instance = function('vkEnumerateInstanceExtensionProperties', c.c_int,
                                 [c.c_char_p, c.c_void_p, c.c_void_p])
    available = extensions(lambda n, p: enumerate_instance(None, n, p))
    portability = b'VK_KHR_portability_enumeration'
    names = (c.c_char_p * 1)(portability)
    use_portability = portability.decode() in available
    app = Application(0, None, b'Perpendicular prerequisites', 0, None, 0,
                      (1 << 22) | (minor << 12))
    info = InstanceInfo(1, None, int(use_portability), c.pointer(app), 0, None,
                        int(use_portability), c.cast(names, c.c_void_p))
    instance = c.c_void_p()
    result = function('vkCreateInstance', c.c_int, [c.c_void_p] * 3)(
        c.byref(info), None, c.byref(instance))
    report = {'icd': path, 'requested_api': '1.' + str(minor),
              'create_instance': result, 'devices': []}
    if result != 0:
        return report
    try:
        enumerate_devices = function('vkEnumeratePhysicalDevices', c.c_int,
                                     [c.c_void_p] * 3, instance)
        count = c.c_uint32()
        result = enumerate_devices(instance, c.byref(count), None)
        if result != 0:
            raise RuntimeError('Device count failed: ' + str(result))
        devices = (c.c_void_p * count.value)()
        result = enumerate_devices(instance, c.byref(count), devices)
        if result != 0:
            raise RuntimeError('Device enumeration failed: ' + str(result))
        properties = function('vkGetPhysicalDeviceProperties', None,
                              [c.c_void_p] * 2, instance)
        enumerate_extensions = function('vkEnumerateDeviceExtensionProperties',
                                       c.c_int, [c.c_void_p] * 4, instance)
        for device in devices:
            data = c.create_string_buffer(4096)
            properties(device, data)
            version, _, _, _, kind = struct.unpack_from('5I', data.raw)
            supported = extensions(lambda n, p: enumerate_extensions(device, None, n, p))
            required = {name: name in supported for name in
                        ('VK_EXT_mesh_shader', 'VK_EXT_external_memory_host',
                         'VK_KHR_synchronization2', 'VK_KHR_dynamic_rendering')}
            report['devices'].append({
                'name': data.raw[20:276].split(b'\0')[0].decode(), 'type': kind,
                'api': f'{version >> 22}.{(version >> 12) & 1023}.{version & 4095}',
                'required_extensions': required,
                'extension_count': len(supported)})
    finally:
        function('vkDestroyInstance', None, [c.c_void_p] * 2, instance)(instance, None)
    return report


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('icd')
    parser.add_argument('--api-minor', type=int, choices=(1, 2, 3), default=3)
    args = parser.parse_args()
    print(json.dumps(probe(args.icd, args.api_minor), indent=2))
