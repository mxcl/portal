use base64::Engine;
use base64::engine::general_purpose::STANDARD as BASE64;
use libc::{TIOCGPGRP, TIOCSWINSZ, c_int, c_void, pid_t, winsize};
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, VecDeque};
use std::env;
use std::ffi::CString;
use std::fs;
use std::io::{self, BufRead, BufReader, Write};
use std::os::fd::{AsRawFd, RawFd};
use std::os::unix::ffi::{OsStrExt, OsStringExt};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::mpsc::{self, Sender};
use std::sync::{Arc, Mutex, Weak};
use std::thread;
use std::time::{SystemTime, UNIX_EPOCH};

const COMMAND_STARTED_MARKER: &[u8] = b"\x1b]133;C;";
const COMMAND_FINISHED_MARKER: &[u8] = b"\x1b]133;D;";
const SYNTHETIC_COMMAND_FINISHED_MARKER: &[u8] = b"\x1b]133;D;0\x07";
const CURRENT_PROTOCOL_VERSION: u16 = 2;
const PREVIOUS_PROTOCOL_VERSION: u16 = 1;
const MAX_SCROLLBACK_LINES: usize = 10_000;
const MAX_SCROLLBACK_BYTES: usize = 16 * 1024 * 1024;
const INITIAL_HISTORY_LINES: usize = 1_000;

#[derive(Clone, Debug)]
struct AttachRequest {
    session_id: String,
    cwd: PathBuf,
    shell: String,
    environment: Vec<(String, String)>,
    protocol_version: u16,
    client_role: ClientRole,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum ClientRole {
    Mac,
    Phone,
}

#[derive(Clone, Debug)]
enum SessionEvent {
    Output { sequence: u64, bytes: Vec<u8> },
    Presence(usize),
    Geometry { rows: u16, cols: u16 },
    Exit(i32),
}

#[derive(Clone, Debug)]
struct OutputChunk {
    sequence: u64,
    bytes: Vec<u8>,
    line_count: usize,
}

struct TerminalState {
    parser: vt100::Parser,
    chunks: VecDeque<OutputChunk>,
    retained_bytes: usize,
    retained_lines: usize,
    next_sequence: u64,
    rows: u16,
    cols: u16,
}

struct TerminalSnapshot {
    sequence: u64,
    rows: u16,
    cols: u16,
    screen: Vec<u8>,
    history: Vec<u8>,
    history_start_sequence: u64,
    has_older_history: bool,
}

impl TerminalState {
    fn new(rows: u16, cols: u16) -> Self {
        Self {
            parser: vt100::Parser::new(rows, cols, MAX_SCROLLBACK_LINES),
            chunks: VecDeque::new(),
            retained_bytes: 0,
            retained_lines: 0,
            next_sequence: 1,
            rows,
            cols,
        }
    }

    fn record(&mut self, bytes: Vec<u8>) -> u64 {
        self.parser.process(&bytes);
        let sequence = self.next_sequence;
        self.next_sequence = self.next_sequence.saturating_add(1);
        let line_count = bytes.iter().filter(|byte| **byte == b'\n').count();
        self.retained_bytes += bytes.len();
        self.retained_lines += line_count;
        self.chunks.push_back(OutputChunk {
            sequence,
            bytes,
            line_count,
        });
        while self.retained_bytes > MAX_SCROLLBACK_BYTES
            || self.retained_lines > MAX_SCROLLBACK_LINES
        {
            let Some(removed) = self.chunks.pop_front() else {
                break;
            };
            self.retained_bytes -= removed.bytes.len();
            self.retained_lines -= removed.line_count;
        }
        sequence
    }

    fn snapshot(&self, history_lines: usize) -> TerminalSnapshot {
        let mut selected = Vec::new();
        let mut selected_lines = 0;
        for chunk in self.chunks.iter().rev() {
            selected.push(chunk);
            selected_lines += chunk.line_count;
            if selected_lines >= history_lines {
                break;
            }
        }
        selected.reverse();
        let history_start_sequence = selected
            .first()
            .map_or(self.next_sequence, |chunk| chunk.sequence);
        let has_older_history = self
            .chunks
            .front()
            .is_some_and(|chunk| chunk.sequence < history_start_sequence);
        let history = selected
            .into_iter()
            .flat_map(|chunk| chunk.bytes.iter().copied())
            .collect();
        TerminalSnapshot {
            sequence: self.next_sequence.saturating_sub(1),
            rows: self.rows,
            cols: self.cols,
            screen: self.parser.screen().contents_formatted(),
            history,
            history_start_sequence,
            has_older_history,
        }
    }

