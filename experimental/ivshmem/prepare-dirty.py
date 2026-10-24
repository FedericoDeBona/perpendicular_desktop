#!/usr/bin/env python3
"""Prepare one bounded dirty-rectangle qualification overlay outside the repo.

Full readback stays as the oracle; this does not claim GPU readback savings.
"""
import argparse
from pathlib import Path
import shutil
import subprocess
HERE=Path(__file__).resolve().parent

def replace(path,old,new):
    s=path.read_text();assert s.count(old)==1,(path,old[:90],s.count(old));path.write_text(s.replace(old,new))

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--output',required=True,type=Path);a=p.parse_args()
    out=a.output.resolve();subprocess.run(['python3',str(HERE/'prepare-frames.py'),'--output',str(out)],check=True)
    guest=out/'guest/src/windows';mac=out/'macos'
    shutil.copy2(HERE/'guest/dirty.rs',guest/'dirty.rs');shutil.copy2(HERE/'DirtyFrames.swift',mac/'DirtyFrames.swift')
    replace(out/'guest/src/windows.rs','mod ivshmem;','mod ivshmem;\nmod dirty;')
    replace(guest/'capture.rs','                let geometry = [size.Width, size.Height, x, y, width, height];',
        '                let trial_dirty_rects=super::dirty::rectangles(&frame,x,y,width,height);\n                let geometry = [size.Width, size.Height, x, y, width, height];')
    replace(guest/'capture.rs','"guestDirtyRegionMode":frame_dirty_mode,"guestDirtyRegionCount":dirty_regions,',
        '"guestDirtyRegionMode":frame_dirty_mode,"guestDirtyRegionCount":dirty_regions,"guestDirtyRects":trial_dirty_rects,')
    replace(guest/'worker.rs','                if command["operation"] == "trial_clock" {',
        '''                if command["operation"] == "trial_dirty_refresh" {
                    super::dirty::request_refresh();
                    outbox.control(json!({"type":"reply","request":request,"ok":true,"result":{"fullPending":true}}));
                    continue;
                }
                if command["operation"] == "trial_clock" {''')
    path=guest/'ivshmem.rs'
    replace(path,'next:u32,dropped:u64}','next:u32,dropped:u64,dirty:Option<super::dirty::Dirty>}')
    replace(path,'next:1,dropped:0}', 'next:1,dropped:0,dirty:if std::env::var("PERP_IVSHMEM_DIRTY_CHECK").as_deref()==Ok("1"){Some(super::dirty::Dirty::new())}else{None}}')
    replace(path,'  let started=Instant::now();unsafe{ptr::copy_nonoverlapping(bytes.as_ptr(),self.memory.add(base+PAYLOAD),bytes.len())};',
        '''  let prepared=self.dirty.as_mut().and_then(|d|d.prepare(header,bytes));
  let payload=prepared.as_deref().unwrap_or(bytes);
  header["sharedPayloadBytes"]=json!(payload.len());
  let started=Instant::now();unsafe{ptr::copy_nonoverlapping(payload.as_ptr(),self.memory.add(base+PAYLOAD),payload.len())};''')
    replace(path,'  header["transport"]=json!("ivshmem-raw");header["encoding"]=json!("raw");header["wireBytes"]=json!(0);',
        '  header["transport"]=json!(if self.dirty.is_some(){"ivshmem-dirty-check"}else{"ivshmem-raw"});if self.dirty.is_none(){header["encoding"]=json!("raw");}header["wireBytes"]=json!(0);')
    replace(path,'write_volatile(bytes.len() as u32);','write_volatile(payload.len() as u32);')
    replace(path,'  self.next=sequence.checked_add(1)', '  if let Some(d)=self.dirty.as_mut(){d.published(sequence);}\n  self.next=sequence.checked_add(1)')
    path=mac/'SharedFrames.swift'
    replace(path,'    private var seenShared=false','    private let dirtyFrames=ExperimentalDirtyFrames()\n    private var seenShared=false')
    replace(path,'header["transport"] as? String == "ivshmem-raw",','["ivshmem-raw","ivshmem-dirty-check"].contains(header["transport"] as? String ?? ""),')
    replace(path,'pixelCount==stride*height,header["bytes"] as? Int==pixelCount',
        'header["bytes"] as? Int==stride*height,(header["transport"] as? String == "ivshmem-dirty-check" || pixelCount==stride*height)')
    replace(path,'                let surface=GuestFrameSurface.allocate(width:width,height:height,stride:stride)',
        '''                let checking=header["transport"] as? String == "ivshmem-dirty-check"
                let surface=checking ? try dirtyFrames.reconstruct(&header,source:source,count:pixelCount,width:width,height:height,stride:stride) : GuestFrameSurface.allocate(width:width,height:height,stride:stride)''')
    replace(path,'                if let surface{surface.contents.copyMemory(from:source,byteCount:pixelCount);pixels=Data()}',
        '                if let surface{if !checking{surface.contents.copyMemory(from:source,byteCount:pixelCount)};pixels=Data()}')
    replace(path,'                if let expected=header["guestPixelsSHA256"] as? String {',
        '                if !checking,let expected=header["guestPixelsSHA256"] as? String {')
    replace(mac/'App.swift','        if command == "trial_reconnect" {',
        '''        if command == "trial_dirty_refresh",let bridge {
            bridge.command("trial_dirty_refresh"){[weak self] result in
                switch result {
                case .success(let value):self?.localResponse(["ok":true,"result":value],reply:reply)
                case .failure(let error):self?.localResponse(["ok":false,"error":error.localizedDescription],reply:reply)
                }
            };return
        }
        if command == "trial_reconnect" {''')
    print('Dirty qualification overlay ready; ordinary files unchanged:',out)

if __name__=='__main__':main()
