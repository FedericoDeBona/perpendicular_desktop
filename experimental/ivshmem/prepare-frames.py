#!/usr/bin/env python3
"""Prepare private source overlays for the existing isolated IVSHMEM clone.

Never installs or starts anything. Ordinary source files are read-only inputs.
"""
import argparse
import json
from pathlib import Path
import shutil
import subprocess

REPO=Path(__file__).resolve().parents[2]
EXPERIMENT=Path(__file__).resolve().parent

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output',required=True,type=Path)
    args=parser.parse_args();out=args.output.resolve()
    assert not out.exists() and not out.is_relative_to(REPO), 'Fresh external output required'
    out.mkdir(parents=True)
    guest=out/'guest';shutil.copytree(REPO/'guest',guest,ignore=shutil.ignore_patterns('target'))
    # Reuse dependency outputs via APFS clones; never write the ordinary target directory.
    subprocess.run(['cp','-cR',str(REPO/'guest/target'),str(guest/'target')],check=True)
    shutil.copy2(EXPERIMENT/'guest/frames.rs',guest/'src/windows/ivshmem.rs')
    p=guest/'src/windows.rs';p.write_text(p.read_text().replace('mod wire;','mod wire;\nmod ivshmem;'))
    p=guest/'src/windows/wire.rs';s=p.read_text()
    s=s.replace('        self.row_alignment.store(256, Ordering::Release);','''        let worker_epoch=hello["epoch"].clone();
        let mut shared=super::ivshmem::Frames::open().ok();
        self.row_alignment.store(256, Ordering::Release);''')
    # hello is moved by send: retain the worker epoch beforehand.
    s=s.replace('        send(&mut stream, Packet { header:hello,', '        let worker_epoch=hello["epoch"].clone();\n        send(&mut stream, Packet { header:hello,')
    s=s.replace('        let worker_epoch=hello["epoch"].clone();\n        let mut shared=', '        let mut shared=')
    s=s.replace('                // Encode only the frame', '''                packet.header["guestWorkerEpoch"]=worker_epoch.clone();
                if shared.as_ref().is_some_and(|s| !s.enabled()) {shared=None;}
                if let Some(transport)=shared.as_mut() {
                    stamp(&mut packet);
                    match transport.publish(&mut packet.header,&packet.bytes) {
                        Ok(false)=>continue,
                        Ok(true)=>{
                            let mut receipt=[0u8;1];
                            if stream.read_exact(&mut receipt).is_err() || receipt[0]!=1 {
                                self.connected.store(false,Ordering::Release);
                            }
                            continue;
                        }
                        Err(_)=>{self.connected.store(false,Ordering::Release);continue;}
                    }
                }
                packet.header["transport"]=json!(if compress_frames {"tcp-lz4"}else{"tcp-raw"});
                // Encode only the frame''')
    s=s.replace('    // Stamp the actual latest packet selected for transmission, without cloning pixels.','''    stamp(&mut packet);
    let header = serde_json::to_vec(&packet.header)?;
    stream.write_all(&(header.len() as u32).to_le_bytes())?;
    stream.write_all(&header)?;
    stream.write_all(&packet.bytes)
}
fn stamp(packet:&mut Packet) {
    // Stamp the actual latest packet selected for transmission, without cloning pixels.''')
    block='''    let header = serde_json::to_vec(&packet.header)?;
    stream.write_all(&(header.len() as u32).to_le_bytes())?;
    stream.write_all(&header)?;
    stream.write_all(&packet.bytes)
}

fn frame_age'''
    assert block in s
    s=s.replace(block,'''    let mut counter=0;
    unsafe {let _=QueryPerformanceCounter(&mut counter);}
    packet.header["guestSentQPC"]=json!(counter);
}

fn frame_age''')
    p.write_text(s)
    mac=out/'macos';shutil.copytree(REPO/'macos',mac)
    shutil.copy2(EXPERIMENT/'SharedFrames.swift',mac)
    p=mac/'VirtualMachine.swift';s=p.read_text();needle='        machine = try launch("qemu-system-aarch64",arguments'
    assert s.count(needle)==1
    s=s.replace(needle,'''        arguments += ["-object", "memory-backend-file,id=ivshmem,size=64M,mem-path=\\(directory.appendingPathComponent(ExperimentalSharedFrames.name).path),share=on",
            "-chardev", "socket,id=ivshmem-notify,path=\\(ExperimentalSharedFrames.socketPath)",
            "-device", "perp-ivshmem-plain,memdev=ivshmem,host-notify=ivshmem-notify,addr=0x9"]
'''+needle);p.write_text(s)
    p=mac/'App.swift';s=p.read_text().replace('Library/Application Support/Perpendicular Restart','Library/Application Support/Perpendicular IVSHMEM Trial').replace('launcher.title="Perpendicular"','launcher.title="Perpendicular IVSHMEM Trial"')
    s=s.replace('    private var machine:VirtualMachineController!','    private var sharedFrames:ExperimentalSharedFrames?\n    private var machine:VirtualMachineController!')
    needle='            bridge.onConnection={ [weak self] value in'
    s=s.replace(needle,'''            sharedFrames=try ExperimentalSharedFrames(directory:directory,frame:{[weak self] packet in
                self?.bridge?.acceptSharedFrame(packet)
            },failed:{[weak self] in self?.bridge?.disconnect()})
'''+needle)
    s=s.replace('                if !value {\n                    self.activeApps=[]','                if !value {\n                    self.sharedFrames?.controlDisconnected()\n                    self.activeApps=[]')
    needle='        let allowed:Set<String>='
    s=s.replace(needle,'''        if command == "ivshmem_disable" {sharedFrames?.disable();localResponse(["ok":true,"result":["disabled":true]],reply:reply);return}
'''+needle)
    p.write_text(s)
    p=mac/'GuestBridge.swift';s=p.read_text()
    s=s.replace('    func cancel() { connection.cancel() }','''    func sharedReceipt(){connection.send(content:Data([1]),completion:.contentProcessed{[weak self] error in
        if error != nil {self?.connection.cancel()}
    })}
    func cancel() { connection.cancel() }''')
    s=s.replace('if ((h["capabilities"] as? [String:Any])?["frameEncodings"] as? [String])?.contains("lz4-block") == true', 'if ExperimentalSharedFrames.mode == "lz4", ((h["capabilities"] as? [String:Any])?["frameEncodings"] as? [String])?.contains("lz4-block") == true')
    s=s.replace('    private var activeFrames:UUID?', '    private var pendingShared:GuestPacket?\n    private var activeFrames:UUID?')
    s=s.replace('activeFrames=id;clients[id]?.authorize(frames:true);return', 'activeFrames=id;clients[id]?.authorize(frames:true);if let packet=pendingShared {pendingShared=nil;acceptSharedFrame(packet)};return')
    s=s.replace('activeFrames=nil;frameChannel=nil;identity=incomingIdentity','activeFrames=nil;pendingShared=nil;frameChannel=nil;identity=incomingIdentity')
    needle='    private func recordFrameTimings('
    s=s.replace(needle,'''    func acceptSharedFrame(_ packet:GuestPacket){
        guard let epoch=packet.header["guestWorkerEpoch"] as? String,identity?.hasSuffix("|"+epoch)==true else{return}
        guard let id=activeFrames,let client=clients[id] else{pendingShared=packet;return}
        client.sharedReceipt();receive(id,packet)
    }
'''+needle)
    s=s.replace('header["hostReceivedAt"]=completed','header["hostReceivedAt"]=completed;header["hostTrialReceiveAt"]=completed')
    # Per-frame data for the brief trial, shared and TCP alike.
    s=s.replace('        guard ProcessInfo.processInfo.environment["PERPENDICULAR_STATE_TRACE"]', '''        if let encoded=try? JSONSerialization.data(withJSONObject:["event":"received","hostTime":ProcessInfo.processInfo.systemUptime,"header":header],options:[.sortedKeys]) {
            ExperimentalFrameTrace.append(encoded)
        }
        guard ProcessInfo.processInfo.environment["PERPENDICULAR_STATE_TRACE"]''')
    p.write_text(s)
    p=mac/'ApplicationContent.swift';s=p.read_text();s=s.replace('    private var renderer:WindowRenderer?', '    private var trialHeader:[String:Any]=[:]\n    private var trialFrames:[UInt64:[String:Any]]=[:]\n    private var renderer:WindowRenderer?')
    s=s.replace('        self.generation=generation;source=', '        trialHeader=packet.header\n        self.generation=generation;source=')
    s=s.replace('                self?.onFramePresented?(id)','''                if let self,let header=self.trialFrames.removeValue(forKey:id),
                   let data=try? JSONSerialization.data(withJSONObject:["event":"presented","hostTime":ProcessInfo.processInfo.systemUptime,"header":header],options:[.sortedKeys]) {ExperimentalFrameTrace.append(data)}
                self?.onFramePresented?(id)''')
    # presentationID advances only when present() accepts the packet.
    assert s.count('presentationID &+= 1')==1
    s=s.replace('presentationID &+= 1','presentationID &+= 1\n        if trialFrames.count>64 {trialFrames.removeAll()};trialFrames[presentationID]=trialHeader')
    p.write_text(s)
    (mac/'ExperimentalFrameTrace.swift').write_text('''import Foundation
final class ExperimentalFrameTrace {
    static func append(_ data:Data){
        let url=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Perpendicular IVSHMEM Trial/frame-events.jsonl")
        if !FileManager.default.fileExists(atPath:url.path){FileManager.default.createFile(atPath:url.path,contents:nil,attributes:[.posixPermissions:0o600])}
        if let file=try? FileHandle(forWritingTo:url){defer{try? file.close()};_ = try? file.seekToEnd();try? file.write(contentsOf:data+Data([10]))}
    }
}
''')
    (out/'overlay.json').write_text(json.dumps({'source_commit':subprocess.check_output(['git','rev-parse','HEAD'],cwd=REPO,text=True).strip(),'experiment':'raw frames, independent source overlays','installed':False},indent=2))
    print(out)
if __name__=='__main__':main()
