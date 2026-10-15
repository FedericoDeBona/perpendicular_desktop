//! Bounded physical-pixel requests. Guest acknowledgements never replace the
//! measured current mode, and the host DPI is an advisory layout hint only.
use crate::error::{Error, Result};
use serde::Deserialize;
use serde_json::{json, Value};

pub const MIN_WIDTH: u32 = 640;
pub const MIN_HEIGHT: u32 = 480;
pub const MAX_WIDTH: u32 = 3840;
pub const MAX_HEIGHT: u32 = 2160;
pub const MAX_PIXELS: u64 = 8_294_400;
pub const MIN_HOST_DPI: u32 = 96;
pub const MAX_HOST_DPI: u32 = 288;
pub const MIN_INTERVAL_MS: u32 = 750;
const MAX_MODES: usize = 128;

pub fn limits() -> Value {
    json!({"min_width":MIN_WIDTH,"min_height":MIN_HEIGHT,"max_width":MAX_WIDTH,
        "max_height":MAX_HEIGHT,"max_pixels":MAX_PIXELS,"min_host_dpi":MIN_HOST_DPI,
        "max_host_dpi":MAX_HOST_DPI,"min_interval_ms":MIN_INTERVAL_MS})
}

pub fn request(width: u32, height: u32, host_dpi: u32) -> Result<Value> {
    if !(MIN_WIDTH..=MAX_WIDTH).contains(&width)
        || !(MIN_HEIGHT..=MAX_HEIGHT).contains(&height)
        || u64::from(width) * u64::from(height) > MAX_PIXELS
        || !(MIN_HOST_DPI..=MAX_HOST_DPI).contains(&host_dpi)
    {
        return Err(Error::new("invalid_display_request",
            "Display requests require 640–3840 by 480–2160 physical pixels, at most 8294400 pixels, and host DPI 96–288"));
    }
    Ok(json!({"width":width,"height":height,"host_dpi":host_dpi}))
}

#[derive(Deserialize)]
struct Mode {
    width: u32,
    height: u32,
}

#[derive(Deserialize)]
struct Current {
    width: u32,
    height: u32,
    dpi: Option<u32>,
    device_name: String,
    adapter: String,
}

fn invalid(message: &str) -> Error {
    Error::new("guest_agent_protocol", message)
}

fn current(value: &Value) -> Result<Option<Current>> {
    if value.is_null() {
        return Ok(None);
    }
    let mode: Current = serde_json::from_value(value.clone())
        .map_err(|_| invalid("Guest display current mode is malformed"))?;
    // Reporting an existing mode is distinct from requesting one. A display
    // already above our request budget must remain visible without allocation.
    if mode.width == 0
        || mode.height == 0
        || mode.width > 16384
        || mode.height > 16384
        || mode.dpi.is_some_and(|dpi| !(48..=768).contains(&dpi))
        || mode.device_name.is_empty()
        || mode.device_name.len() > 256
        || mode.adapter.len() > 512
        || mode.device_name.contains('\0')
        || mode.adapter.contains('\0')
    {
        return Err(invalid(
            "Guest display current mode exceeds reporting bounds",
        ));
    }
    Ok(Some(mode))
}

fn reason(value: &Value) -> Result<()> {
    if value.is_null() || value.as_str().is_some_and(|text| text.len() <= 1024) {
        Ok(())
    } else {
        Err(invalid("Guest display reason is malformed or too large"))
    }
}

pub fn validate_status(mut result: Value) -> Result<Value> {
    let can_resize = result
        .get("can_resize")
        .and_then(Value::as_bool)
        .ok_or_else(|| invalid("Guest display resize capability must be boolean"))?;
    reason(
        result
            .get("reason")
            .ok_or_else(|| invalid("Guest display reason is missing"))?,
    )?;
    let measured = current(
        result
            .get("current")
            .ok_or_else(|| invalid("Guest current display is missing"))?,
    )?;
    let modes = result
        .get("modes")
        .and_then(Value::as_array)
        .filter(|modes| modes.len() <= MAX_MODES)
        .ok_or_else(|| invalid("Guest display modes are missing or exceed 128 entries"))?;
    let mut seen = std::collections::HashSet::new();
    let mut alternative = false;
    for value in modes {
        let mode: Mode = serde_json::from_value(value.clone())
            .map_err(|_| invalid("Guest display mode is malformed"))?;
        request(mode.width, mode.height, MIN_HOST_DPI).map_err(|_| {
            invalid("Guest display advertises a mode outside the host pixel budget")
        })?;
        if !seen.insert((mode.width, mode.height)) {
            return Err(invalid("Guest display modes contain duplicates"));
        }
        alternative |= measured
            .as_ref()
            .is_some_and(|m| (m.width, m.height) != (mode.width, mode.height));
    }
    if can_resize && (measured.is_none() || !alternative) {
        return Err(invalid(
            "Guest resize capability has no measured alternative mode",
        ));
    }
    if result.get("dpi_change_supported").and_then(Value::as_bool) != Some(false) {
        return Err(invalid(
            "This display protocol cannot change Windows DPI scaling",
        ));
    }
    result["connected"] = json!(true);
    result["limits"] = limits();
    Ok(result)
}

