use serde_json::{Value, json};
use std::{
    collections::{HashMap, VecDeque},
    io::{Read, Write},
    net::TcpStream,
    sync::{
        Arc, Condvar, Mutex,
        atomic::{AtomicBool, AtomicUsize, Ordering},
    },
    time::Duration,
};

pub struct Packet {
    pub header: Value,
    pub bytes: Vec<u8>,
}
#[derive(Default)]
struct Pending {
    controls: VecDeque<Packet>,
    frames: HashMap<String, Packet>,
    order: VecDeque<String>,
}
pub struct Outbox {
    pending: Mutex<Pending>,
    wake: Condvar,
    frame_wake: Condvar,
    split: AtomicBool,
    row_alignment: AtomicUsize,
    pub connected: AtomicBool,
}

impl Outbox {
    pub fn new() -> Arc<Self> {
        Arc::new(Self {
            pending: Mutex::new(Pending::default()),
            wake: Condvar::new(),
            frame_wake: Condvar::new(),
            split: AtomicBool::new(false),
            row_alignment: AtomicUsize::new(4),
            connected: AtomicBool::new(true),
        })
    }
    pub fn control(&self, header: Value) {
        let mut pending = self.pending.lock().unwrap();
        if pending.controls.len() >= 128 {
            self.connected.store(false, Ordering::Release);
            return;
        }
        pending.controls.push_back(Packet {
            header,
            bytes: Vec::new(),
        });
        self.wake.notify_one();
    }
    pub fn frame(&self, id: &str, header: Value, bytes: Vec<u8>) {
        let mut pending = self.pending.lock().unwrap();
        if !pending.frames.contains_key(id) {
            pending.order.push_back(id.to_owned());
        }
        pending
            .frames
            .insert(id.to_owned(), Packet { header, bytes });
        if !self.split.load(Ordering::Acquire) {
            self.wake.notify_one();
        }
        self.frame_wake.notify_one();
    }
    pub fn row_alignment(&self) -> usize { self.row_alignment.load(Ordering::Acquire) }
    /// Enabled only after the host requests the optional authenticated pixel
    /// connection. Older hosts keep the original combined stream.
    pub fn start_frames(self: Arc<Self>, mut stream: TcpStream, hello: Value) -> Result<(), String> {
        stream.set_nodelay(true).map_err(super::error)?;
        stream.set_write_timeout(Some(Duration::from_secs(3))).map_err(super::error)?;
        stream.set_read_timeout(Some(Duration::from_secs(5))).map_err(super::error)?;
        send(&mut stream, &Packet { header:hello, bytes:Vec::new() }).map_err(super::error)?;
        self.row_alignment.store(256, Ordering::Release);
        self.split.store(true, Ordering::Release);
        self.wake.notify_one();
        while self.connected.load(Ordering::Acquire) {
            let packet = {
                let mut pending = self.pending.lock().unwrap();
                if pending.order.is_empty() {
                    pending = self.frame_wake.wait_timeout(pending, Duration::from_secs(2)).unwrap().0;
                }
                pending.order.pop_front().and_then(|id| pending.frames.remove(&id))
            };
            if let Some(packet) = packet {
                let mut receipt = [0u8;1];
                if send(&mut stream, &packet).is_err() || stream.read_exact(&mut receipt).is_err() || receipt[0] != 1 {
                    self.connected.store(false, Ordering::Release);
                }
            }
        }
        let _ = stream.shutdown(std::net::Shutdown::Both);
        self.wake.notify_one();
        Ok(())
    }
    pub fn retire(&self, id: &str) {
        let mut pending = self.pending.lock().unwrap();
        pending.frames.remove(id);
        pending.order.retain(|value| value != id);
    }
    pub fn writer(self: Arc<Self>, mut stream: TcpStream) {
        let _ = stream.set_write_timeout(Some(Duration::from_secs(3)));
        while self.connected.load(Ordering::Acquire) {
            let packet = {
                let mut pending = self.pending.lock().unwrap();
                if pending.controls.is_empty() && (pending.order.is_empty() || self.split.load(Ordering::Acquire)) {
                    pending = self
                        .wake
                        .wait_timeout(pending, Duration::from_secs(2))
                        .unwrap()
                        .0;
                }
                if let Some(value) = pending.controls.pop_front() {
                    value
                } else if !self.split.load(Ordering::Acquire) && !pending.order.is_empty() {
                    let id = pending.order.pop_front().unwrap();
                    match pending.frames.remove(&id) {
                        Some(p) => p,
                        None => continue,
                    }
                } else {
                    Packet {
                        header: json!({"type":"heartbeat"}),
                        bytes: Vec::new(),
                    }
                }
            };
            if send(&mut stream, &packet).is_err() {
                self.connected.store(false, Ordering::Release);
            }
        }
        let _ = stream.shutdown(std::net::Shutdown::Both);
    }
}

pub fn send(stream: &mut TcpStream, packet: &Packet) -> std::io::Result<()> {
    let header = serde_json::to_vec(&packet.header)?;
    stream.write_all(&(header.len() as u32).to_le_bytes())?;
    stream.write_all(&header)?;
    stream.write_all(&packet.bytes)
}

pub fn read(stream: &mut TcpStream) -> Result<Value, String> {
    let mut prefix = [0; 4];
    stream.read_exact(&mut prefix).map_err(super::error)?;
    let size = u32::from_le_bytes(prefix) as usize;
    if size == 0 || size > 16384 {
        return Err("invalid command size".into());
    }
    let mut bytes = vec![0; size];
    stream.read_exact(&mut bytes).map_err(super::error)?;
    serde_json::from_slice(&bytes).map_err(super::error)
}
