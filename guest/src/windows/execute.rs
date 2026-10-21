//! Bounded commands in the interactive worker's existing user token.
//! No shell is added implicitly, no elevation is attempted, and the job's
//! descendants cannot outlive the request or a worker crash.
use super::{
    error,
    identity::{self, Handle},
};
use serde_json::{Value, json};
use std::{
    fs::File,
    io::Read,
    os::windows::io::{AsRawHandle, FromRawHandle},
    path::{Component, Path, Prefix},
    time::{Duration, Instant},
};
use windows::{
    Win32::{
        Foundation::{
            ERROR_BROKEN_PIPE, ERROR_NO_DATA, ERROR_PIPE_NOT_CONNECTED, HANDLE,
            HANDLE_FLAG_INHERIT, HANDLE_FLAGS, SetHandleInformation, WAIT_OBJECT_0, WAIT_TIMEOUT,
        },
        Security::SECURITY_ATTRIBUTES,
        System::{
            JobObjects::{
                AssignProcessToJobObject, CreateJobObjectW, JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
                JOBOBJECT_EXTENDED_LIMIT_INFORMATION, JobObjectExtendedLimitInformation,
                SetInformationJobObject, TerminateJobObject,
            },
            Pipes::{CreatePipe, PeekNamedPipe},
            Threading::{
                CREATE_NO_WINDOW, CREATE_SUSPENDED, CreateProcessW, DeleteProcThreadAttributeList,
                EXTENDED_STARTUPINFO_PRESENT, GetExitCodeProcess,
                InitializeProcThreadAttributeList, LPPROC_THREAD_ATTRIBUTE_LIST,
                PROC_THREAD_ATTRIBUTE_HANDLE_LIST, PROCESS_INFORMATION, ResumeThread,
                STARTF_USESTDHANDLES, STARTUPINFOEXW, TerminateProcess, UpdateProcThreadAttribute,
                WaitForSingleObject,
            },
        },
    },
    core::{HRESULT, PCWSTR, PWSTR},
};

const OUTPUT_LIMIT: usize = 65_536;

struct Attributes {
    _storage: Vec<usize>,
    list: LPPROC_THREAD_ATTRIBUTE_LIST,
}
impl Attributes {
    fn handles(handles: &[HANDLE]) -> Result<Self, String> {
        unsafe {
            let mut bytes = 0;
            let _ = InitializeProcThreadAttributeList(None, 1, None, &mut bytes);
            if bytes == 0 || bytes > 65_536 {
                return Err("Cannot allocate process handle list".into());
            }
            let mut storage = vec![0usize; bytes.div_ceil(size_of::<usize>())];
            let list = LPPROC_THREAD_ATTRIBUTE_LIST(storage.as_mut_ptr().cast());
            InitializeProcThreadAttributeList(Some(list), 1, None, &mut bytes).map_err(error)?;
            let result = Self {
                _storage: storage,
                list,
            };
            UpdateProcThreadAttribute(
                list,
                0,
                PROC_THREAD_ATTRIBUTE_HANDLE_LIST as usize,
                Some(handles.as_ptr().cast()),
                size_of_val(handles),
                None,
                None,
            )
            .map_err(error)?;
            Ok(result)
        }
    }
}
impl Drop for Attributes {
    fn drop(&mut self) {
        unsafe {
            DeleteProcThreadAttributeList(self.list);
        }
    }
}

fn pipe(parent_reads: bool) -> Result<(Handle, Handle), String> {
    unsafe {
        let attributes = SECURITY_ATTRIBUTES {
            nLength: size_of::<SECURITY_ATTRIBUTES>() as u32,
            bInheritHandle: true.into(),
            ..Default::default()
        };
        let (mut read, mut write) = (HANDLE::default(), HANDLE::default());
        CreatePipe(&mut read, &mut write, Some(&attributes), 0).map_err(error)?;
        let (read, write) = (Handle(read), Handle(write));
        SetHandleInformation(
            if parent_reads { read.0 } else { write.0 },
            HANDLE_FLAG_INHERIT.0,
            HANDLE_FLAGS(0),
        )
        .map_err(error)?;
        Ok((read, write))
    }
}

fn file(mut handle: Handle) -> File {
    let raw = std::mem::replace(&mut handle.0, HANDLE::default());
    unsafe { File::from_raw_handle(raw.0) }
}

