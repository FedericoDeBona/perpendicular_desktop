//! Explicit topology diagnostics, primary selection and exact extended layout.
//! Reading does not start a graphics device. Applying verifies Windows' result.
use serde::Deserialize;
use serde_json::{Value, json};
use std::{collections::BTreeSet, thread, time::Duration};
use windows::Win32::{
    Devices::{Display::*, DeviceAndDriverInstallation::{CM_Get_Device_Interface_PropertyW, CR_SUCCESS},
        Properties::{DEVPKEY_Device_InstanceId, DEVPROP_TYPE_STRING, DEVPROPTYPE}},
    Foundation::{ERROR_INSUFFICIENT_BUFFER, ERROR_SUCCESS},
    Foundation::RECT,
};
use windows::core::PCWSTR;

struct Topology {
    paths: Vec<DISPLAYCONFIG_PATH_INFO>,
    modes: Vec<DISPLAYCONFIG_MODE_INFO>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Layout {
    device: String,
    x: i32,
    y: i32,
    width: u32,
    height: u32,
    primary: bool,
    #[serde(default)]
    dpi: Option<u32>,
    #[serde(default, rename = "workArea")]
    work_area: Option<Area>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Area { x: i32, y: i32, width: i32, height: i32 }

impl Topology {
    fn read() -> Result<Self, String> {
        for _ in 0..3 {
            let (mut path_count, mut mode_count) = (0, 0);
            let code = unsafe {
                GetDisplayConfigBufferSizes(QDC_ONLY_ACTIVE_PATHS, &mut path_count, &mut mode_count)
            };
            if code != ERROR_SUCCESS {
                return Err(format!("Display configuration size: {}", code.0));
            }
            if path_count == 0 || path_count > 16 || mode_count > 64 {
                return Err("Unsupported active display configuration size".into());
            }
            let mut paths = vec![DISPLAYCONFIG_PATH_INFO::default(); path_count as usize];
            let mut modes = vec![DISPLAYCONFIG_MODE_INFO::default(); mode_count as usize];
            let code = unsafe {
                QueryDisplayConfig(
                    QDC_ONLY_ACTIVE_PATHS,
                    &mut path_count,
                    paths.as_mut_ptr(),
                    &mut mode_count,
                    modes.as_mut_ptr(),
                    None,
                )
            };
            if code == ERROR_INSUFFICIENT_BUFFER {
                continue;
            }
            if code != ERROR_SUCCESS {
                return Err(format!("Read display configuration: {}", code.0));
            }
            paths.truncate(path_count as usize);
            modes.truncate(mode_count as usize);
            return Ok(Self { paths, modes });
        }
        Err("Displays changed repeatedly while reading configuration".into())
    }

    fn source_name(path: &DISPLAYCONFIG_PATH_INFO) -> Result<String, String> {
        let mut name = DISPLAYCONFIG_SOURCE_DEVICE_NAME::default();
        name.header.r#type = DISPLAYCONFIG_DEVICE_INFO_GET_SOURCE_NAME;
        name.header.size = size_of::<DISPLAYCONFIG_SOURCE_DEVICE_NAME>() as u32;
        name.header.adapterId = path.sourceInfo.adapterId;
        name.header.id = path.sourceInfo.id;
        let code = unsafe { DisplayConfigGetDeviceInfo(&mut name.header) };
        if code != 0 {
            return Err(format!("Read display source name: {code}"));
        }
        let end = name
            .viewGdiDeviceName
            .iter()
            .position(|&x| x == 0)
            .unwrap_or(name.viewGdiDeviceName.len());
        Ok(String::from_utf16_lossy(&name.viewGdiDeviceName[..end]))
    }

    fn source_index(&self, path: &DISPLAYCONFIG_PATH_INFO) -> Result<usize, String> {
        let index = unsafe { path.sourceInfo.Anonymous.modeInfoIdx } as usize;
        let mode = self
            .modes
            .get(index)
            .ok_or("Display source mode is unavailable")?;
        if mode.infoType != DISPLAYCONFIG_MODE_INFO_TYPE_SOURCE
            || mode.id != path.sourceInfo.id
            || mode.adapterId != path.sourceInfo.adapterId
        {
            return Err("Display path and source mode do not agree".into());
        }
        Ok(index)
    }

    fn describe(&self) -> Result<Value, String> {
        let mut paths = Vec::new();
        let adapters = super::drivers::adapters()?;
        for path in &self.paths {
            let mode = &self.modes[self.source_index(path)?];
            let source = unsafe { mode.Anonymous.sourceMode };
            let mut name = DISPLAYCONFIG_ADAPTER_NAME::default();
            name.header.r#type = DISPLAYCONFIG_DEVICE_INFO_GET_ADAPTER_NAME;
            name.header.size = size_of::<DISPLAYCONFIG_ADAPTER_NAME>() as u32;
            name.header.adapterId = path.sourceInfo.adapterId;
            let code = unsafe { DisplayConfigGetDeviceInfo(&mut name.header) };
            if code != 0 { return Err(format!("Read display adapter: {code}")); }
            let mut instance = [0u16;1024];
            let mut bytes = (instance.len()*2) as u32;
            let mut kind = DEVPROPTYPE::default();
            let code = unsafe { CM_Get_Device_Interface_PropertyW(PCWSTR(name.adapterDevicePath.as_ptr()),
                &DEVPKEY_Device_InstanceId, &mut kind, Some(instance.as_mut_ptr().cast()), &mut bytes, 0) };
            if code != CR_SUCCESS || kind != DEVPROP_TYPE_STRING || bytes > 2048 || bytes%2 != 0 {
                return Err("Cannot identify display adapter instance".into());
            }
            let instance = String::from_utf16_lossy(&instance[..instance.iter().position(|&c|c==0).unwrap_or(instance.len())]);
            let adapter = adapters.iter().find(|a| a["instance"].as_str().is_some_and(|v| v.eq_ignore_ascii_case(&instance)))
                .ok_or("Display adapter is not in the device inventory")?;
            paths.push(json!({"device":Self::source_name(path)?,"instance":instance,
                "pciAddress":adapter["pciAddress"],"service":adapter["service"],"problem":adapter["problem"],
                "adapterLuid":{"high":path.sourceInfo.adapterId.HighPart,"low":path.sourceInfo.adapterId.LowPart},
                "sourceId":path.sourceInfo.id,"targetId":path.targetInfo.id,
                "targetAvailable":path.targetInfo.targetAvailable.as_bool(),
                "x":source.position.x,"y":source.position.y,
                "width":source.width,"height":source.height}));
        }
        let mut monitors=super::display::snapshot();
        if let Some(displays)=monitors["displays"].as_array_mut() {
            for monitor in displays {
                let get=|fields:&Value,key:&str|fields[key].as_i64().and_then(|v|i32::try_from(v).ok()).ok_or("Invalid monitor bounds");
                let rect=|fields:&Value|->Result<RECT,String>{let x=get(fields,"x")?;let y=get(fields,"y")?;
                    Ok(RECT{left:x,top:y,right:x+get(fields,"width")?,bottom:y+get(fields,"height")?})};
                let area=super::window_control::app_work_area(rect(monitor)?,rect(&monitor["workArea"])?);
                monitor["appWorkArea"]=json!({"x":area.left,"y":area.top,"width":area.right-area.left,"height":area.bottom-area.top});
            }
        }
        Ok(json!({"paths":paths,"monitors":monitors}))
    }

    fn select_primary(&mut self, name: &str) -> Result<(), String> {
        let names = self
            .paths
            .iter()
            .map(Self::source_name)
            .collect::<Result<Vec<_>, _>>()?;
        let matches = names
            .iter()
            .enumerate()
            .filter(|(_, n)| n.eq_ignore_ascii_case(name))
            .map(|(i, _)| i)
            .collect::<Vec<_>>();
        if matches.len() != 1 {
            return Err("Expected exactly one active display with the requested name".into());
        }
        let selected = matches[0];
        // Cloned paths need a separate policy; never translate one source twice.
        let indices = self
            .paths
            .iter()
            .map(|p| self.source_index(p))
            .collect::<Result<Vec<_>, _>>()?;
        if indices.iter().copied().collect::<BTreeSet<_>>().len() != indices.len() {
            return Err(
                "Primary selection requires extended displays, without cloned sources".into(),
            );
        }
        let origin = unsafe { self.modes[indices[selected]].Anonymous.sourceMode.position };
        for index in indices {
            let source = unsafe { &mut self.modes[index].Anonymous.sourceMode };
            source.position.x = source
                .position
                .x
                .checked_sub(origin.x)
                .ok_or("Display X overflow")?;
            source.position.y = source
                .position
                .y
                .checked_sub(origin.y)
                .ok_or("Display Y overflow")?;
        }
        self.paths.swap(0, selected);
        self.apply()
    }

    fn arrange(&mut self, layout: &[Layout]) -> Result<(), String> {
        self.arrange_validated(layout, true)
    }

    fn arrange_validated(&mut self, layout: &[Layout], apply: bool) -> Result<(), String> {
        if layout.len() != self.paths.len() || layout.iter().filter(|m| m.primary).count() != 1 {
            return Err("Layout must describe every active display and one primary".into());
        }
        for (i, monitor) in layout.iter().enumerate() {
            if monitor.device.contains('\0')
                || monitor.x.abs_diff(0) > 1_000_000
                || monitor.y.abs_diff(0) > 1_000_000
                || !(640..=4096).contains(&monitor.width)
                || !(480..=4096).contains(&monitor.height)
                || u64::from(monitor.width) * u64::from(monitor.height) > 8_388_608
                || (monitor.primary && (monitor.x != 0 || monitor.y != 0))
            {
                return Err("Invalid display layout coordinates or dimensions".into());
            }
            if monitor.dpi.is_some_and(|dpi| ![96,120,144,168,192,216,240,288].contains(&dpi)) {
                return Err("Unsupported display DPI".into());
            }
            if let Some(area) = &monitor.work_area {
                if area.width < 160 || area.height < 100 || area.x < monitor.x || area.y < monitor.y
                    || i64::from(area.x)+i64::from(area.width) > i64::from(monitor.x)+i64::from(monitor.width)
                    || i64::from(area.y)+i64::from(area.height) > i64::from(monitor.y)+i64::from(monitor.height) {
                    return Err("Work area must fit its display".into());
                }
            }
            for other in &layout[..i] {
                if monitor.device.eq_ignore_ascii_case(&other.device)
                    || (monitor.x < other.x + other.width as i32
                        && other.x < monitor.x + monitor.width as i32
                        && monitor.y < other.y + other.height as i32
                        && other.y < monitor.y + monitor.height as i32)
                {
                    return Err(
                        "Extended displays must have distinct names and non-overlapping rectangles"
                            .into(),
                    );
                }
            }
        }
        let indices = self
            .paths
            .iter()
            .map(|p| self.source_index(p))
            .collect::<Result<Vec<_>, _>>()?;
        if indices.iter().copied().collect::<BTreeSet<_>>().len() != indices.len() {
            return Err("Layout requires extended displays without cloned sources".into());
        }
        let mut primary = None;
        for (i, path) in self.paths.iter_mut().enumerate() {
            let name = Self::source_name(path)?;
            let monitor = layout
                .iter()
                .find(|m| m.device.eq_ignore_ascii_case(&name))
                .ok_or("Requested layout does not match the active display names")?;
            let source = unsafe { &mut self.modes[indices[i]].Anonymous.sourceMode };
            if source.width != monitor.width || source.height != monitor.height {
                source.width = monitor.width;
                source.height = monitor.height;
                // Ask Windows to find the target timing for this exact source
                // raster. No ALLOW_CHANGES: never silently substitute a mode.
                // DISPLAYCONFIG_PATH_MODE_IDX_INVALID is a C macro, omitted
                // from these generated bindings.
                path.targetInfo.Anonymous.modeInfoIdx = u32::MAX;
            }
            source.position.x = monitor.x;
            source.position.y = monitor.y;
            if monitor.primary {
                primary = Some(i);
            }
        }
        self.paths
            .swap(0, primary.ok_or("Primary display not active")?);
        if apply { self.apply() } else { Ok(()) }
    }

    fn apply(&self) -> Result<(), String> {
        let common = SDC_USE_SUPPLIED_DISPLAY_CONFIG;
        let code = unsafe {
            SetDisplayConfig(Some(&self.paths), Some(&self.modes), common | SDC_VALIDATE)
        };
        if code != 0 {
            return Err(format!("Validate display configuration: {code}"));
        }
        let code = unsafe {
            SetDisplayConfig(
                Some(&self.paths),
                Some(&self.modes),
                common | SDC_APPLY | SDC_SAVE_TO_DATABASE,
            )
        };
        if code != 0 {
            return Err(format!("Apply display configuration: {code}"));
        }
        Ok(())
    }
}

// Windows Settings uses these two private packets for live per-monitor DPI.
// Bound the ABI/range and verify through the normal monitor API afterwards;
// an unsupported Windows build fails instead of changing registry defaults.
#[repr(C)]
#[derive(Default)]
struct DpiGet { header: DISPLAYCONFIG_DEVICE_INFO_HEADER, minimum: i32, current: i32, maximum: i32 }
#[repr(C)]
struct DpiSet { header: DISPLAYCONFIG_DEVICE_INFO_HEADER, relative: i32 }

fn set_dpi(path: &DISPLAYCONFIG_PATH_INFO, dpi: u32) -> Result<(), String> {
    let scales = [96u32,120,144,168,192,216,240,288,336,384,432,480];
    if size_of::<DpiGet>() != 32 || size_of::<DpiSet>() != 24 { return Err("Unsupported DPI packet ABI".into()); }
    let mut get = DpiGet::default();
    get.header = DISPLAYCONFIG_DEVICE_INFO_HEADER { r#type: DISPLAYCONFIG_DEVICE_INFO_TYPE(-3),
        size: 32, adapterId: path.sourceInfo.adapterId, id: path.sourceInfo.id };
    let code = unsafe { DisplayConfigGetDeviceInfo(&mut get.header) };
    if code != 0 { return Err(format!("Read live display scaling: {code}")); }
    if !(-11..=0).contains(&get.minimum) || !(0..=11).contains(&get.maximum)
        || get.current < get.minimum || get.current > get.maximum {
        return Err("Unsupported live DPI range".into());
    }
    let desired = scales.iter().position(|&s|s==dpi).ok_or("Unsupported DPI value")? as i32 + get.minimum;
    if desired < get.minimum || desired > get.maximum { return Err("Requested DPI is outside this monitor's range".into()); }
    if desired == get.current { return Ok(()); }
    let set = DpiSet { header: DISPLAYCONFIG_DEVICE_INFO_HEADER {r#type:DISPLAYCONFIG_DEVICE_INFO_TYPE(-4),
        size:24,adapterId:path.sourceInfo.adapterId,id:path.sourceInfo.id},relative:desired };
    let code = unsafe { DisplayConfigSetDeviceInfo(&set.header) };
    if code != 0 { return Err(format!("Apply live display scaling: {code}")); }
    Ok(())
}

fn matches(description: &Value, layout: &[Layout], include_dpi: bool) -> bool {
    description["monitors"]["displays"].as_array().is_some_and(|displays|
        displays.len()==layout.len() && layout.iter().all(|m| displays.iter().any(|d|
            d["device"].as_str().is_some_and(|v|v.eq_ignore_ascii_case(&m.device)) && d["x"]==m.x && d["y"]==m.y
                && d["width"]==m.width && d["height"]==m.height && d["primary"]==m.primary
                && (!include_dpi || m.dpi.is_none_or(|dpi|d["dpi"]==dpi)))))
}

pub fn snapshot() -> Result<Value, String> { Topology::read()?.describe() }

pub fn configure(value: &Value) -> Result<Value, String> {
    let layout: Vec<Layout> = serde_json::from_value(value["layout"].clone()).map_err(|e|format!("Invalid layout: {e}"))?;
    let mut topology = Topology::read()?;
    // Always validate the full input, even if its raster already matches.
    let already_matches = matches(&topology.describe()?, &layout, false);
    topology.arrange_validated(&layout, !already_matches)?;
    let current = Topology::read()?;
    for monitor in &layout {
        if let Some(dpi) = monitor.dpi {
            let path = current.paths.iter().find(|p| Topology::source_name(p).is_ok_and(|v|v.eq_ignore_ascii_case(&monitor.device)))
                .ok_or("Display disappeared during DPI update")?;
            set_dpi(path, dpi)?;
        }
    }
    for _ in 0..15 {
        let description = snapshot()?;
        if matches(&description,&layout,true) {
            let areas=layout.iter().filter_map(|m|m.work_area.as_ref().map(|a|(
                RECT{left:m.x,top:m.y,right:m.x+m.width as i32,bottom:m.y+m.height as i32},
                RECT{left:a.x,top:a.y,right:a.x+a.width,bottom:a.y+a.height}))).collect();
            super::window_control::set_app_work_areas(areas)?;
            return snapshot();
        }
        thread::sleep(Duration::from_millis(100));
    }
    Err("Windows did not confirm display layout and DPI".into())
}

pub fn run(args: &[String]) -> Result<(), String> {
    if let [flag, data] = args {
        if flag == "--layout" && data.len() <= 8192 {
            let layout: Value = serde_json::from_str(data).map_err(|e|format!("Invalid layout: {e}"))?;
            println!("{}", configure(&json!({"layout":layout}))?);
            return Ok(());
        }
    }
    let mut topology = Topology::read()?;
    let (primary, layout) = match args {
        [] => {
            println!("{}", topology.describe()?);
            return Ok(());
        }
        [flag, name] if flag == "--primary" && !name.contains('\0') => (Some(name.as_str()), None),
        [flag, data] if flag == "--layout" && data.len() <= 8192 => (
            None,
            Some(
                serde_json::from_str::<Vec<Layout>>(data)
                    .map_err(|e| format!("Invalid layout: {e}"))?,
            ),
        ),
        _ => {
            return Err(
                "Expected display-topology [--primary ACTIVE_DEVICE_NAME | --layout JSON_ARRAY]"
                    .into(),
            );
        }
    };
    if let Some(name) = primary {
        topology.select_primary(name)?;
    }
    if let Some(layout) = &layout {
        topology.arrange(layout)?;
    }
    for _ in 0..10 {
        let actual = Topology::read()?;
        let description = actual.describe()?;
        let confirmed = description["monitors"]["displays"]
            .as_array()
            .is_some_and(|displays| {
                if let Some(name) = primary {
                    displays.iter().any(|d| {
                        d["device"]
                            .as_str()
                            .is_some_and(|v| v.eq_ignore_ascii_case(name))
                            && d["primary"] == true
                            && d["x"] == 0
                            && d["y"] == 0
                    })
                } else if let Some(layout) = &layout {
                    displays.len() == layout.len()
                        && layout.iter().all(|m| {
                            displays.iter().any(|d| {
                                d["device"]
                                    .as_str()
                                    .is_some_and(|v| v.eq_ignore_ascii_case(&m.device))
                                    && d["x"] == m.x
                                    && d["y"] == m.y
                                    && d["width"] == m.width
                                    && d["height"] == m.height
                                    && d["primary"] == m.primary
                            })
                        })
                } else {
                    false
                }
            });
        if confirmed {
            println!("{description}");
            return Ok(());
        }
        thread::sleep(Duration::from_millis(100));
    }
    Err("Windows accepted the request but did not confirm the requested display layout".into())
}
