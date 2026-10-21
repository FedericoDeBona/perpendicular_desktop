use super::error;
use serde_json::{Value, json};
use windows::{
    Win32::{
        Devices::{DeviceAndDriverInstallation::*, Properties::*},
        Foundation::DEVPROPKEY,
    },
    core::PCWSTR,
};

struct DeviceSet(HDEVINFO);
impl Drop for DeviceSet {
    fn drop(&mut self) {
        unsafe {
            let _ = SetupDiDestroyDeviceInfoList(self.0);
        }
    }
}

/// Query SetupAPI directly: loading PowerShell's PnpDevice provider can stall
/// precisely when a display driver has failed. Include disconnected profiles.
pub fn devices() -> Result<Vec<Value>, String> {
    unsafe {
        let set = DeviceSet(
            SetupDiGetClassDevsW(
                Some(&GUID_DEVCLASS_DISPLAY),
                PCWSTR::null(),
                None,
                SETUP_DI_GET_CLASS_DEVS_FLAGS(0),
            )
            .map_err(error)?,
        );
        let mut result = Vec::new();
        for index in 0..64 {
            let mut info = SP_DEVINFO_DATA {
                cbSize: size_of::<SP_DEVINFO_DATA>() as u32,
                ..Default::default()
            };
            if let Err(e) = SetupDiEnumDeviceInfo(set.0, index, &mut info) {
                if e.code() == windows::Win32::Foundation::ERROR_NO_MORE_ITEMS.to_hresult() {
                    break;
                }
                return Err(error(e));
            }
            let mut instance = [0u16; 1024];
            SetupDiGetDeviceInstanceIdW(set.0, &info, Some(&mut instance), None).map_err(error)?;
            let instance = String::from_utf16_lossy(
                &instance[..instance
                    .iter()
                    .position(|u| *u == 0)
                    .unwrap_or(instance.len())],
            );
            let property = |key: &DEVPROPKEY| -> Value {
                let mut kind = DEVPROPTYPE::default();
                let mut bytes = [0u8; 8192];
                let mut count = 0;
                if SetupDiGetDevicePropertyW(
                    set.0,
                    &info,
                    key,
                    &mut kind,
                    Some(&mut bytes),
                    Some(&mut count),
                    0,
                )
                .is_err()
                {
                    return Value::Null;
                }
                match kind {
                    DEVPROP_TYPE_STRING => {
                        let units: Vec<u16> = bytes[..count as usize]
                            .chunks_exact(2)
                            .map(|b| u16::from_le_bytes([b[0], b[1]]))
                            .take_while(|u| *u != 0)
                            .collect();
                        json!(String::from_utf16_lossy(&units))
                    }
                    DEVPROP_TYPE_BOOLEAN if count == 1 => json!(bytes[0] != 0),
                    DEVPROP_TYPE_UINT32 if count == 4 => {
                        json!(u32::from_le_bytes(bytes[..4].try_into().unwrap()))
                    }
                    _ => Value::Null,
                }
            };
            result.push(json!({"instance":instance,"name":property(&DEVPKEY_Device_DeviceDesc),
                "present":property(&DEVPKEY_Device_IsPresent),"service":property(&DEVPKEY_Device_Service),
                "inf":property(&DEVPKEY_Device_DriverInfPath),"problem":property(&DEVPKEY_Device_ProblemCode)}));
        }
        Ok(result)
    }
}
