//! QMP commands are issued only through a private Unix socket after checking the
//! QEMU guest UUID and this launch's unique name. No stale PID is ever signalled.
use crate::error::{Error, Result};
use serde_json::{json, Value};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::time::Duration;

pub struct Qmp {
    reader: BufReader<UnixStream>,
    sequence: u64,
}

impl Qmp {
    pub fn connect(path: &Path) -> Result<Self> {
        let stream = UnixStream::connect(path).map_err(|e| {
            Error::new(
                "qmp_unavailable",
                format!("Cannot connect to {}: {e}", path.display()),
            )
        })?;
        stream.set_read_timeout(Some(Duration::from_secs(3)))?;
        stream.set_write_timeout(Some(Duration::from_secs(3)))?;
        let mut client = Self {
            reader: BufReader::new(stream),
            sequence: 0,
        };
        let greeting = client.read_message()?;
        if greeting.get("QMP").is_none() {
            return Err(Error::new(
                "qmp_protocol",
                "Endpoint did not send a QMP greeting",
            ));
        }
        client.execute("qmp_capabilities", json!({}))?;
        Ok(client)
    }

    fn read_message(&mut self) -> Result<Value> {
        // Limit the allocation even when the socket contains an invalid peer.
        let mut bytes = Vec::new();
        loop {
            let available = self.reader.fill_buf()?;
            if available.is_empty() {
                return Err(Error::new(
                    "qmp_closed",
                    "QEMU closed the control connection",
                ));
            }
            let length = available
                .iter()
                .position(|b| *b == b'\n')
                .map_or(available.len(), |p| p + 1);
            if bytes.len() + length > 1024 * 1024 {
                return Err(Error::new("qmp_protocol", "QMP message exceeded 1 MiB"));
            }
            bytes.extend_from_slice(&available[..length]);
            self.reader.consume(length);
            if bytes.last() == Some(&b'\n') {
                return Ok(serde_json::from_slice(&bytes)?);
            }
        }
    }

    pub fn execute(&mut self, name: &str, arguments: Value) -> Result<Value> {
        self.sequence += 1;
        let id = self.sequence;
        let request = json!({"execute": name, "arguments": arguments, "id": id});
        serde_json::to_writer(self.reader.get_mut(), &request)?;
        self.reader.get_mut().write_all(b"\r\n")?;
        self.reader.get_mut().flush()?;
        for _ in 0..256 {
            let response = self.read_message()?;
            if response.get("event").is_some() {
                continue;
            }
            if response.get("id").and_then(Value::as_u64) != Some(id) {
                continue;
            }
            if let Some(error) = response.get("error") {
                return Err(Error::new(
                    "qmp_command",
                    format!(
                        "{name}: {}",
                        error
                            .get("desc")
                            .and_then(Value::as_str)
                            .unwrap_or("Unknown QMP error")
                    ),
                ));
            }
            return response.get("return").cloned().ok_or_else(|| {
                Error::new("qmp_protocol", "QMP response has neither return nor error")
            });
        }
        Err(Error::new(
            "qmp_protocol",
            "QMP response missing after 256 messages",
        ))
    }

    pub fn verify(&mut self, id: &str, launch_name: &str) -> Result<()> {
        let actual_uuid = self.execute("query-uuid", json!({}))?;
        let actual_name = self.execute("query-name", json!({}))?;
        if actual_uuid.get("UUID").and_then(Value::as_str) != Some(id)
            || actual_name.get("name").and_then(Value::as_str) != Some(launch_name)
        {
            return Err(Error::new(
                "ownership_mismatch",
                "QMP endpoint does not belong to this VM launch; no action was taken",
            ));
        }
        Ok(())
    }

    pub fn status(&mut self) -> Result<String> {
        self.execute("query-status", json!({}))?
            .get("status")
            .and_then(Value::as_str)
            .map(str::to_owned)
            .ok_or_else(|| Error::new("qmp_protocol", "query-status response is missing status"))
    }

    pub fn guest_shutdown(&mut self) -> Result<()> {
        // A paused CPU cannot process ACPI power-button delivery. Resume only
        // the already-verified VM before requesting an orderly guest shutdown.
        if matches!(self.status()?.as_str(), "paused" | "prelaunch") {
            self.execute("cont", json!({}))?;
        }
        self.execute("system_powerdown", json!({}))?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::net::UnixListener;
    use std::thread;

    #[test]
    fn negotiates_filters_events_and_checks_ownership() {
        let dir = tempfile::tempdir().unwrap();
        let socket = dir.path().join("qmp.sock");
        let listener = UnixListener::bind(&socket).unwrap();
        let worker = thread::spawn(move || {
            let (mut peer, _) = listener.accept().unwrap();
            peer.write_all(b"{\"QMP\":{\"version\":{}}}\r\n").unwrap();
            let mut reader = BufReader::new(peer.try_clone().unwrap());
            for _ in 0..4 {
                let mut line = String::new();
                reader.read_line(&mut line).unwrap();
                let input: Value = serde_json::from_str(&line).unwrap();
                let result = match input["execute"].as_str().unwrap() {
                    "qmp_capabilities" => json!({}),
                    "query-uuid" => json!({"UUID":"owned-id"}),
                    "query-name" => json!({"name":"owned-launch"}),
                    "query-status" => json!({"status":"paused"}),
                    _ => panic!("unexpected command"),
                };
                peer.write_all(b"{\"event\":\"STOP\"}\r\n").unwrap();
                writeln!(peer, "{}", json!({"return":result,"id":input["id"]})).unwrap();
            }
        });
        let mut qmp = Qmp::connect(&socket).unwrap();
        qmp.verify("owned-id", "owned-launch").unwrap();
        assert_eq!(qmp.status().unwrap(), "paused");
        worker.join().unwrap();
    }

    #[test]
    fn refuses_different_guest_without_mutation() {
        let dir = tempfile::tempdir().unwrap();
        let socket = dir.path().join("qmp.sock");
        let listener = UnixListener::bind(&socket).unwrap();
        let worker = thread::spawn(move || {
            let (mut peer, _) = listener.accept().unwrap();
            peer.write_all(b"{\"QMP\":{}}\n").unwrap();
            let mut reader = BufReader::new(peer.try_clone().unwrap());
            for command in ["qmp_capabilities", "query-uuid", "query-name"] {
                let mut line = String::new();
                reader.read_line(&mut line).unwrap();
                let input: Value = serde_json::from_str(&line).unwrap();
                assert_eq!(input["execute"], command);
                let result = if command == "query-uuid" {
                    json!({"UUID":"another-vm"})
                } else {
                    json!({"name":"another-launch"})
                };
                writeln!(peer, "{}", json!({"return":result,"id":input["id"]})).unwrap();
            }
        });
        assert_eq!(
            Qmp::connect(&socket)
                .unwrap()
                .verify("owned-id", "owned-launch")
                .unwrap_err()
                .code,
            "ownership_mismatch"
        );
        worker.join().unwrap();
    }
}