    fn history_before(&self, before_sequence: u64, max_lines: usize) -> TerminalSnapshot {
        let mut selected = Vec::new();
        let mut selected_lines = 0;
        for chunk in self
            .chunks
            .iter()
            .rev()
            .filter(|chunk| chunk.sequence < before_sequence)
        {
            selected.push(chunk);
            selected_lines += chunk.line_count;
            if selected_lines >= max_lines {
                break;
            }
        }
        selected.reverse();
        let history_start_sequence = selected
            .first()
            .map_or(before_sequence, |chunk| chunk.sequence);
        let has_older_history = self
            .chunks
            .front()
            .is_some_and(|chunk| chunk.sequence < history_start_sequence);
        let history = selected
            .into_iter()
            .flat_map(|chunk| chunk.bytes.iter().copied())
            .collect();
        TerminalSnapshot {
            sequence: before_sequence.saturating_sub(1),
            rows: self.rows,
            cols: self.cols,
            screen: Vec::new(),
            history,
            history_start_sequence,
            has_older_history,
        }
    }

    fn resize(&mut self, rows: u16, cols: u16) {
        self.rows = rows;
        self.cols = cols;
        self.parser.screen_mut().set_size(rows, cols);
    }

    fn clear_history(&mut self) {
        self.chunks.clear();
        self.retained_bytes = 0;
        self.retained_lines = 0;
    }
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct SessionMetadata {
    session_id: String,
    title: String,
    cwd: String,
    created_at: f64,
    command_count: u32,
    running_command: Option<String>,
    command_history: Vec<String>,
    attached_client_count: usize,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct SessionStateUpdate {
    title: Option<String>,
    cwd: Option<String>,
    created_at: Option<f64>,
    command_count: Option<u32>,
    running_command: Option<String>,
    command_history: Option<Vec<String>>,
}

struct Session {
    session_id: String,
    master_fd: RawFd,
    child_pid: pid_t,
    exited: AtomicBool,
    attached_client_count: AtomicUsize,
    terminal: Mutex<TerminalState>,
    metadata: Mutex<SessionMetadata>,
    clients: Mutex<Vec<Sender<SessionEvent>>>,
    state: Weak<DaemonState>,
}

impl Session {
    fn new(request: &AttachRequest, state: Weak<DaemonState>) -> io::Result<Arc<Self>> {
        let mut master_fd: c_int = -1;
        let mut size = winsize {
            ws_row: 30,
            ws_col: 100,
            ws_xpixel: 0,
            ws_ypixel: 0,
        };
        let pid = unsafe {
            libc::forkpty(
                &mut master_fd,
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                &mut size,
            )
        };
        if pid < 0 {
            return Err(io::Error::last_os_error());
        }

        if pid == 0 {
            let _ = env::set_current_dir(&request.cwd);
            for (key, value) in &request.environment {
                unsafe {
                    env::set_var(key, value);
                }
            }

            let shell = CString::new(request.shell.as_bytes()).unwrap_or_else(|_| {
                CString::new("/bin/zsh").expect("static shell path must be valid")
            });
            let shell_name = Path::new(&request.shell)
                .file_name()
                .and_then(|name| name.to_str())
                .unwrap_or("zsh");
            let login_shell = CString::new(format!("-{shell_name}"))
                .unwrap_or_else(|_| CString::new("-zsh").expect("static argv must be valid"));
            let mut argv = [login_shell.as_ptr(), std::ptr::null()];
            unsafe {
                libc::execv(shell.as_ptr(), argv.as_mut_ptr());
                libc::perror(c"exec".as_ptr());
                libc::_exit(127);
            }
        }

        let session = Arc::new(Self {
            session_id: request.session_id.clone(),
            master_fd,
            child_pid: pid,
            exited: AtomicBool::new(false),
            attached_client_count: AtomicUsize::new(0),
            terminal: Mutex::new(TerminalState::new(size.ws_row, size.ws_col)),
            metadata: Mutex::new(SessionMetadata::new(request)),
            clients: Mutex::new(Vec::new()),
            state,
        });
        Self::start_reader(session.clone());
        Ok(session)
    }

    fn attach_client(&self, sender: Sender<SessionEvent>) -> TerminalSnapshot {
        let terminal = self.terminal.lock().expect("terminal lock poisoned");
        self.clients
            .lock()
            .expect("clients lock poisoned")
            .push(sender);
        terminal.snapshot(INITIAL_HISTORY_LINES)
    }

    fn increment_attached_client_count(&self) {
        let count = self.attached_client_count.fetch_add(1, Ordering::SeqCst) + 1;
        self.broadcast(SessionEvent::Presence(count));
    }

    fn decrement_attached_client_count(&self) {
        if let Ok(previous) =
            self.attached_client_count
                .fetch_update(Ordering::SeqCst, Ordering::SeqCst, |count| {
                    count.checked_sub(1)
                })
        {
            self.broadcast(SessionEvent::Presence(previous.saturating_sub(1)));
        }
    }

    fn metadata_snapshot(&self) -> SessionMetadata {
        self.reconcile_idle_command_state();
        let mut metadata = self
            .metadata
            .lock()
            .expect("metadata lock poisoned")
            .clone();
        metadata.attached_client_count = self.attached_client_count.load(Ordering::SeqCst);
        metadata
    }

    fn update_metadata(&self, update: SessionStateUpdate) {
        let mut metadata = self.metadata.lock().expect("metadata lock poisoned");
        if let Some(title) = update.title {
            metadata.title = title;
        }
        if let Some(cwd) = update.cwd {
            metadata.cwd = cwd;
        }
        if let Some(created_at) = update.created_at {
            metadata.created_at = created_at;
        }
        if let Some(command_count) = update.command_count {
            metadata.command_count = command_count;
        }
        metadata.running_command = update.running_command;
        if let Some(command_history) = update.command_history {
            metadata.command_history = command_history;
        }
    }

    fn clear_running_command(&self) {
        self.metadata
            .lock()
            .expect("metadata lock poisoned")
            .running_command = None;
    }

    fn clear_history(&self) {
        self.terminal
            .lock()
            .expect("terminal lock poisoned")
            .clear_history();
    }

    fn reconcile_idle_command_state(&self) {
        if !shell_is_foreground(self) {
            return;
        }

        let mut terminal = self.terminal.lock().expect("terminal lock poisoned");
        let history = terminal.snapshot(MAX_SCROLLBACK_LINES).history;
        if history_has_unfinished_command(&history) {
            // ponytail: exit status is unknown for old incomplete replays; 0 restores input.
            terminal.record(SYNTHETIC_COMMAND_FINISHED_MARKER.to_vec());
        }
        drop(terminal);
        self.clear_running_command();
    }

    fn write_input(&self, bytes: &[u8]) {
        let mut offset = 0;
        while offset < bytes.len() {
            let written = unsafe {
                libc::write(
                    self.master_fd,
                    bytes[offset..].as_ptr() as *const c_void,
                    bytes.len() - offset,
                )
            };
            if written > 0 {
                offset += written as usize;
            } else if written == -1
                && io::Error::last_os_error().raw_os_error() == Some(libc::EINTR)
            {
                continue;
            } else {
                break;
            }
        }
    }

    fn resize(&self, rows: u16, cols: u16) {
        let mut size = winsize {
            ws_row: rows,
            ws_col: cols,
            ws_xpixel: 0,
            ws_ypixel: 0,
        };
        unsafe {
            libc::ioctl(self.master_fd, TIOCSWINSZ, &mut size);
        }
        self.terminal
            .lock()
            .expect("terminal lock poisoned")
            .resize(rows, cols);
        self.broadcast(SessionEvent::Geometry { rows, cols });
    }

    fn broadcast(&self, event: SessionEvent) {
        self.clients
            .lock()
            .expect("clients lock poisoned")
            .retain(|client| client.send(event.clone()).is_ok());
    }

    fn interrupt(&self) {
        let mut foreground_process_group: pid_t = 0;
        let signaled = unsafe {
            libc::ioctl(self.master_fd, TIOCGPGRP, &mut foreground_process_group) == 0
                && foreground_process_group > 0
                && libc::kill(-foreground_process_group, libc::SIGINT) == 0
        };
        if !signaled {
            self.write_input(&[0x03]);
        }
    }

    fn kill(&self) {
        unsafe {
            libc::kill(-self.child_pid, libc::SIGTERM);
            libc::kill(self.child_pid, libc::SIGTERM);
            libc::close(self.master_fd);
        }
    }

    fn start_reader(session: Arc<Self>) {
        thread::spawn(move || {
            let mut buffer = [0_u8; 8192];
            loop {
                let count = unsafe {
                    libc::read(
                        session.master_fd,
                        buffer.as_mut_ptr() as *mut c_void,
                        buffer.len(),
                    )
                };
                if count <= 0 {
                    break;
                }

                let bytes = buffer[..count as usize].to_vec();
                let sequence = session
                    .terminal
                    .lock()
                    .expect("terminal lock poisoned")
                    .record(bytes.clone());
                if bytes
                    .windows(COMMAND_FINISHED_MARKER.len())
                    .any(|window| window == COMMAND_FINISHED_MARKER)
                {
                    session.clear_running_command();
                }

                let mut clients = session.clients.lock().expect("clients lock poisoned");
                clients.retain(|client| {
                    client
                        .send(SessionEvent::Output {
                            sequence,
                            bytes: bytes.clone(),
                        })
                        .is_ok()
                });
            }

            let status = reap_child(session.child_pid);
            session.exited.store(true, Ordering::SeqCst);
            let mut clients = session.clients.lock().expect("clients lock poisoned");
            clients.retain(|client| client.send(SessionEvent::Exit(status)).is_ok());
            drop(clients);

            if let Some(state) = session.state.upgrade() {
                let mut sessions = state.sessions.lock().expect("sessions lock poisoned");
                if sessions
                    .get(&session.session_id)
                    .is_some_and(|current| Arc::ptr_eq(current, &session))
                {
                    sessions.remove(&session.session_id);
                }
            }
        });
    }
}

impl SessionMetadata {
    fn new(request: &AttachRequest) -> Self {
        let cwd = request.cwd.to_string_lossy().to_string();
        Self {
            session_id: request.session_id.clone(),
            title: default_title_for_cwd(&request.cwd),
            cwd,
            created_at: unix_timestamp_now(),
            command_count: 0,
            running_command: None,
            command_history: Vec::new(),
            attached_client_count: 0,
        }
    }
}

struct DaemonState {
    sessions: Mutex<HashMap<String, Arc<Session>>>,
}

fn main() -> io::Result<()> {
    let mut args = env::args().skip(1);
    match args.next().as_deref() {
        Some("serve") => serve(),
        _ => {
            eprintln!("usage: vaultty-sessiond serve");
            std::process::exit(64);
        }
    }
}

fn serve() -> io::Result<()> {
    let socket_path = socket_path()?;
    if let Some(parent) = socket_path.parent() {
        fs::create_dir_all(parent)?;
        fs::set_permissions(parent, fs::Permissions::from_mode(0o700))?;
    }
    if socket_path.exists() {
        let _ = fs::remove_file(&socket_path);
    }

    let listener = UnixListener::bind(&socket_path)?;
    fs::set_permissions(&socket_path, fs::Permissions::from_mode(0o600))?;
    let state = Arc::new(DaemonState {
        sessions: Mutex::new(HashMap::new()),
    });

    for stream in listener.incoming() {
        match stream {
            Ok(stream) => {
                let state = state.clone();
                thread::spawn(move || {
                    if let Err(error) = handle_client(stream, state) {
                        eprintln!("vaultty-sessiond client error: {error}");
                    }
                });
            }
            Err(error) => eprintln!("vaultty-sessiond accept error: {error}"),
        }
    }
    Ok(())
}

fn handle_client(mut stream: UnixStream, state: Arc<DaemonState>) -> io::Result<()> {
    validate_peer(&stream)?;

    let reader_stream = stream.try_clone()?;
    let mut reader = BufReader::new(reader_stream);
    let mut line = String::new();
    if reader.read_line(&mut line)? == 0 {
        return Ok(());
    }

    if let Some(encoded_session_id) = line.trim_end().strip_prefix("KILL ") {
        let session_id = decode_string(encoded_session_id)?;
        let session = {
            state
                .sessions
                .lock()
                .expect("sessions lock poisoned")
                .remove(&session_id)
        };
        if let Some(session) = session {
            session.kill();
        }
        writeln!(stream, "OK")?;
        return Ok(());
    }

    if line.trim_end() == "LIST" {
        write_session_list(&mut stream, &state)?;
        return Ok(());
    }

    let request = parse_attach(line.trim_end())?;
    let existing_session = {
        let mut sessions = state.sessions.lock().expect("sessions lock poisoned");
        if sessions
            .get(&request.session_id)
            .is_some_and(|session| session.exited.load(Ordering::SeqCst))
        {
            sessions.remove(&request.session_id);
        }
        sessions.get(&request.session_id).cloned()
    };
    let (session, created) = if let Some(session) = existing_session {
        (session, false)
    } else {
        let new_session = Session::new(&request, Arc::downgrade(&state))?;
        let replaced_session = {
            let mut sessions = state.sessions.lock().expect("sessions lock poisoned");
            if let Some(existing) = sessions
                .get(&request.session_id)
                .filter(|session| !session.exited.load(Ordering::SeqCst))
                .cloned()
            {
                Some(existing)
            } else {
                sessions.insert(request.session_id.clone(), new_session.clone());
                None
            }
        };
        if let Some(existing) = replaced_session {
            new_session.kill();
            (existing, false)
        } else {
            (new_session, true)
        }
    };

    let (tx, rx) = mpsc::channel::<SessionEvent>();
    let snapshot = session.attach_client(tx);
    session.increment_attached_client_count();
    if request.protocol_version >= CURRENT_PROTOCOL_VERSION {
        write_attach_header_v2(&mut stream, created, &snapshot)?;
    } else {
        write_attach_header(&mut stream, created, &snapshot.history)?;
    }

    let writer = Arc::new(Mutex::new(stream.try_clone()?));
    let writer_for_output = writer.clone();
    thread::spawn(move || {
        while let Ok(event) = rx.recv() {
            let mut writer = writer_for_output.lock().expect("writer lock poisoned");
            match event {
                SessionEvent::Output { sequence, bytes } => {
                    let result = if request.protocol_version >= CURRENT_PROTOCOL_VERSION {
                        writeln!(writer, "OUTPUT2 {sequence} {}", BASE64.encode(bytes))
                    } else {
                        writeln!(writer, "OUTPUT {}", BASE64.encode(bytes))
                    };
                    if result.is_err() || writer.flush().is_err() {
                        break;
                    }
                }
                SessionEvent::Exit(status) => {
                    if writeln!(writer, "EXIT {status}").is_err() || writer.flush().is_err() {
                        break;
                    }
                }
                SessionEvent::Presence(count) => {
                    if request.protocol_version >= CURRENT_PROTOCOL_VERSION
                        && (writeln!(writer, "PRESENCE {count}").is_err()
                            || writer.flush().is_err())
                    {
                        break;
                    }
                }
                SessionEvent::Geometry { rows, cols } => {
                    if request.protocol_version >= CURRENT_PROTOCOL_VERSION
                        && (writeln!(writer, "GEOMETRY {rows} {cols}").is_err()
                            || writer.flush().is_err())
                    {
                        break;
                    }
                }
            }
        }
    });

    line.clear();
    while reader.read_line(&mut line)? > 0 {
        let command = line.trim_end();
        if command == "DETACH" {
            break;
        } else if let Some(encoded) = command.strip_prefix("INPUT ") {
            if let Ok(bytes) = BASE64.decode(encoded) {
                session.write_input(&bytes);
            }
        } else if let Some(rest) = command.strip_prefix("RESIZE ") {
            let parts: Vec<&str> = rest.split_whitespace().collect();
            if parts.len() == 2 && request.client_role == ClientRole::Mac {
                if let (Ok(rows), Ok(cols)) = (parts[0].parse::<u16>(), parts[1].parse::<u16>()) {
                    session.resize(rows, cols);
                }
            }
        } else if let Some(rest) = command.strip_prefix("HISTORY_PAGE ") {
            if request.protocol_version >= CURRENT_PROTOCOL_VERSION {
                let parts: Vec<&str> = rest.split_whitespace().collect();
                if parts.len() == 2 {
                    if let (Ok(before), Ok(lines)) =
                        (parts[0].parse::<u64>(), parts[1].parse::<usize>())
                    {
                        let page = session
                            .terminal
                            .lock()
                            .expect("terminal lock poisoned")
                            .history_before(before, lines.min(INITIAL_HISTORY_LINES));
                        write_history_page(
                            &mut *writer.lock().expect("writer lock poisoned"),
                            &page,
                        )?;
                    }
                }
            }
        } else if command == "INTERRUPT" {
            session.interrupt();
        } else if command == "CLEAR_HISTORY" {
            session.clear_history();
        } else if let Some(encoded) = command.strip_prefix("STATE ") {
            let update = decode_state_update(encoded)?;
            session.update_metadata(update);
        } else if command == "KILL" {
            session.kill();
            state
                .sessions
                .lock()
                .expect("sessions lock poisoned")
                .remove(&request.session_id);
            break;
        }
        line.clear();
    }

    session.decrement_attached_client_count();
    Ok(())
}

fn write_attach_header(stream: &mut impl Write, created: bool, history: &[u8]) -> io::Result<()> {
    writeln!(stream, "READY {}", if created { 1 } else { 0 })?;
    if !created || !history.is_empty() {
        writeln!(stream, "HISTORY {}", BASE64.encode(history))?;
    }
    Ok(())
}

fn write_attach_header_v2(
    stream: &mut impl Write,
    created: bool,
    snapshot: &TerminalSnapshot,
) -> io::Result<()> {
    writeln!(stream, "PROTOCOL {CURRENT_PROTOCOL_VERSION}")?;
    writeln!(stream, "READY {}", if created { 1 } else { 0 })?;
    writeln!(
        stream,
        "SNAPSHOT {} {} {} {}",
        snapshot.sequence,
        snapshot.rows,
        snapshot.cols,
        BASE64.encode(&snapshot.screen)
    )?;
    write_history_page(stream, snapshot)
}

fn write_history_page(stream: &mut impl Write, page: &TerminalSnapshot) -> io::Result<()> {
    writeln!(
        stream,
        "HISTORY_PAGE {} {} {} {}",
        page.history_start_sequence,
        page.sequence,
        if page.has_older_history { 1 } else { 0 },
        BASE64.encode(&page.history)
    )
}

fn write_session_list(stream: &mut UnixStream, state: &DaemonState) -> io::Result<()> {
    let sessions = state
        .sessions
        .lock()
        .expect("sessions lock poisoned")
        .values()
        .cloned()
        .collect::<Vec<_>>();
    let metadata: Vec<SessionMetadata> = sessions
        .iter()
        .filter(|session| !session.exited.load(Ordering::SeqCst))
        .map(|session| session.metadata_snapshot())
        .collect();
    let json = serde_json::to_vec(&metadata).map_err(invalid_data)?;
    writeln!(stream, "SESSIONS {}", BASE64.encode(json))
}

fn parse_attach(line: &str) -> io::Result<AttachRequest> {
    let parts: Vec<&str> = line.split_whitespace().collect();
    let (protocol_version, client_role, field_offset) = match parts.as_slice() {
        ["ATTACH", ..] if parts.len() == 5 => (PREVIOUS_PROTOCOL_VERSION, ClientRole::Mac, 1),
        ["ATTACH2", version, role, _client_id, ..] if parts.len() == 8 => {
            let version = version.parse::<u16>().map_err(|_| {
                io::Error::new(io::ErrorKind::InvalidInput, "invalid protocol version")
            })?;
            if !(PREVIOUS_PROTOCOL_VERSION..=CURRENT_PROTOCOL_VERSION).contains(&version) {
                return Err(io::Error::new(
                    io::ErrorKind::Unsupported,
                    "unsupported protocol version",
                ));
            }
            let role = match *role {
                "mac" => ClientRole::Mac,
                "phone" => ClientRole::Phone,
                _ => {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidInput,
                        "invalid client role",
                    ));
                }
            };
            (version, role, 4)
        }
        _ => {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "expected ATTACH or ATTACH2",
            ));
        }
    };
    if parts.len() != field_offset + 4 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "invalid attach fields",
        ));
    }

    let session_id = decode_string(parts[field_offset])?;
    let cwd = PathBuf::from(decode_string(parts[field_offset + 1])?);
    let shell = decode_string(parts[field_offset + 2])?;
    let env_blob = if parts[field_offset + 3] == "-" {
        Vec::new()
    } else {
        BASE64
            .decode(parts[field_offset + 3])
            .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "invalid environment"))?
    };
    let environment = String::from_utf8_lossy(&env_blob)
        .split('\0')
        .filter_map(|entry| {
            let (key, value) = entry.split_once('=')?;
            Some((key.to_owned(), value.to_owned()))
        })
        .collect();

    Ok(AttachRequest {
        session_id,
        cwd,
        shell,
        environment,
        protocol_version,
        client_role,
    })
}

