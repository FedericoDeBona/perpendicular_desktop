mod app_process;
mod capture;
mod catalogue;
mod clipboard;
mod display;
mod drivers;
mod execute;
mod icons;
mod menu_capture;
mod identity;
mod service;
mod window_control;
mod wire;
mod worker;

use serde::{Deserialize, Serialize};
use std::path::Path;

#[derive(Clone, Deserialize, Serialize)]
pub struct Configuration {
    pub port: u16,
    pub token: String,
    #[serde(default, rename = "ownerSid", skip_serializing_if = "Option::is_none")]
    pub owner_sid: Option<String>,
}

pub fn run() -> Result<(), String> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.first().map(String::as_str) {
        Some("install") => service::install(Path::new(args.get(1).ok_or("missing configuration")?)),
        Some("service") => service::run(),
        Some("worker") => worker::run(Path::new(args.get(1).ok_or("missing configuration")?)),
        _ => Err("Expected install, service or worker".into()),
    }
}

pub fn error(value: impl std::fmt::Display) -> String {
    value.to_string()
}
