use super::error;
use serde_json::{Value, json};
use windows::{
    Win32::{
        Devices::{DeviceAndDriverInstallation::*, Properties::*},
        Foundation::DEVPROPKEY,
        System::Registry::{
            HKEY, KEY_QUERY_VALUE, REG_BINARY, REG_VALUE_TYPE, RegCloseKey, RegQueryValueExW,
        },
    },
    core::{PCWSTR, w},
};

struct DeviceSet(HDEVINFO);
impl Drop for DeviceSet {
    fn drop(&mut self) {
        unsafe {
            let _ = SetupDiDestroyDeviceInfoList(self.0);
        }
    }
}

struct DeviceKey(HKEY);
impl Drop for DeviceKey {
    fn drop(&mut self) {
        unsafe {
            let _ = RegCloseKey(self.0);
        }
    }
}

/// Query SetupAPI directly: loading PowerShell's PnpDevice provider can stall
/// precisely when a display driver has failed. Keep adapter history, but report
/// only present monitors. This inventory remains separate from display_info.
pub fn devices() -> Result<Vec<Value>, String> {
    let mut result = class_devices(
        &GUID_DEVCLASS_DISPLAY,
        "display",
        SETUP_DI_GET_CLASS_DEVS_FLAGS(0),
        64,
    )?;
    result.extend(class_devices(
        &GUID_DEVCLASS_MONITOR,
        "monitor",
        DIGCF_PRESENT,
        16,
    )?);
    Ok(result)
}

fn class_devices(
    class: &windows::core::GUID,
    kind: &str,
    flags: SETUP_DI_GET_CLASS_DEVS_FLAGS,
    limit: u32,
) -> Result<Vec<Value>, String> {
    unsafe {
        let set = DeviceSet(
            SetupDiGetClassDevsW(Some(class), PCWSTR::null(), None, flags).map_err(error)?,
        );
        let mut result = Vec::new();
        for index in 0..limit {
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
                    || count as usize > bytes.len()
                {
                    return Value::Null;
                }
                match kind {
                    DEVPROP_TYPE_STRING if count % 2 == 0 => {
                        let units: Vec<u16> = bytes[..count as usize]
                            .chunks_exact(2)
                            .map(|b| u16::from_le_bytes([b[0], b[1]]))
                            .take_while(|u| *u != 0)
                            .collect();
                        json!(
                            String::from_utf16_lossy(&units)
                                .chars()
                                .take(512)
                                .collect::<String>()
                        )
                    }
                    DEVPROP_TYPE_BOOLEAN if count == 1 => json!(bytes[0] != 0),
                    DEVPROP_TYPE_UINT32 if count == 4 => {
                        json!(u32::from_le_bytes(bytes[..4].try_into().unwrap()))
                    }
                    _ => Value::Null,
                }
            };
            let mut device = json!({"class":kind,"instance":instance,"name":property(&DEVPKEY_Device_DeviceDesc),
                "present":property(&DEVPKEY_Device_IsPresent),"service":property(&DEVPKEY_Device_Service),
                "inf":property(&DEVPKEY_Device_DriverInfPath),"problem":property(&DEVPKEY_Device_ProblemCode),
                "status":property(&DEVPKEY_Device_DevNodeStatus)});
            if kind == "monitor" {
                device["edid"] = match read_edid(set.0, &info) {
                    Ok(bytes) => parse_edid(&bytes).unwrap_or_else(
                        |message| json!({"available":true,"valid":false,"message":message}),
                    ),
                    Err(message) => json!({"available":false,"valid":false,"message":message}),
                };
            }
            result.push(device);
        }
        Ok(result)
    }
}