fn decode_string(value: &str) -> io::Result<String> {
    let bytes = BASE64
        .decode(value)
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "invalid base64"))?;
    String::from_utf8(bytes)
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "invalid utf8"))
}

fn decode_state_update(value: &str) -> io::Result<SessionStateUpdate> {
    let json = if value.trim_start().starts_with('{') {
        value.as_bytes().to_vec()
    } else {
        BASE64
            .decode(value)
            .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "invalid state base64"))?
    };
    serde_json::from_slice(&json).map_err(invalid_data)
}

fn invalid_data(error: impl std::error::Error) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, error.to_string())
}

fn unix_timestamp_now() -> f64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_secs_f64())
        .unwrap_or(0.0)
}

fn default_title_for_cwd(cwd: &Path) -> String {
    cwd.file_name()
        .and_then(|name| name.to_str())
        .filter(|name| !name.is_empty())
        .unwrap_or("~")
        .to_owned()
}

fn socket_path() -> io::Result<PathBuf> {
    if let Some(path) = env::var_os("VAULTTY_SESSIOND_SOCKET") {
        return Ok(PathBuf::from(path));
    }
    let home = env::var_os("HOME").ok_or_else(|| {
        io::Error::new(io::ErrorKind::NotFound, "HOME is required for socket path")
    })?;
    Ok(PathBuf::from(home)
        .join("Library")
        .join("Application Support")
        .join("Vaultty")
        .join("runtime")
        .join("sessiond.sock"))
}

