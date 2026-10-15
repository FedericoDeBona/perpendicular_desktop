//! Explicit, bounded exchanges with an untrusted guest. No unsolicited text is
//! interpreted as instructions or applied to host clipboard/filesystem state.
use crate::error::{Error, Result};
use serde::Deserialize;
use serde_json::{json, Map, Value};
use std::fs;
use std::io::{Read, Write};
use std::os::fd::{AsRawFd, FromRawFd};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{FileTypeExt, MetadataExt};
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::time::{Duration, Instant};
use uuid::Uuid;

pub const MAX_REQUEST_BYTES: usize = 1536 * 1024;
pub const MAX_RESPONSE_BYTES: usize = 1024 * 1024;
pub const MAX_FILE_BYTES: usize = 1024 * 1024;
pub const MAX_CLIPBOARD_BYTES: usize = 256 * 1024;
const EXCHANGE_TIMEOUT: Duration = Duration::from_secs(5);

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Response {
    id: u64,
    ok: bool,
    #[serde(default)]
    result: Option<Map<String, Value>>,
    #[serde(default)]
    error: Option<AgentError>,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct AgentError {
    code: String,
    message: String,
}

pub fn exchange(path: &Path, op: &str, params: Value) -> Result<Value> {
    exchange_with_timeout(path, op, params, EXCHANGE_TIMEOUT)
}

fn exchange_with_timeout(path: &Path, op: &str, params: Value, timeout: Duration) -> Result<Value> {
    if !params.is_object() {
        return Err(Error::new(
            "guest_agent_protocol",
            "Guest request params must be an object",
        ));
    }
    let metadata=fs::symlink_metadata(path).map_err(|e|Error::new("guest_agent_unavailable",format!("Guest agent socket is unavailable; start Perpendicular Guest Tools inside Windows. {e}")))?;
    if !metadata.file_type().is_socket() || metadata.uid() != unsafe { libc::geteuid() } {
        return Err(Error::new(
            "ownership_mismatch",
            "Guest transport must be an owned Unix socket",
        ));
    }
    let random = Uuid::new_v4();
    let id = u64::from_le_bytes(random.as_bytes()[..8].try_into().unwrap()) & ((1u64 << 53) - 1);
    let mut encoded = serde_json::to_vec(&json!({"id":id,"op":op,"params":params}))?;
    if encoded.len() + 1 > MAX_REQUEST_BYTES {
        return Err(Error::new(
            "guest_request_too_large",
            "Serialized guest request exceeds1.5MiB",
        ));
    }
    encoded.push(b'\n');
    let deadline = Instant::now() + timeout;
    let mut stream = connect_before(path, deadline)?;
    let mut position = 0;
    while position < encoded.len() {
        wait_ready(&stream, libc::POLLOUT, deadline)?;
        match stream.write(&encoded[position..]) {
            Ok(0) => {
                return Err(Error::new(
                    "guest_agent_unavailable",
                    "Guest transport closed before accepting the request",
                ))
            }
            Ok(count) => position += count,
            Err(error)
                if matches!(
                    error.kind(),
                    std::io::ErrorKind::WouldBlock | std::io::ErrorKind::Interrupted
                ) =>
            {
                continue
            }
            Err(error) => return Err(transport_error(error)),
        }
    }
    let mut response = Vec::new();
    let mut buffer = [0u8; 8192];
    loop {
        wait_ready(&stream, libc::POLLIN, deadline)?;
        let count = match stream.read(&mut buffer) {
            Ok(count) => count,
            Err(error)
                if matches!(
                    error.kind(),
                    std::io::ErrorKind::WouldBlock | std::io::ErrorKind::Interrupted
                ) =>
            {
                continue
            }
            Err(error) => return Err(transport_error(error)),
        };
        if count == 0 {
            return Err(Error::new(
                "guest_agent_unavailable",
                "Guest agent closed without a complete response",
            ));
        }
        if let Some(newline) = buffer[..count].iter().position(|byte| *byte == b'\n') {
            if response.len() + newline + 1 > MAX_RESPONSE_BYTES {
                return Err(Error::new(
                    "guest_response_too_large",
                    "Guest response exceeds1MiB",
                ));
            }
            response.extend_from_slice(&buffer[..newline]);
            if buffer[newline + 1..count]
                .iter()
                .any(|byte| !byte.is_ascii_whitespace())
            {
                return Err(Error::new(
                    "guest_agent_protocol",
                    "Unsolicited data followed the guest response",
                ));
            }
            return decode_response(&response, id);
        }
        if response.len() + count >= MAX_RESPONSE_BYTES {
            return Err(Error::new(
                "guest_response_too_large",
                "Guest response exceeds1MiB",
            ));
        }
        response.extend_from_slice(&buffer[..count]);
    }
}

fn connect_before(path: &Path, deadline: Instant) -> Result<UnixStream> {
    let bytes = path.as_os_str().as_bytes();
    let mut address: libc::sockaddr_un = unsafe { std::mem::zeroed() };
    if bytes.len() >= address.sun_path.len() || bytes.contains(&0) {
        return Err(Error::new(
            "guest_agent_unavailable",
            "Guest socket path is invalid or too long",
        ));
    }
    address.sun_family = libc::AF_UNIX as libc::sa_family_t;
    for (index, byte) in bytes.iter().enumerate() {
        address.sun_path[index] = *byte as libc::c_char;
    }
    let length =
        (std::mem::offset_of!(libc::sockaddr_un, sun_path) + bytes.len() + 1) as libc::socklen_t;
    #[cfg(target_os = "macos")]
    {
        address.sun_len = length as u8;
    }
    let descriptor = unsafe { libc::socket(libc::AF_UNIX, libc::SOCK_STREAM, 0) };
    if descriptor < 0 {
        return Err(transport_error(std::io::Error::last_os_error()));
    }
    let stream = unsafe { UnixStream::from_raw_fd(descriptor) };
    if unsafe { libc::fcntl(descriptor, libc::F_SETFD, libc::FD_CLOEXEC) } < 0 {
        return Err(transport_error(std::io::Error::last_os_error()));
    }
    #[cfg(target_os = "macos")]
    {
        let enabled: libc::c_int = 1;
        if unsafe {
            libc::setsockopt(
                descriptor,
                libc::SOL_SOCKET,
                libc::SO_NOSIGPIPE,
                &enabled as *const _ as *const libc::c_void,
                std::mem::size_of_val(&enabled) as libc::socklen_t,
            )
        } < 0
        {
            return Err(transport_error(std::io::Error::last_os_error()));
        }
    }
    stream.set_nonblocking(true).map_err(transport_error)?;
    let connected = unsafe {
        libc::connect(
            stream.as_raw_fd(),
            &address as *const _ as *const libc::sockaddr,
            length,
        )
    };
    if connected < 0 {
        let error = std::io::Error::last_os_error();
        if !matches!(
            error.raw_os_error(),
            Some(libc::EINPROGRESS | libc::EWOULDBLOCK | libc::EINTR)
        ) {
            return Err(transport_error(error));
        }
        loop {
            let milliseconds = remaining(deadline)?.as_millis().clamp(1, i32::MAX as u128) as i32;
            let mut descriptor = libc::pollfd {
                fd: stream.as_raw_fd(),
                events: libc::POLLOUT,
                revents: 0,
            };
            let ready = unsafe { libc::poll(&mut descriptor, 1, milliseconds) };
            if ready == 0 {
                return Err(Error::new(
                    "guest_agent_timeout",
                    "Guest transport connection exceeded5seconds",
                ));
            }
            if ready < 0 {
                let error = std::io::Error::last_os_error();
                if error.kind() == std::io::ErrorKind::Interrupted {
                    continue;
                }
                return Err(transport_error(error));
            }
            let mut socket_error: libc::c_int = 0;
            let mut size = std::mem::size_of_val(&socket_error) as libc::socklen_t;
            if unsafe {
                libc::getsockopt(
                    stream.as_raw_fd(),
                    libc::SOL_SOCKET,
                    libc::SO_ERROR,
                    &mut socket_error as *mut _ as *mut libc::c_void,
                    &mut size,
                )
            } < 0
            {
                return Err(transport_error(std::io::Error::last_os_error()));
            }
            if socket_error != 0 {
                return Err(transport_error(std::io::Error::from_raw_os_error(
                    socket_error,
                )));
            }
            break;
        }
    }
    Ok(stream)
}

fn wait_ready(stream: &UnixStream, event: libc::c_short, deadline: Instant) -> Result<()> {
    loop {
        let milliseconds = remaining(deadline)?.as_millis().clamp(1, i32::MAX as u128) as i32;
        let mut descriptor = libc::pollfd {
            fd: stream.as_raw_fd(),
            events: event,
            revents: 0,
        };
        let ready = unsafe { libc::poll(&mut descriptor, 1, milliseconds) };
        if ready == 0 {
            return Err(Error::new(
                "guest_agent_timeout",
                "Guest agent did not complete the exchange within5seconds",
            ));
        }
        if ready < 0 {
            let error = std::io::Error::last_os_error();
            if error.kind() == std::io::ErrorKind::Interrupted {
                continue;
            }
            return Err(transport_error(error));
        }
        if descriptor.revents & libc::POLLNVAL != 0 {
            return Err(Error::new(
                "guest_agent_unavailable",
                "Guest transport descriptor became invalid",
            ));
        }
        return Ok(());
    }
}

fn remaining(deadline: Instant) -> Result<Duration> {
    let time = deadline.saturating_duration_since(Instant::now());
    if time.is_zero() {
        Err(Error::new(
            "guest_agent_timeout",
            "Guest agent did not complete the exchange within5seconds",
        ))
    } else {
        Ok(time)
    }
}

fn transport_error(error: std::io::Error) -> Error {
    if matches!(
        error.kind(),
        std::io::ErrorKind::TimedOut | std::io::ErrorKind::WouldBlock
    ) {
        Error::new(
            "guest_agent_timeout",
            "Guest agent did not complete the exchange within5seconds",
        )
    } else {
        Error::new(
            "guest_agent_unavailable",
            format!("Guest transport failed: {error}"),
        )
    }
}

fn decode_response(bytes: &[u8], id: u64) -> Result<Value> {
    let response: Response = serde_json::from_slice(bytes).map_err(|e| {
        Error::new(
            "guest_agent_protocol",
            format!("Invalid guest response envelope: {e}"),
        )
    })?;
    if response.id != id {
        return Err(Error::new(
            "guest_agent_protocol",
            "Guest response id does not match the request; unsolicited or stale data was rejected",
        ));
    }
    match (response.ok, response.result, response.error) {
        (true, Some(result), None) => Ok(Value::Object(result)),
        (false, None, Some(error)) => {
            if error.code.is_empty()
                || error.code.len() > 64
                || !error
                    .code
                    .bytes()
                    .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'_')
                || error.message.len() > 8192
            {
                return Err(Error::new(
                    "guest_agent_protocol",
                    "Guest error code/message exceeds the protocol limits",
                ));
            }
            Err(Error::new(&error.code, error.message))
        }
        _ => Err(Error::new(
            "guest_agent_protocol",
            "Guest response must contain exactly one matching success or error payload",
        )),
    }
}

