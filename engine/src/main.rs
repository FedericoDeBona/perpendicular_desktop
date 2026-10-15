use clap::{Parser, Subcommand};
use perpendicular_engine::engine::Engine;
use perpendicular_engine::error::{Error, Result};
use perpendicular_engine::model::UpdateOptions;
use serde_json::{json, Value};
use std::path::PathBuf;

#[derive(Parser)]
#[command(
    name = "perpendicular-engine",
    version,
    about = "Independent Windows ARM VM lifecycle engine. Every response is JSON."
)]
struct Cli {
    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    SystemInfo,
    List,
    GuestStatus {
        id: String,
    },
    GuestClipboardRead {
        id: String,
    },
    GuestClipboardWrite {
        id: String,
        #[arg(
            long,
            conflicts_with = "text_file",
            required_unless_present = "text_file"
        )]
        text: Option<String>,
        #[arg(long, conflicts_with = "text")]
        text_file: Option<PathBuf>,
    },
    GuestFilePush {
        id: String,
        #[arg(long)]
        source: PathBuf,
        #[arg(long)]
        name: String,
    },
    Create {
        #[arg(long)]
        name: String,
        #[arg(long)]
        iso: PathBuf,
        #[arg(long, default_value_t = 4)]
        cpus: u16,
        #[arg(long, default_value_t = 8192)]
        memory_mib: u64,
        #[arg(long, default_value_t = 64)]
        disk_gib: u64,
    },
    Clone {
        id: String,
        #[arg(long)]
        name: String,
    },
    ImportDisk {
        #[arg(long)]
        name: String,
        #[arg(long)]
        disk: PathBuf,
        #[arg(long, default_value_t = 4)]
        cpus: u16,
        #[arg(long, default_value_t = 8192)]
        memory_mib: u64,
        #[arg(long)]
        iso: Option<PathBuf>,
    },
    Start {
        id: String,
    },
    Pause {
        id: String,
    },
    Resume {
        id: String,
    },
    Stop {
        id: String,
        #[arg(long)]
        force: bool,
    },
    EjectIso {
        id: String,
    },
    EjectGuestTools {
        id: String,
    },
    Update {
        id: String,
        #[arg(long)]
        name: Option<String>,
        #[arg(long)]
        cpus: Option<u16>,
        #[arg(long)]
        memory_mib: Option<u64>,
        #[arg(long)]
        iso: Option<PathBuf>,
        #[arg(long)]
        guest_tools_iso: Option<PathBuf>,
        #[arg(long,value_parser=["en-us","it"])]
        keyboard_layout: Option<String>,
        #[arg(long,action=clap::ArgAction::Set)]
        audio_output: Option<bool>,
    },
    Delete {
        id: String,
    },
    Snapshots {
        id: String,
    },
    SnapshotCreate {
        id: String,
        #[arg(long)]
        name: String,
    },
    SnapshotRestore {
        id: String,
        snapshot_id: String,
    },
    SnapshotDelete {
        id: String,
        snapshot_id: String,
    },
    #[command(name = "__supervise", hide = true)]
    Supervise {
        launch_job: PathBuf,
    },
}

fn run(command: Commands) -> Result<Value> {
    if let Commands::Supervise { launch_job } = command {
        perpendicular_engine::process::supervise(&launch_job)?;
        return Ok(json!({"supervisor":"exited"}));
    }
    let engine = Engine::open()?;
    match command {
        Commands::SystemInfo => Ok(engine.system_info()),
        Commands::List => engine.list(),
        Commands::GuestStatus { id } => engine.guest_status(&id),
        Commands::GuestClipboardRead { id } => engine.guest_clipboard_read(&id),
        Commands::GuestClipboardWrite {
            id,
            text,
            text_file,
        } => match (text, text_file) {
            (Some(text), None) => engine.guest_clipboard_write(&id, &text),
            (None, Some(path)) => engine.guest_clipboard_write_file(&id, &path),
            _ => Err(Error::new(
                "invalid_arguments",
                "Choose exactly one clipboard text source",
            )),
        },
        Commands::GuestFilePush { id, source, name } => engine.guest_file_push(&id, &source, &name),
        Commands::Create {
            name,
            iso,
            cpus,
            memory_mib,
            disk_gib,
        } => engine.create(&name, &iso, cpus, memory_mib, disk_gib),
        Commands::Clone { id, name } => engine.clone_vm(&id, &name),
        Commands::ImportDisk {
            name,
            disk,
            cpus,
            memory_mib,
            iso,
        } => engine.import_disk(&name, &disk, cpus, memory_mib, iso.as_deref()),
        Commands::Start { id } => engine.start(&id),
        Commands::Pause { id } => engine.pause_or_resume(&id, false),
        Commands::Resume { id } => engine.pause_or_resume(&id, true),
        Commands::Stop { id, force } => engine.stop(&id, force),
        Commands::EjectIso { id } => engine.eject_iso(&id),
        Commands::EjectGuestTools { id } => engine.eject_guest_tools(&id),
        Commands::Update {
            id,
            name,
            cpus,
            memory_mib,
            iso,
            guest_tools_iso,
            keyboard_layout,
            audio_output,
        } => engine.update(
            &id,
            UpdateOptions {
                name: name.as_deref(),
                cpus,
                memory_mib,
                iso: iso.as_deref(),
                guest_tools_iso: guest_tools_iso.as_deref(),
                keyboard_layout: keyboard_layout.as_deref(),
                audio_output,
            },
        ),
        Commands::Delete { id } => engine.delete(&id),
        Commands::Snapshots { id } => engine.snapshots(&id),
        Commands::SnapshotCreate { id, name } => engine.snapshot_create(&id, &name),
        Commands::SnapshotRestore { id, snapshot_id } => engine.snapshot_restore(&id, &snapshot_id),
        Commands::SnapshotDelete { id, snapshot_id } => engine.snapshot_delete(&id, &snapshot_id),
        Commands::Supervise { .. } => unreachable!(),
    }
}

fn main() {
    let parsed = match Cli::try_parse() {
        Ok(parsed) => parsed,
        Err(error) => {
            let kind = error.kind();
            if kind == clap::error::ErrorKind::DisplayHelp
                || kind == clap::error::ErrorKind::DisplayVersion
            {
                println!("{}", json!({"help":error.to_string()}));
                return;
            }
            println!(
                "{}",
                json!({"error":Error::new("invalid_arguments",error.to_string())})
            );
            std::process::exit(2);
        }
    };
    match run(parsed.command) {
        Ok(value) => println!("{value}"),
        Err(error) => {
            println!("{}", json!({"error":error}));
            std::process::exit(1);
        }
    }
}