fn validate_peer(stream: &UnixStream) -> io::Result<()> {
    if env::var_os("VAULTTY_SESSIOND_DISABLE_PEER_VALIDATION").is_some() {
        return Ok(());
    }

    let mut uid: libc::uid_t = 0;
    let mut gid: libc::gid_t = 0;
    let rc = unsafe { libc::getpeereid(stream.as_raw_fd(), &mut uid, &mut gid) };
    if rc != 0 {
        return Err(io::Error::last_os_error());
    }
    if uid != unsafe { libc::geteuid() } {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "peer uid does not match daemon uid",
        ));
    }

    #[cfg(target_os = "macos")]
    validate_peer_signature(stream)?;

    Ok(())
}

#[cfg(target_os = "macos")]
fn validate_peer_signature(stream: &UnixStream) -> io::Result<()> {
    let pid = peer_pid(stream.as_raw_fd())?;
    let path = process_path(pid)?;
    let output = Command::new("/usr/bin/codesign")
        .args(["-dv", "--verbose=4"])
        .arg(&path)
        .output()?;
    let text = String::from_utf8_lossy(&output.stderr);
    let path_text = String::from_utf8_lossy(path.as_os_str().as_bytes());
    let looks_like_vaultty = path_text.ends_with("/Contents/MacOS/Vaultty")
        || path_text.ends_with("/Vaultty")
        || path_text.ends_with("/vaultty-session-bridge");
    let signed_by_expected_team =
        text.contains("TeamIdentifier=") && !text.contains("TeamIdentifier=not set");

    if output.status.success() && looks_like_vaultty && signed_by_expected_team {
        return Ok(());
    }

    Err(io::Error::new(
        io::ErrorKind::PermissionDenied,
        format!("peer process is not signed Vaultty: {}", path.display()),
    ))
}