pub fn unavailable(code: &str, message: &str) -> Value {
    json!({"connected":false,"can_resize":false,"code":code,"reason":message,
        "current":null,"modes":[],"dpi_change_supported":false,"limits":limits()})
}

pub fn validate_resize(result: Value, requested: &Value) -> Result<Value> {
    let applied = result
        .get("applied")
        .and_then(Value::as_bool)
        .ok_or_else(|| invalid("Guest display result has no applied boolean"))?;
    let changed = result
        .get("changed")
        .and_then(Value::as_bool)
        .ok_or_else(|| invalid("Guest display result has no changed boolean"))?;
    let code = result
        .get("code")
        .and_then(Value::as_str)
        .ok_or_else(|| invalid("Guest display result has no code"))?;
    if code.is_empty()
        || code.len() > 64
        || !code
            .bytes()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'_')
        || result.get("requested") != Some(requested)
        || result.get("dpi_changed").and_then(Value::as_bool) != Some(false)
        || result
            .get("retry_after_ms")
            .and_then(Value::as_u64)
            .is_none_or(|delay| delay > u64::from(MIN_INTERVAL_MS))
    {
        return Err(invalid(
            "Guest display acknowledgement does not match its request or protocol limits",
        ));
    }
    reason(
        result
            .get("reason")
            .ok_or_else(|| invalid("Guest display result reason is missing"))?,
    )?;
    let actual = current(
        result
            .get("actual")
            .ok_or_else(|| invalid("Guest actual display is missing"))?,
    )?;
    if (changed && !applied)
        || (applied
            && !actual.is_some_and(|mode| {
                Some(u64::from(mode.width)) == requested["width"].as_u64()
                    && Some(u64::from(mode.height)) == requested["height"].as_u64()
            }))
    {
        return Err(invalid(
            "Guest reported display success without the requested actual resolution",
        ));
    }
    Ok(result)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn measured(width: u32, height: u32) -> Value {
        json!({"width":width,"height":height,"dpi":null,"device_name":r"\\.\DISPLAY1","adapter":"Fixture display"})
    }

    #[test]
    fn dimensions_dpi_and_pixel_budget_are_validated_before_ipc() {
        assert!(request(3840, 2160, 288).is_ok());
        for args in [
            (0, 600, 96),
            (639, 600, 96),
            (800, 479, 96),
            (3841, 2160, 96),
            (1920, 2161, 96),
            (800, 600, 95),
            (800, 600, 289),
            (u32::MAX, u32::MAX, 96),
        ] {
            assert_eq!(
                request(args.0, args.1, args.2).unwrap_err().code,
                "invalid_display_request"
            );
        }
    }

    #[test]
    fn fixed_driver_and_unavailable_agent_never_claim_resize_support() {
        let status = json!({"can_resize":false,"reason":"The driver exposes one mode",
            "current":measured(800,600),"modes":[{"width":800,"height":600}],"dpi_change_supported":false});
        assert_eq!(
            validate_status(status.clone()).unwrap()["can_resize"],
            false
        );
        let mut lie = status.clone();
        lie["can_resize"] = json!(true);
        assert!(validate_status(lie).is_err());
        let mut duplicate = status;
        duplicate["modes"]
            .as_array_mut()
            .unwrap()
            .push(json!({"width":800,"height":600}));
        assert!(validate_status(duplicate).is_err());
        assert_eq!(
            unavailable("unsupported_operation", "Upgrade guest tools")["connected"],
            false
        );
    }

    #[test]
    fn resize_requires_matching_measured_resolution_and_keeps_failures_visible() {
        let requested = request(1280, 720, 192).unwrap();
        let mut result = json!({"applied":true,"changed":true,"code":"resized","reason":null,
            "requested":requested,"actual":measured(1280,720),"dpi_changed":false,"retry_after_ms":0});
        assert!(validate_resize(result.clone(), &requested).is_ok());
        result["actual"] = measured(800, 600);
        assert!(validate_resize(result.clone(), &requested).is_err());
        result["applied"] = json!(false);
        result["changed"] = json!(false);
        result["code"] = json!("display_mode_unsupported");
        assert_eq!(
            validate_resize(result.clone(), &requested).unwrap()["actual"]["width"],
            800
        );
        result["requested"]["width"] = json!(1920);
        assert!(validate_resize(result, &requested).is_err());
    }
}