/// Windows CRT argument quoting, including empty arguments and trailing slashes.
fn quote(value: &str) -> String {
    // cmd.exe also interprets its own command tail. Keep ordinary switches
    // and words unquoted while retaining CRT escaping where it is needed.
    if !value.is_empty()
        && !value
            .chars()
            .any(|character| character.is_whitespace() || character == '"')
    {
        return value.to_owned();
    }
    let mut result = String::from("\"");
    let mut slashes = 0;
    for character in value.chars() {
        if character == '\\' {
            slashes += 1;
            continue;
        }
        if character == '"' {
            result.extend(std::iter::repeat_n('\\', slashes * 2 + 1));
        } else {
            result.extend(std::iter::repeat_n('\\', slashes));
        }
        result.push(character);
        slashes = 0;
    }
    result.extend(std::iter::repeat_n('\\', slashes * 2));
    result.push('"');
    result
}

fn drain(
    pipe: &mut File,
    output: &mut Vec<u8>,
    remaining: &mut usize,
    truncated: &mut bool,
) -> Result<bool, String> {
    // Peek before every synchronous read. A descendant holding a pipe open
    // must not leave a reader thread blocked after the command has ended.
    for _ in 0..8 {
        let mut available = 0;
        unsafe {
            if let Err(message) = PeekNamedPipe(
                HANDLE(pipe.as_raw_handle()),
                None,
                0,
                None,
                Some(&mut available),
                None,
            ) {
                if [ERROR_BROKEN_PIPE, ERROR_NO_DATA, ERROR_PIPE_NOT_CONNECTED]
                    .iter()
                    .any(|code| message.code() == HRESULT::from_win32(code.0))
                {
                    return Ok(false);
                }
                return Err(error(message));
            }
        }
        if available == 0 {
            return Ok(true);
        }
        let mut buffer = [0u8; 8192];
        let count = pipe
            .read(&mut buffer[..(available as usize).min(8192)])
            .map_err(error)?;
        if count == 0 {
            return Ok(false);
        }
        let keep = count.min(*remaining);
        output.extend_from_slice(&buffer[..keep]);
        *remaining -= keep;
        *truncated |= keep < count;
    }
    Ok(true)
}

fn text(bytes: &[u8], remaining: &mut usize, truncated: &mut bool) -> String {
    let mut value = String::from_utf8_lossy(bytes).into_owned();
    if value.len() > *remaining {
        let mut end = *remaining;
        while !value.is_char_boundary(end) {
            end -= 1;
        }
        value.truncate(end);
        *truncated = true;
    }
    *remaining -= value.len();
    value
}

