//! Explicit topology diagnostics, primary selection and exact extended layout.
//! Reading does not start a graphics device. Applying verifies Windows' result.
use serde::Deserialize;
use serde_json::{Value, json};
use std::{collections::BTreeSet, thread, time::Duration};
use windows::Win32::{
    Devices::Display::*,
    Foundation::{ERROR_INSUFFICIENT_BUFFER, ERROR_SUCCESS},
};

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
}

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
        for path in &self.paths {
            let mode = &self.modes[self.source_index(path)?];
            let source = unsafe { mode.Anonymous.sourceMode };
            paths.push(json!({"device":Self::source_name(path)?,
                "adapterLuid":{"high":path.sourceInfo.adapterId.HighPart,"low":path.sourceInfo.adapterId.LowPart},
                "sourceId":path.sourceInfo.id,"targetId":path.targetInfo.id,
                "targetAvailable":path.targetInfo.targetAvailable.as_bool(),
                "x":source.position.x,"y":source.position.y,
                "width":source.width,"height":source.height}));
        }
        Ok(json!({"paths":paths,"monitors":super::display::snapshot()}))
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
        self.apply()
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

pub fn run(args: &[String]) -> Result<(), String> {
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