pub fn validate_clipboard(text: &str) -> Result<()> {
    if text.len() > MAX_CLIPBOARD_BYTES {
        return Err(Error::new(
            "clipboard_too_large",
            "Clipboard text exceeds256KiB of UTF-8",
        ));
    }
    Ok(())
}

pub fn validate_filename(name: &str) -> Result<()> {
    if name.is_empty()
        || name.chars().count() > 128
        || name.len() > 512
        || name.ends_with(['.', ' '])
        || name
            .chars()
            .any(|c| c.is_control() || "<>:\"/\\|?*".contains(c))
    {
        return Err(Error::new("invalid_guest_filename","File name must be a Windows basename of1–128characters without path separators, reserved punctuation, controls or trailing dot/space"));
    }
    let stem = name
        .split('.')
        .next()
        .unwrap_or("")
        .trim_end_matches(' ')
        .to_uppercase();
    let device = matches!(
        stem.as_str(),
        "CON" | "PRN" | "AUX" | "NUL" | "CONIN$" | "CONOUT$"
    ) || ["COM", "LPT"].iter().any(|prefix| {
        stem.strip_prefix(prefix).is_some_and(|suffix| {
            matches!(
                suffix,
                "1" | "2" | "3" | "4" | "5" | "6" | "7" | "8" | "9" | "¹" | "²" | "³"
            )
        })
    });
    if device {
        return Err(Error::new(
            "invalid_guest_filename",
            "Windows device names cannot be used as transfer filenames",
        ));
    }
    Ok(())
}