pub fn run(request: &Value) -> Result<Value, String> {
    let (sid, session) = identity::current()?;
    if ["S-1-5-18", "S-1-5-19", "S-1-5-20"].contains(&sid.as_str()) {
        return Err("Commands require the interactive user, not a system account".into());
    }
    let executable = request["executable"]
        .as_str()
        .filter(|value| {
            // Reject UNC/device paths rather than letting CreateProcessW
            // resolve a network executable before the child timeout starts.
            !value.contains('\0')
                && Path::new(value).is_absolute()
                && matches!(Path::new(value).components().next(),
                    Some(Component::Prefix(prefix)) if matches!(prefix.kind(), Prefix::Disk(_)))
        })
        .ok_or("An absolute drive-rooted Windows executable path is required")?;
    let arguments = request["args"]
        .as_array()
        .filter(|values| values.len() <= 128)
        .ok_or("At most 128 string arguments are required")?;
    let timeout = if request["timeoutSeconds"].is_null() {
        15
    } else {
        request["timeoutSeconds"]
            .as_u64()
            .filter(|value| (1..=60).contains(value))
            .ok_or("timeoutSeconds must be between 1 and 60")?
    };
    let mut command = quote(executable);
    for value in arguments {
        let argument = value
            .as_str()
            .filter(|value| !value.contains('\0'))
            .ok_or("Arguments must be strings without NUL characters")?;
        command.push(' ');
        command.push_str(&quote(argument));
    }
    let mut command: Vec<u16> = command.encode_utf16().chain([0]).collect();
    if command.len() > 32_767 {
        return Err("The Windows command line is too long".into());
    }
    let application: Vec<u16> = executable.encode_utf16().chain([0]).collect();
    let started = Instant::now();
    unsafe {
        let job = Handle(CreateJobObjectW(None, PCWSTR::null()).map_err(error)?);
        let mut limits = JOBOBJECT_EXTENDED_LIMIT_INFORMATION::default();
        limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        SetInformationJobObject(
            job.0,
            JobObjectExtendedLimitInformation,
            (&limits as *const JOBOBJECT_EXTENDED_LIMIT_INFORMATION).cast(),
            size_of_val(&limits) as u32,
        )
        .map_err(error)?;
        let (input_read, input_write) = pipe(false)?;
        let (output_read, output_write) = pipe(true)?;
        let (error_read, error_write) = pipe(true)?;
        // These are the only inherited handles. stdin immediately reaches EOF.
        drop(input_write);
        let inherited = [input_read.0, output_write.0, error_write.0];
        let attributes = Attributes::handles(&inherited)?;
        let mut startup = STARTUPINFOEXW::default();
        startup.StartupInfo.cb = size_of::<STARTUPINFOEXW>() as u32;
        startup.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
        startup.StartupInfo.hStdInput = input_read.0;
        startup.StartupInfo.hStdOutput = output_write.0;
        startup.StartupInfo.hStdError = error_write.0;
        startup.lpAttributeList = attributes.list;
        let mut process = PROCESS_INFORMATION::default();
        // CreateProcessW inherits this worker's interactive token. It cannot
        // borrow the service's SYSTEM token and does not invoke RunAs.
        CreateProcessW(
            PCWSTR(application.as_ptr()),
            Some(PWSTR(command.as_mut_ptr())),
            None,
            None,
            true,
            CREATE_SUSPENDED | CREATE_NO_WINDOW | EXTENDED_STARTUPINFO_PRESENT,
            None,
            PCWSTR::null(),
            &startup.StartupInfo,
            &mut process,
        )
        .map_err(error)?;
        let process_handle = Handle(process.hProcess);
        let thread = Handle(process.hThread);
        if let Err(message) = AssignProcessToJobObject(job.0, process_handle.0) {
            let _ = TerminateProcess(process_handle.0, 1);
            return Err(error(message));
        }
        drop(attributes);
        drop(input_read);
        drop(output_write);
        drop(error_write);
        if ResumeThread(thread.0) == u32::MAX {
            return Err("The command could not be resumed".into());
        }
        drop(thread);
        let (mut stdout, mut stderr) = (file(output_read), file(error_read));
        let (mut output, mut errors) = (Vec::new(), Vec::new());
        let mut remaining = OUTPUT_LIMIT;
        let (mut truncated, mut timed_out) = (false, false);
        let exited = loop {
            drain(&mut stdout, &mut output, &mut remaining, &mut truncated)?;
            drain(&mut stderr, &mut errors, &mut remaining, &mut truncated)?;
            let wait = WaitForSingleObject(process_handle.0, 20);
            if wait == WAIT_OBJECT_0 {
                break true;
            }
            if wait != WAIT_TIMEOUT {
                return Err("Cannot wait for the command".into());
            }
            if started.elapsed() >= Duration::from_secs(timeout) {
                timed_out = true;
                TerminateJobObject(job.0, 1460).map_err(error)?;
                break WaitForSingleObject(process_handle.0, 2000) == WAIT_OBJECT_0;
            }
        };
        let mut code = 0;
        let exit_code = if exited && GetExitCodeProcess(process_handle.0, &mut code).is_ok() {
            Some(code)
        } else {
            None
        };
        // Bound all descendants to this request, including ones that retained
        // inherited output pipes after the main executable returned.
        drop(job);
        let drain_until = Instant::now() + Duration::from_millis(200);
        while Instant::now() < drain_until {
            let out_open = drain(&mut stdout, &mut output, &mut remaining, &mut truncated)?;
            let err_open = drain(&mut stderr, &mut errors, &mut remaining, &mut truncated)?;
            if !out_open && !err_open {
                break;
            }
            std::thread::sleep(Duration::from_millis(5));
        }
        let mut text_remaining = OUTPUT_LIMIT;
        let output = text(&output, &mut text_remaining, &mut truncated);
        let errors = text(&errors, &mut text_remaining, &mut truncated);
        Ok(
            json!({"exitCode":exit_code,"timedOut":timed_out,"stdout":output,"stderr":errors,
            "outputTruncated":truncated,"outputEncoding":"utf-8-lossy","userSid":sid,"session":session}),
        )
    }
}
