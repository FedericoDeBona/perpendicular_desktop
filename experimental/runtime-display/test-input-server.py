#!/usr/bin/env python3
"""QEMU11 adapter for the immutable, frozen real RFB input server regression."""
import ast
import importlib.util
import sys
sys.dont_write_bytecode = True
import inspect
from pathlib import Path
import select
import time

REPO=Path(__file__).resolve().parents[2]
spec=importlib.util.spec_from_file_location('frozen_server',REPO/'experimental/input-backpressure/test-server.py')
frozen=importlib.util.module_from_spec(spec);spec.loader.exec_module(frozen)


def real_lifetime(qmp, qt, client, work, process, peers):
    def slots():
        return qmp.command('qom-get',{'path':'/machine/peripheral/keyboard','property':'x-runtime-test-cleanup-slots'})
    def display(create):
        qmp.command('qom-set',{'path':'/machine/peripheral/keyboard','property':'x-runtime-test-display','value':create})
    def reopen():
        display(True)
        result=frozen.RFB(frozen.connect(work/'vnc.sock',process));peers.append(result.peer)
        return result
    for _ in range(5):qt.step();time.sleep(.012)
    client.keys([(ord('a'),True)])
    for _ in range(20):
        qt.step();time.sleep(.003)
        if qmp.pending():break
    assert qmp.pending()==1
    display(False)
    assert slots()==1
    # No polls: old release stays bounded while real VncState and VncDisplay
    # allocations are freed/reused. The connection helper touches owned child only.
    for _ in range(48):
        another=reopen();another.keys([(ord('b'),True)])
        qt.step();time.sleep(.003)
        display(False)
        assert slots()==1 and qmp.pending()==1
    result=reopen()
    reports=frozen.pump(qmp,qt,lambda result: slots()==0 and qmp.pending()==0 and result and frozen.keyboard_state(result[-1])==(0,set()))
    assert reports and process.poll() is None
    print('Real QEMU11 lifetime: 49 display teardowns/reopens with polls suspended remain one cleanup slot; release drains and survivor responds PASS',flush=True)
    # Actual USB input-handler removal while a cleanup is deferred must not
    # retain a freed HIDState callback. The stable keyboard probe remains usable.
    qmp.command('device_add',{'driver':'usb-kbd','id':'spare','bus':'usb.0'})
    result.keys([(ord('c'),True)])
    for _ in range(30):qt.step();time.sleep(.003)
    spare=qmp.command('qom-get',{'path':'/machine/peripheral/spare','property':'x-input-test-pending'})
    assert spare==1
    display(False)
    qmp.command('device_del',{'id':'spare'})
    deadline=time.monotonic()+4
    while slots():
        assert time.monotonic()<deadline, {'slots':slots(), 'spare':qmp.command('qom-get',{'path':'/machine/peripheral/spare','property':'x-input-test-pending'},allow_error=True), 'original_pending':qmp.pending()}
        qt.step();time.sleep(.012)
    assert 'error' in qmp.command('qom-get',{'path':'/machine/peripheral/spare','property':'x-input-test-pending'},allow_error=True)
    assert qmp.pending()==0, 'Old release reached the replacement keyboard'
    result=reopen()
    print('Real QEMU11 device removal: deferred cleanup retires safely after USB handler unregister PASS',flush=True)
    return result


class Adapter(ast.NodeTransformer):
    def visit_Constant(self,node):
        if isinstance(node.value,str):
            changes={'.tools/input-backpressure':'.tools/runtime-display','.tools/input-backpressure/full-source':'.tools/runtime-display/source','cortex-a72':'cortex-a57','virtio-gpu-pci,id=gpu,max_outputs=2':'virtio-ramfb,id=gpu,addr=7,max_outputs=2','Real public display rebind: rejects owned input without losing listener; idle rebind restores safely PASS':'Real QEMU11 internal console rebind helper: rejects pending input; idle rebind restores safely PASS'}
            if node.value in changes:node.value=changes[node.value]
        return node


def main():
    # Reuse the actual frozen test code, not a reimplementation of the parser
    # or device. Only known source/binary/device/API fixture differences change.
    source=inspect.getsource(frozen.main)
    marker='''                # Cause control on the same test device only:'''
    assert marker in source
    source=source.replace(marker,'''                b = real_lifetime(qmp, qt, b, work, process, peers)

'''+marker)
    tree=Adapter().visit(ast.parse(source));ast.fix_missing_locations(tree)
    namespace=dict(frozen.__dict__);namespace['real_lifetime']=real_lifetime
    exec(compile(tree,str(Path(__file__).resolve()),'exec'),namespace)
    namespace['main']()


if __name__=='__main__':main()