pub fn validate_status(result: Value) -> Result<Value> {
    let mut status = result
        .as_object()
        .cloned()
        .ok_or_else(|| Error::new("guest_agent_protocol", "Guest status must be an object"))?;
    if status.get("protocol").and_then(Value::as_u64) != Some(1) {
        return Err(Error::new(
            "guest_protocol_unsupported",
            "Guest agent protocol1 is required",
        ));
    }
    for field in ["agent_version", "os_build", "architecture", "username"] {
        if !status
            .get(field)
            .and_then(Value::as_str)
            .is_some_and(|text| text.len() <= 256)
        {
            return Err(Error::new(
                "guest_agent_protocol",
                format!("Guest status has invalid {field}"),
            ));
        }
    }
    let known_state = |value: &Value| value.is_boolean() || value.as_str() == Some("unknown");
    if !status.get("secure_boot").is_some_and(known_state)
        || !status
            .get("tpm")
            .and_then(Value::as_object)
            .is_some_and(|tpm| {
                ["present", "ready"]
                    .iter()
                    .all(|key| tpm.get(*key).is_some_and(known_state))
            })
    {
        return Err(Error::new(
            "guest_agent_protocol",
            "Guest security status must contain boolean or unknown values",
        ));
    }
    let mut capabilities = status
        .get("capabilities")
        .and_then(Value::as_object)
        .cloned()
        .ok_or_else(|| {
            Error::new(
                "guest_agent_protocol",
                "Guest status has no capabilities object",
            )
        })?;
    for field in ["clipboard", "file_write"] {
        if capabilities.get(field).and_then(Value::as_bool).is_none() {
            return Err(Error::new(
                "guest_agent_protocol",
                format!("Guest capability {field} must be boolean"),
            ));
        }
    }
    // The host's enforced limits remain authoritative even if the guest claims
    // to accept larger messages or requests additional host functionality.
    capabilities.insert("max_request_bytes".into(), json!(MAX_REQUEST_BYTES));
    capabilities.insert("max_response_bytes".into(), json!(MAX_RESPONSE_BYTES));
    capabilities.insert("max_clipboard_bytes".into(), json!(MAX_CLIPBOARD_BYTES));
    capabilities.insert("max_file_bytes".into(), json!(MAX_FILE_BYTES));
    status.insert("capabilities".into(), Value::Object(capabilities));
    status.insert("connected".into(), json!(true));
    Ok(Value::Object(status))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{BufRead, BufReader};
    use std::os::unix::net::UnixListener;
    use std::thread;

    #[test]
    fn request_response_roundtrip_requires_exact_integer_id_and_envelope() {
        let dir = tempfile::tempdir().unwrap();
        let socket = dir.path().join("agent.sock");
        let listener = UnixListener::bind(&socket).unwrap();
        let worker = thread::spawn(move || {
            let (mut peer, _) = listener.accept().unwrap();
            let mut line = String::new();
            BufReader::new(peer.try_clone().unwrap())
                .read_line(&mut line)
                .unwrap();
            let request: Value = serde_json::from_str(&line).unwrap();
            assert_eq!(request["op"], "clipboard.read");
            assert!(request["id"].as_u64().is_some());
            writeln!(
                peer,
                "{}",
                json!({"id":request["id"],"ok":true,"result":{"text":"Hello\nWindows"}})
            )
            .unwrap();
        });
        assert_eq!(
            exchange(&socket, "clipboard.read", json!({})).unwrap()["text"],
            "Hello\nWindows"
        );
        worker.join().unwrap();
        for data in [
            r#"{"id":2,"ok":true,"result":{}}"#,
            r#"{"id":1.0,"ok":true,"result":{}}"#,
            r#"{"id":1,"ok":true,"result":{},"error":{"code":"x","message":"y"}}"#,
            r#"{"id":1,"ok":true,"result":[],"unsolicited":"payload"}"#,
        ] {
            assert_eq!(
                decode_response(data.as_bytes(), 1).unwrap_err().code,
                "guest_agent_protocol"
            );
        }
    }

    #[test]
    fn slow_or_oversized_guest_is_bounded_and_cannot_supply_unsolicited_messages() {
        for mode in ["timeout", "oversize", "unsolicited"] {
            let dir = tempfile::tempdir().unwrap();
            let socket = dir.path().join("agent.sock");
            let listener = UnixListener::bind(&socket).unwrap();
            let worker = thread::spawn(move || {
                let (mut peer, _) = listener.accept().unwrap();
                let mut line = String::new();
                BufReader::new(peer.try_clone().unwrap())
                    .read_line(&mut line)
                    .unwrap();
                let request: Value = serde_json::from_str(&line).unwrap();
                match mode {
                    "timeout" => thread::sleep(Duration::from_millis(100)),
                    "oversize" => {
                        let _ = peer.write_all(&vec![b'x'; MAX_RESPONSE_BYTES + 1]);
                    }
                    _ => {
                        let payload = format!(
                            "{}\n{{\"unsolicited\":true}}\n",
                            json!({"id":request["id"],"ok":true,"result":{}})
                        );
                        let _ = peer.write_all(payload.as_bytes());
                        thread::sleep(Duration::from_millis(100));
                    }
                }
            });
            let error = exchange_with_timeout(
                &socket,
                "status",
                json!({}),
                if mode == "timeout" {
                    Duration::from_millis(40)
                } else {
                    Duration::from_secs(1)
                },
            )
            .unwrap_err();
            assert_eq!(
                error.code,
                match mode {
                    "timeout" => "guest_agent_timeout",
                    "oversize" => "guest_response_too_large",
                    _ => "guest_agent_protocol",
                }
            );
            worker.join().unwrap();
        }
    }

    #[test]
    fn clipboard_and_windows_basename_constraints_are_enforced() {
        assert!(validate_filename("report italiano.txt").is_ok());
        for name in [
            "",
            "../escape.txt",
            "C:\\escape",
            "NUL.txt",
            "NUL .txt",
            "COM1",
            "lpt³.log",
            "trailing.",
            "tail ",
            "a/b",
            "new\nline",
        ] {
            assert!(validate_filename(name).is_err(), "{name}");
        }
        assert!(validate_clipboard(&"x".repeat(MAX_CLIPBOARD_BYTES)).is_ok());
        assert!(validate_clipboard(&"à".repeat(MAX_CLIPBOARD_BYTES)).is_err());
    }
}
