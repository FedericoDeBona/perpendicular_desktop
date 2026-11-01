//! Read the installed hardware driver's video decoder profiles without a browser.
//! This does not install a driver, change settings, or exercise video playback.

#[cfg(windows)]
fn main() -> Result<(), Box<dyn std::error::Error>> {
    use serde_json::json;
    use windows::{
        Win32::{
            Foundation::HMODULE,
            Graphics::{
                Direct3D::{D3D_DRIVER_TYPE_HARDWARE, D3D_FEATURE_LEVEL_11_0},
                Direct3D11::*,
                Dxgi::IDXGIDevice,
            },
        },
        core::Interface,
    };

    unsafe {
        let mut device = None;
        let mut level = D3D_FEATURE_LEVEL_11_0;
        D3D11CreateDevice(
            None,
            D3D_DRIVER_TYPE_HARDWARE,
            HMODULE::default(),
            D3D11_CREATE_DEVICE_BGRA_SUPPORT,
            Some(&[D3D_FEATURE_LEVEL_11_0]),
            D3D11_SDK_VERSION,
            Some(&mut device),
            Some(&mut level),
            None,
        )?;
        let device = device.ok_or("D3D11 returned no device")?;
        let adapter = device.cast::<IDXGIDevice>()?.GetAdapter()?.GetDesc()?;
        let name = String::from_utf16_lossy(
            &adapter.Description[..adapter
                .Description
                .iter()
                .position(|c| *c == 0)
                .unwrap_or(128)],
        );
        let mut result = json!({
            "adapter": name,
            "vendorID": adapter.VendorId,
            "deviceID": adapter.DeviceId,
            "featureLevel": format!("0x{:x}", level.0),
        });
        match device.cast::<ID3D11VideoDevice>() {
            Ok(video) => {
                let count = video.GetVideoDecoderProfileCount();
                let mut profiles = Vec::new();
                for index in 0..count {
                    profiles.push(format!("{:?}", video.GetVideoDecoderProfile(index)?));
                }
                result["videoDevice"] = json!(true);
                result["decoderProfileCount"] = json!(count);
                result["decoderProfiles"] = json!(profiles);
            }
            Err(error) => {
                result["videoDevice"] = json!(false);
                result["videoDeviceHRESULT"] = json!(format!("0x{:08x}", error.code().0 as u32));
            }
        }
        println!("{}", result);
    }
    Ok(())
}

#[cfg(not(windows))]
fn main() {
    eprintln!("Run this diagnostic inside Windows.");
    std::process::exit(1);
}
