#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Read-only validation against existing pinned headers; no fetch or Windows run."""
import argparse
import hashlib
import json
from pathlib import Path
import re

HERE = Path(__file__).resolve().parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--headers', type=Path, default=HERE.parents[1] / '.tools/graphics-experiment/src/dxmt/include/native/directx')
args = parser.parse_args()
source = (HERE / 'D3D11Probe.cs').read_text()
constants = {name: int(value) for name, value in re.findall(r'internal const int (\w+)Slot = (\d+);', source)}
checks = {
    'd3d11.h': {
        'ID3D11Device': ['QueryInterface', 'Release', 'CreateRenderTargetView', 'GetDeviceRemovedReason'],
    },
    'd3d11_1.h': {'ID3D11DeviceContext1': ['ClearView']},
    'dxgi.h': {'IDXGIDevice': ['GetAdapter'], 'IDXGIAdapter1': ['GetDesc1'],
               'IDXGISwapChain': ['Present', 'GetBuffer', 'SetFullscreenState', 'GetFullscreenState', 'ResizeBuffers']},
    'dxgi1_2.h': {'IDXGIFactory2': ['GetParent', 'MakeWindowAssociation', 'CreateSwapChainForHwnd']},
}
guids = {
    'DxgiDeviceId': ('dxgi.h', 'IDXGIDevice'),
    'Adapter1Id': ('dxgi.h', 'IDXGIAdapter1'),
    'Factory2Id': ('dxgi1_2.h', 'IDXGIFactory2'),
    'Context1Id': ('d3d11_1.h', 'ID3D11DeviceContext1'),
    'Texture2DId': ('d3d11.h', 'ID3D11Texture2D'),
}
receipts = []
for file, interfaces in checks.items():
    data = (args.headers / file).read_bytes()
    text = data.decode()
    for interface, methods in interfaces.items():
        body = text.split('typedef struct ' + interface + 'Vtbl {', 1)[1].split('} ' + interface + 'Vtbl;', 1)[0]
        names = re.findall(r'\(STDMETHODCALLTYPE \*(\w+)\)', body)
        for name in methods:
            assert names.index(name) == constants[name], (interface, name, names.index(name), constants[name])
    receipts.append({'header': file, 'sha256': hashlib.sha256(data).hexdigest()})
for field, (file, interface) in guids.items():
    text = (args.headers / file).read_text()
    fields = re.search(r'DEFINE_GUID\(IID_' + interface + r',\s*([^;]+)\);', text).group(1).split(',')
    numbers = [int(field.strip(), 0) for field in fields]
    expected = '{:08x}-{:04x}-{:04x}-{:02x}{:02x}-'.format(*numbers[:5]) + ''.join('{:02x}'.format(number) for number in numbers[5:])
    actual = re.search(r'Guid ' + field + r' = new Guid\("([^"]+)"\)', source).group(1)
    assert actual == expected, (field, actual, expected)
print(json.dumps({'result': 'PASS', 'vtable_slots': len(constants), 'interface_guids': len(guids), 'headers': receipts}, indent=2))