#[cfg(target_os = "macos")]
fn peer_pid(fd: RawFd) -> io::Result<pid_t> {
    const LOCAL_PEERPID: c_int = 2;
    let mut pid: pid_t = 0;
    let mut len = std::mem::size_of::<pid_t>() as libc::socklen_t;
    let rc = unsafe {
        libc::getsockopt(
            fd,
            libc::SOL_LOCAL,
            LOCAL_PEERPID,
            &mut pid as *mut _ as *mut c_void,
            &mut len,
        )
    };
    if rc == 0 {
        Ok(pid)
    } else {
        Err(io::Error::last_os_error())
    }
}

#[cfg(target_os = "macos")]
fn process_path(pid: pid_t) -> io::Result<PathBuf> {
    let mut buffer = vec![0_u8; libc::PROC_PIDPATHINFO_MAXSIZE as usize];
    let count =
        unsafe { libc::proc_pidpath(pid, buffer.as_mut_ptr() as *mut c_void, buffer.len() as u32) };
    if count <= 0 {
        return Err(io::Error::last_os_error());
    }
    buffer.truncate(count as usize);
    Ok(PathBuf::from(std::ffi::OsString::from_vec(buffer)))
}

fn reap_child(pid: pid_t) -> i32 {
    let mut status: c_int = 0;
    loop {
        let rc = unsafe { libc::waitpid(pid, &mut status, 0) };
        if rc >= 0 {
            break;
        }
        if io::Error::last_os_error().raw_os_error() != Some(libc::EINTR) {
            return -1;
        }
    }
    if status & 0x7f == 0 {
        (status >> 8) & 0xff
    } else {
        128 + (status & 0x7f)
    }
}

