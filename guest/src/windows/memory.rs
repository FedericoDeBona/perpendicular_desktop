use serde_json::{Value, json};
use std::mem::size_of;
use windows::Win32::System::SystemInformation::{GlobalMemoryStatusEx, MEMORYSTATUSEX};

/// Read the current memory manager totals, including memory added at runtime.
/// No allocation, privilege change, driver dependency or WGC work is required.
pub fn status() -> Result<Value, String> {
    let mut state = MEMORYSTATUSEX {
        dwLength: size_of::<MEMORYSTATUSEX>() as u32,
        ..Default::default()
    };
    unsafe { GlobalMemoryStatusEx(&mut state) }.map_err(super::error)?;
    Ok(json!({
        "totalPhysicalBytes": state.ullTotalPhys,
        "availablePhysicalBytes": state.ullAvailPhys,
        "memoryLoadPercent": state.dwMemoryLoad,
        "commitLimitBytes": state.ullTotalPageFile,
        "availableCommitBytes": state.ullAvailPageFile,
    }))
}