fn read_edid(set: HDEVINFO, info: &SP_DEVINFO_DATA) -> Result<Vec<u8>, String> {
    unsafe {
        let key = DeviceKey(
            SetupDiOpenDevRegKey(
                set,
                info,
                DICS_FLAG_GLOBAL.0,
                0,
                DIREG_DEV,
                KEY_QUERY_VALUE.0,
            )
            .map_err(error)?,
        );
        let mut bytes = [0u8; 4096];
        let mut count = bytes.len() as u32;
        let mut kind = REG_VALUE_TYPE::default();
        RegQueryValueExW(
            key.0,
            w!("EDID"),
            None,
            Some(&mut kind),
            Some(bytes.as_mut_ptr()),
            Some(&mut count),
        )
        .ok()
        .map_err(error)?;
        if kind != REG_BINARY || !(128..=4096).contains(&count) {
            return Err("Monitor EDID is not a bounded binary value".into());
        }
        Ok(bytes[..count as usize].to_vec())
    }
}

/// Decode only public EDID identity and physical dimensions, never export the blob.
fn parse_edid(bytes: &[u8]) -> Result<Value, String> {
    if !(128..=4096).contains(&bytes.len())
        || bytes.len() % 128 != 0
        || bytes[..8] != [0, 255, 255, 255, 255, 255, 255, 0]
    {
        return Err("Invalid EDID header or length".into());
    }
    if bytes[18] != 1 || bytes[19] > 4 {
        return Err("Unsupported EDID version".into());
    }
    if bytes.len() != (usize::from(bytes[126]) + 1) * 128
        || bytes
            .chunks_exact(128)
            .any(|block| block.iter().fold(0u8, |sum, byte| sum.wrapping_add(*byte)) != 0)
    {
        return Err("Invalid EDID extension count or checksum".into());
    }
    let manufacturer = u16::from_be_bytes([bytes[8], bytes[9]]);
    let letters = [
        (manufacturer >> 10) & 31,
        (manufacturer >> 5) & 31,
        manufacturer & 31,
    ];
    if manufacturer & 0x8000 != 0 || letters.iter().any(|letter| !(1..=26).contains(letter)) {
        return Err("Invalid EDID manufacturer identity".into());
    }
    let manufacturer: String = letters
        .into_iter()
        .map(|letter| char::from(b'A' + letter as u8 - 1))
        .collect();
    let mut physical = None;
    let mut name = None;
    let mut serial_text = None;
    for descriptor in bytes[54..126].chunks_exact(18) {
        if descriptor[0] != 0 || descriptor[1] != 0 {
            let width = u16::from(descriptor[12]) | (u16::from(descriptor[14] & 0xf0) << 4);
            let height = u16::from(descriptor[13]) | (u16::from(descriptor[14] & 0x0f) << 8);
            if physical.is_none() && width > 0 && height > 0 {
                physical = Some((width, height));
            }
        } else if descriptor[2] == 0 && descriptor[4] == 0 && [0xfc, 0xff].contains(&descriptor[3])
        {
            let text: Vec<u8> = descriptor[5..18]
                .iter()
                .copied()
                .take_while(|byte| *byte != 10 && *byte != 0)
                .collect();
            if text.iter().all(|byte| (32..=126).contains(byte)) {
                let text = String::from_utf8(text).unwrap().trim().to_string();
                if !text.is_empty() {
                    if descriptor[3] == 0xfc {
                        name = Some(text);
                    } else {
                        serial_text = Some(text);
                    }
                }
            }
        }
    }
    // Base fields are centimetres (or aspect ratio in EDID 1.4 when one is zero).
    let source = if physical.is_some() {
        Some("detailedTiming")
    } else if bytes[21] > 0 && bytes[22] > 0 {
        physical = Some((u16::from(bytes[21]) * 10, u16::from(bytes[22]) * 10));
        Some("baseCentimetres")
    } else {
        None
    };
    Ok(
        json!({"available":true,"valid":true,"bytes":bytes.len(),"version":format!("{}.{}",bytes[18],bytes[19]),
        "manufacturer":manufacturer,"product":u16::from_le_bytes([bytes[10],bytes[11]]),
        "serial":u32::from_le_bytes(bytes[12..16].try_into().unwrap()),"serialText":serial_text,"name":name,
        "physicalWidthMM":physical.map(|size|size.0),"physicalHeightMM":physical.map(|size|size.1),
        "physicalSizeSource":source,"baseWidthCM":bytes[21],"baseHeightCM":bytes[22]}),
    )
}