fn shell_is_foreground(session: &Session) -> bool {
    let mut foreground_process_group: pid_t = 0;
    let shell_process_group = unsafe { libc::getpgid(session.child_pid) };
    shell_process_group > 0
        && unsafe { libc::ioctl(session.master_fd, TIOCGPGRP, &mut foreground_process_group) } == 0
        && foreground_process_group == shell_process_group
}

fn history_has_unfinished_command(history: &[u8]) -> bool {
    let last_start = last_marker_offset(history, COMMAND_STARTED_MARKER);
    let last_finish = last_marker_offset(history, COMMAND_FINISHED_MARKER);
    last_start.is_some_and(|start| last_finish.is_none_or(|finish| start > finish))
}

fn last_marker_offset(history: &[u8], marker: &[u8]) -> Option<usize> {
    history
        .windows(marker.len())
        .rposition(|window| window == marker)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn encoded(value: &str) -> String {
        BASE64.encode(value)
    }

    #[test]
    fn parse_attach_accepts_expected_wire_shape() {
        let line = format!(
            "ATTACH {} {} {} {}",
            encoded("session-1"),
            encoded("/tmp"),
            encoded("/bin/sh"),
            encoded("TERM=xterm-256color\0VAULTTY=1")
        );

        let request = parse_attach(&line).expect("attach request should parse");

        assert_eq!(request.session_id, "session-1");
        assert_eq!(request.cwd, PathBuf::from("/tmp"));
        assert_eq!(request.shell, "/bin/sh");
        assert_eq!(
            request.environment,
            vec![
                ("TERM".to_owned(), "xterm-256color".to_owned()),
                ("VAULTTY".to_owned(), "1".to_owned())
            ]
        );
    }

    #[test]
    fn parse_attach_rejects_malformed_input() {
        let error = parse_attach("ATTACH too few fields").expect_err("input should fail");
        assert_eq!(error.kind(), io::ErrorKind::InvalidInput);
    }

    #[test]
    fn parse_attach_v2_tracks_client_role_and_version() {
        let line = format!(
            "ATTACH2 2 phone {} {} {} {} -",
            encoded("phone-1"),
            encoded("session-1"),
            encoded("/tmp"),
            encoded("/bin/sh")
        );

        let request = parse_attach(&line).expect("v2 attach should parse");

        assert_eq!(request.protocol_version, CURRENT_PROTOCOL_VERSION);
        assert_eq!(request.client_role, ClientRole::Phone);
        assert!(request.environment.is_empty());
    }

    #[test]
    fn terminal_state_produces_ordered_snapshot_and_history_pages() {
        let mut terminal = TerminalState::new(24, 80);
        assert_eq!(terminal.record(b"first\n".to_vec()), 1);
        assert_eq!(terminal.record(b"second\n".to_vec()), 2);
        assert_eq!(terminal.record(b"third".to_vec()), 3);

        let snapshot = terminal.snapshot(1);
        assert_eq!(snapshot.sequence, 3);
        assert_eq!(snapshot.history, b"second\nthird");
        assert_eq!(snapshot.history_start_sequence, 2);
        assert!(snapshot.has_older_history);
        assert!(snapshot.screen.windows(5).any(|bytes| bytes == b"third"));

        let page = terminal.history_before(snapshot.history_start_sequence, 1);
        assert_eq!(page.history, b"first\n");
        assert!(!page.has_older_history);
    }

    #[test]
    fn terminal_state_enforces_rendered_line_limit() {
        let mut terminal = TerminalState::new(24, 80);
        for _ in 0..=MAX_SCROLLBACK_LINES {
            terminal.record(b"line\n".to_vec());
        }

        let snapshot = terminal.snapshot(MAX_SCROLLBACK_LINES + 1);

        assert_eq!(
            snapshot
                .history
                .iter()
                .filter(|byte| **byte == b'\n')
                .count(),
            MAX_SCROLLBACK_LINES
        );
        assert_eq!(snapshot.history_start_sequence, 2);
    }

    #[test]
    fn state_update_accepts_json_or_base64_json() {
        let json = r#"{"title":"build","cwd":"/repo","commandCount":3,"runningCommand":"cargo test","commandHistory":["cargo test"]}"#;
        let direct = decode_state_update(json).expect("direct JSON should parse");
        let base64 = decode_state_update(&encoded(json)).expect("base64 JSON should parse");

        assert_eq!(direct.title.as_deref(), Some("build"));
        assert_eq!(base64.cwd.as_deref(), Some("/repo"));
        assert_eq!(base64.command_count, Some(3));
        assert_eq!(base64.command_history, Some(vec!["cargo test".to_owned()]));
    }

    #[test]
    fn metadata_update_preserves_unspecified_fields() {
        let request = AttachRequest {
            session_id: "session-1".to_owned(),
            cwd: PathBuf::from("/tmp/project"),
            shell: "/bin/sh".to_owned(),
            environment: Vec::new(),
            protocol_version: PREVIOUS_PROTOCOL_VERSION,
            client_role: ClientRole::Mac,
        };
        let metadata = SessionMetadata::new(&request);

        assert_eq!(metadata.session_id, "session-1");
        assert_eq!(metadata.title, "project");
        assert_eq!(metadata.cwd, "/tmp/project");
        assert_eq!(metadata.command_count, 0);
    }

    #[test]
    fn session_clear_history_keeps_command_metadata() {
        let request = AttachRequest {
            session_id: "session-1".to_owned(),
            cwd: PathBuf::from("/tmp/project"),
            shell: "/bin/sh".to_owned(),
            environment: Vec::new(),
            protocol_version: PREVIOUS_PROTOCOL_VERSION,
            client_role: ClientRole::Mac,
        };
        let session = Session {
            session_id: request.session_id.clone(),
            master_fd: -1,
            child_pid: 0,
            exited: AtomicBool::new(false),
            attached_client_count: AtomicUsize::new(0),
            terminal: Mutex::new({
                let mut terminal = TerminalState::new(24, 80);
                terminal.record(b"old block output".to_vec());
                terminal
            }),
            metadata: Mutex::new(SessionMetadata {
                command_history: vec!["cargo test".to_owned()],
                ..SessionMetadata::new(&request)
            }),
            clients: Mutex::new(Vec::new()),
            state: Weak::new(),
        };

        session.clear_history();

        assert!(
            session
                .terminal
                .lock()
                .expect("terminal lock poisoned")
                .snapshot(MAX_SCROLLBACK_LINES)
                .history
                .is_empty()
        );
        assert_eq!(
            session
                .metadata
                .lock()
                .expect("metadata lock poisoned")
                .command_history,
            vec!["cargo test".to_owned()]
        );
    }

    #[test]
    fn attach_header_signals_empty_history_replay() {
        let mut output = Vec::new();

        write_attach_header(&mut output, false, b"").expect("header should encode");

        assert_eq!(output, b"READY 0\nHISTORY \n");
    }

    #[test]
    fn new_session_with_empty_history_only_reports_ready() {
        let mut output = Vec::new();

        write_attach_header(&mut output, true, b"").expect("header should encode");

        assert_eq!(output, b"READY 1\n");
    }

    #[test]
    fn history_detects_unfinished_command_replay() {
        assert!(!history_has_unfinished_command(b"plain output"));
        assert!(history_has_unfinished_command(
            b"\x1b]133;C;ZWNobyBoaQo=\x07output"
        ));
        assert!(!history_has_unfinished_command(
            b"\x1b]133;C;ZWNobyBoaQo=\x07output\x1b]133;D;0\x07"
        ));
        assert!(history_has_unfinished_command(
            b"\x1b]133;C;MQ==\x07\x1b]133;D;0\x07\x1b]133;C;Mg==\x07"
        ));
    }
}
