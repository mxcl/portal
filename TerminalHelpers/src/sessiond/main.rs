use base64::Engine;
use base64::engine::general_purpose::STANDARD as BASE64;
use libc::{TIOCGPGRP, TIOCSWINSZ, c_char, c_int, c_void, pid_t, winsize};
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, VecDeque};
use std::env;
use std::ffi::{CString, OsString};
use std::fs::{self, File, OpenOptions};
use std::io::{self, BufRead, BufReader, Write};
use std::os::fd::{AsRawFd, RawFd};
use std::os::unix::ffi::{OsStrExt, OsStringExt};
use std::os::unix::fs::{FileTypeExt, OpenOptionsExt, PermissionsExt};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::mpsc::{self, Sender};
use std::sync::{Arc, Mutex, Weak};
use std::thread;
use std::time::{SystemTime, UNIX_EPOCH};

#[path = "../macos_peer.rs"]
mod macos_peer;

#[path = "../runtime.rs"]
mod runtime;
use runtime::socket_path;

const COMMAND_STARTED_MARKER: &[u8] = b"\x1b]133;C;";
const COMMAND_FINISHED_MARKER: &[u8] = b"\x1b]133;D;";
const SYNTHETIC_COMMAND_FINISHED_MARKER: &[u8] = b"\x1b]133;D;0\x07";
const INTERRUPTED_COMMAND_FINISHED_MARKER: &[u8] = b"\x1b]133;D;130\x07";
const CURRENT_PROTOCOL_VERSION: u16 = 2;
const PREVIOUS_PROTOCOL_VERSION: u16 = 1;
const MAX_SCROLLBACK_LINES: usize = 10_000;
const MAX_HISTORY_PAGE_BYTES: usize = 256 * 1024;
const MAX_REWRITE_LINE_BYTES: usize = 4 * 1024;
const INITIAL_HISTORY_LINES: usize = 1_000;
const DAEMON_STARTUP_PROBES: usize = 5;

#[derive(Clone, Debug)]
struct AttachRequest {
    session_id: String,
    cwd: PathBuf,
    shell: String,
    environment: Vec<(String, String)>,
    protocol_version: u16,
    client_role: ClientRole,
    allows_creation: bool,
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

#[derive(Default)]
struct HistoryFilter {
    alternate_screen: bool,
    pending_control: Vec<u8>,
    normal_line: Vec<u8>,
    pending_carriage_return: bool,
}

impl HistoryFilter {
    // Fullscreen repaint bytes belong to the live screen, not scrollback replay.
    fn compact(&mut self, bytes: &[u8]) -> Vec<u8> {
        let mut retained = Vec::with_capacity(if self.alternate_screen {
            16
        } else {
            bytes.len()
        });
        for &byte in bytes {
            self.consume(byte, &mut retained);
        }
        retained
    }

    fn consume(&mut self, byte: u8, retained: &mut Vec<u8>) {
        loop {
            match self.pending_control.as_slice() {
                [] => {
                    if matches!(byte, 0x1b | 0x9b | 0x9d) {
                        self.pending_control.push(byte);
                    } else if !self.alternate_screen {
                        self.retain_normal_byte(byte, retained);
                    }
                    return;
                }
                [0x1b] if matches!(byte, b'[' | b']') => {
                    self.pending_control.push(byte);
                    return;
                }
                [0x1b] => {
                    if !self.alternate_screen {
                        self.begin_replacement();
                        self.normal_line.push(0x1b);
                    }
                    self.pending_control.clear();
                }
                _ => {
                    self.pending_control.push(byte);
                    if is_osc(&self.pending_control) {
                        if osc_is_complete(&self.pending_control) {
                            if replay_relevant_osc(&self.pending_control) {
                                if self.pending_control.starts_with(COMMAND_STARTED_MARKER) {
                                    self.normal_line.clear();
                                    self.pending_carriage_return = false;
                                } else {
                                    self.flush_line(retained);
                                    if self.pending_carriage_return {
                                        retained.push(b'\r');
                                        self.pending_carriage_return = false;
                                    }
                                }
                                retained.extend_from_slice(&self.pending_control);
                            } else if !self.alternate_screen {
                                self.normal_line.extend_from_slice(&self.pending_control);
                            }
                            self.pending_control.clear();
                        } else if self.pending_control.len() > 8 * 1024 {
                            if !self.alternate_screen {
                                self.normal_line.extend_from_slice(&self.pending_control);
                            }
                            self.pending_control.clear();
                        }
                        return;
                    }
                    if (0x40..=0x7e).contains(&byte) {
                        let transition = alternate_screen_transition(&self.pending_control);
                        if replay_relevant_csi(&self.pending_control) || !self.alternate_screen {
                            if !self.alternate_screen {
                                self.begin_replacement();
                            }
                            self.normal_line.extend_from_slice(&self.pending_control);
                        }
                        if let Some(alternate_screen) = transition {
                            self.alternate_screen = alternate_screen;
                        }
                        self.pending_control.clear();
                    } else if self.pending_control.len() > 128 {
                        if !self.alternate_screen {
                            self.begin_replacement();
                            self.normal_line.extend_from_slice(&self.pending_control);
                        }
                        self.pending_control.clear();
                    }
                    return;
                }
            }
        }
    }

    fn begin_replacement(&mut self) {
        if self.pending_carriage_return {
            self.normal_line.clear();
            self.pending_carriage_return = false;
        }
    }

    fn retain_normal_byte(&mut self, byte: u8, retained: &mut Vec<u8>) {
        if self.pending_carriage_return {
            if byte == b'\r' {
                return;
            }
            self.pending_carriage_return = false;
            if byte == b'\n' {
                self.normal_line.push(byte);
                self.flush_line(retained);
                return;
            }
            self.normal_line.clear();
        }

        match byte {
            b'\r' => self.pending_carriage_return = true,
            b'\n' => {
                self.normal_line.push(byte);
                self.flush_line(retained);
            }
            _ => {
                self.normal_line.push(byte);
                if self.normal_line.len() >= MAX_REWRITE_LINE_BYTES {
                    // ponytail: cap an unterminated line; terminal-sized redraws stay compactable.
                    self.flush_line(retained);
                }
            }
        }
    }

    fn flush_line(&mut self, retained: &mut Vec<u8>) {
        if is_portal_command_echo(&self.normal_line) || is_transient_progress_bar(&self.normal_line)
        {
            self.normal_line.clear();
        } else {
            retained.append(&mut self.normal_line);
        }
    }

    fn pending_replay(&self) -> Vec<u8> {
        let mut replay = self.normal_line.clone();
        if self.pending_carriage_return {
            replay.push(b'\r');
        }
        if !self.alternate_screen {
            replay.extend_from_slice(&self.pending_control);
        }
        replay
    }

    fn clear(&mut self, alternate_screen: bool) {
        self.alternate_screen = alternate_screen;
        self.pending_control.clear();
        self.normal_line.clear();
        self.pending_carriage_return = false;
    }
}

fn is_portal_command_echo(line: &[u8]) -> bool {
    [
        b"__portal_cmd=".as_slice(),
        b"__portal_command_b64=",
        b"133;C;",
    ]
    .into_iter()
    .all(|needle| line.windows(needle.len()).any(|window| window == needle))
}

fn is_transient_progress_bar(line: &[u8]) -> bool {
    // ponytail: match pure SwiftPM-style bars; use terminal-grid scrollback if more shapes appear.
    if !line.contains(&b'%') {
        return false;
    }
    let mut visible = Vec::with_capacity(line.len());
    let mut index = 0;
    while index < line.len() {
        if line[index..].starts_with(b"\x1b[") {
            let Some(end) = line[index + 2..].iter().position(|byte| *byte == b'm') else {
                return false;
            };
            if !line[index + 2..index + 2 + end]
                .iter()
                .all(|byte| byte.is_ascii_digit() || *byte == b';')
            {
                return false;
            }
            index += end + 3;
        } else {
            visible.push(line[index]);
            index += 1;
        }
    }

    let Some(visible) = visible.strip_suffix(b"\n") else {
        return false;
    };
    let Some(separator) = visible.iter().position(|byte| *byte == b'%') else {
        return false;
    };
    let (percent, bar) = visible.split_at(separator);
    let bar = &bar[1..];
    let Some(percent) = std::str::from_utf8(percent)
        .ok()
        .and_then(|percent| percent.trim_start().parse::<u8>().ok())
    else {
        return false;
    };
    let Some(bar) = bar
        .strip_prefix(b" [")
        .and_then(|bar| bar.strip_suffix(b"]"))
    else {
        return false;
    };
    percent <= 100 && !bar.is_empty() && bar.iter().all(|byte| matches!(byte, b'=' | b'-'))
}

fn is_osc(control: &[u8]) -> bool {
    control.starts_with(b"\x1b]") || control.starts_with(&[0x9d])
}

fn osc_is_complete(control: &[u8]) -> bool {
    control.ends_with(&[0x07]) || control.ends_with(b"\x1b\\")
}

fn replay_relevant_osc(control: &[u8]) -> bool {
    control
        .strip_prefix(b"\x1b]")
        .or_else(|| control.strip_prefix(&[0x9d]))
        .is_some_and(|body| body.starts_with(b"133;"))
}

fn alternate_screen_transition(csi: &[u8]) -> Option<bool> {
    private_mode_transition(csi, &[b"47", b"1047", b"1049"])
}

fn replay_relevant_csi(csi: &[u8]) -> bool {
    private_mode_transition(csi, &[b"1", b"47", b"1047", b"1049"]).is_some()
}

fn private_mode_transition(csi: &[u8], relevant_modes: &[&[u8]]) -> Option<bool> {
    let body = if csi.starts_with(b"\x1b[") {
        &csi[2..]
    } else if csi.starts_with(&[0x9b]) {
        &csi[1..]
    } else {
        return None;
    };
    let (&final_byte, parameters) = body.split_last()?;
    if !matches!(final_byte, b'h' | b'l') || !parameters.starts_with(b"?") {
        return None;
    }
    parameters[1..]
        .split(|byte| *byte == b';')
        .any(|mode| relevant_modes.contains(&mode))
        .then_some(final_byte == b'h')
}

fn select_history<'a>(
    chunks: impl Iterator<Item = &'a OutputChunk>,
    max_lines: usize,
) -> Vec<&'a OutputChunk> {
    let max_bytes = if max_lines == usize::MAX {
        usize::MAX
    } else {
        MAX_HISTORY_PAGE_BYTES
    };
    let mut selected = Vec::new();
    let mut selected_lines: usize = 0;
    let mut selected_bytes: usize = 0;
    let mut limit_len = None;
    for chunk in chunks {
        selected.push(chunk);
        selected_lines = selected_lines.saturating_add(chunk.line_count);
        selected_bytes = selected_bytes.saturating_add(chunk.bytes.len());
        let reached_limit = selected_lines >= max_lines || selected_bytes >= max_bytes;
        if reached_limit {
            let original_limit = *limit_len.get_or_insert(selected.len());
            // Include the command boundary when it fits inside the byte ceiling.
            if max_lines == usize::MAX
                || selected_contains_marker(&selected, COMMAND_STARTED_MARKER)
            {
                break;
            }
            if selected_bytes >= max_bytes {
                selected.truncate(original_limit);
                break;
            }
        }
    }
    if let Some(original_limit) = limit_len
        && !selected_contains_marker(&selected, COMMAND_STARTED_MARKER)
    {
        selected.truncate(original_limit);
    }
    selected.reverse();
    selected
}

fn selected_contains_marker(chunks_newest_first: &[&OutputChunk], marker: &[u8]) -> bool {
    let mut window = VecDeque::with_capacity(marker.len());
    for byte in chunks_newest_first
        .iter()
        .rev()
        .flat_map(|chunk| chunk.bytes.iter().copied())
    {
        if window.len() == marker.len() {
            window.pop_front();
        }
        window.push_back(byte);
        if window.len() == marker.len() && window.iter().copied().eq(marker.iter().copied()) {
            return true;
        }
    }
    false
}

struct TerminalState {
    parser: vt100::Parser,
    history_filter: HistoryFilter,
    chunks: VecDeque<OutputChunk>,
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
            history_filter: HistoryFilter::default(),
            chunks: VecDeque::new(),
            next_sequence: 1,
            rows,
            cols,
        }
    }

    fn record(&mut self, bytes: Vec<u8>) -> u64 {
        self.parser.process(&bytes);
        let sequence = self.next_sequence;
        self.next_sequence = self.next_sequence.saturating_add(1);
        let bytes = self.history_filter.compact(&bytes);
        if !bytes.is_empty() {
            let line_count = bytes.iter().filter(|byte| **byte == b'\n').count();
            self.chunks.push_back(OutputChunk {
                sequence,
                bytes,
                line_count,
            });
        }
        sequence
    }

    fn snapshot(&self, history_lines: usize) -> TerminalSnapshot {
        let selected = select_history(self.chunks.iter().rev(), history_lines);
        let history_start_sequence = selected
            .first()
            .map_or(self.next_sequence, |chunk| chunk.sequence);
        let has_older_history = self
            .chunks
            .front()
            .is_some_and(|chunk| chunk.sequence < history_start_sequence);
        let mut history = self.history_with_command_boundary(&selected);
        history.extend(self.history_filter.pending_replay());
        let mut screen = Vec::new();
        if self.parser.screen().alternate_screen() {
            screen.extend_from_slice(b"\x1b[?1049h");
        }
        screen.extend(self.parser.screen().state_formatted());
        if history_lines == usize::MAX && self.parser.screen().alternate_screen() {
            // v1 has no SNAPSHOT message, so finish its replay with the live screen.
            history.extend_from_slice(&screen);
        }
        TerminalSnapshot {
            sequence: self.next_sequence.saturating_sub(1),
            rows: self.rows,
            cols: self.cols,
            screen,
            history,
            history_start_sequence,
            has_older_history,
        }
    }

    fn history_before(&self, before_sequence: u64, max_lines: usize) -> TerminalSnapshot {
        let selected = select_history(
            self.chunks
                .iter()
                .rev()
                .filter(|chunk| chunk.sequence < before_sequence),
            max_lines,
        );
        let history_start_sequence = selected
            .first()
            .map_or(before_sequence, |chunk| chunk.sequence);
        let has_older_history = self
            .chunks
            .front()
            .is_some_and(|chunk| chunk.sequence < history_start_sequence);
        let history = self.history_with_command_boundary(&selected);
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

    fn history_with_command_boundary(&self, selected: &[&OutputChunk]) -> Vec<u8> {
        let mut history = Vec::new();
        if let Some(first) = selected
            .first()
            .filter(|first| !first.bytes.starts_with(COMMAND_STARTED_MARKER))
        {
            // Released readers need C even when a bounded page starts mid-command.
            // HistoryFilter emits each complete OSC in one chunk.
            for chunk in self
                .chunks
                .iter()
                .rev()
                .filter(|c| c.sequence < first.sequence)
            {
                let start = last_marker_offset(&chunk.bytes, COMMAND_STARTED_MARKER);
                let finish = last_marker_offset(&chunk.bytes, COMMAND_FINISHED_MARKER);
                if finish.is_some_and(|finish| start.is_none_or(|start| finish > start)) {
                    break;
                }
                if let Some(start) = start {
                    if let Some(end) = ((start + COMMAND_STARTED_MARKER.len())..=chunk.bytes.len())
                        .find(|&end| osc_is_complete(&chunk.bytes[start..end]))
                    {
                        history.extend_from_slice(&chunk.bytes[start..end]);
                    }
                    break;
                }
            }
        }
        history.extend(
            selected
                .iter()
                .flat_map(|chunk| chunk.bytes.iter().copied()),
        );
        history
    }

    fn resize(&mut self, rows: u16, cols: u16) {
        self.rows = rows;
        self.cols = cols;
        self.parser.screen_mut().set_size(rows, cols);
    }

    fn clear_history(&mut self) {
        self.chunks.clear();
        self.history_filter
            .clear(self.parser.screen().alternate_screen());
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
    last_command_at: Option<f64>,
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
    last_command_at: Option<f64>,
    running_command: Option<String>,
    command_history: Option<Vec<String>>,
}

struct Session {
    session_id: String,
    master_fd: RawFd,
    child_pid: pid_t,
    exited: AtomicBool,
    interrupt_reconciliation_running: AtomicBool,
    attached_client_count: AtomicUsize,
    terminal: Mutex<TerminalState>,
    metadata: Mutex<SessionMetadata>,
    clients: Mutex<Vec<Sender<SessionEvent>>>,
    state: Weak<DaemonState>,
}

struct ChildLaunch {
    cwd: CString,
    shell: CString,
    login_shell: CString,
    _environment: Vec<CString>,
    environment_pointers: Vec<*const c_char>,
}

impl ChildLaunch {
    fn new(request: &AttachRequest) -> io::Result<Self> {
        let cwd = CString::new(request.cwd.as_os_str().as_bytes())
            .map_err(|_| invalid_child_value("working directory"))?;
        let shell = CString::new(request.shell.as_bytes())
            .unwrap_or_else(|_| CString::new("/bin/zsh").expect("static shell path is valid"));
        let shell_name = Path::new(&request.shell)
            .file_name()
            .and_then(|name| name.to_str())
            .unwrap_or("zsh");
        let login_shell = CString::new(format!("-{shell_name}"))
            .unwrap_or_else(|_| CString::new("-zsh").expect("static argv is valid"));

        let mut inherited: HashMap<OsString, OsString> = env::vars_os().collect();
        for (key, value) in &request.environment {
            inherited.insert(OsString::from(key), OsString::from(value));
        }
        // The app or daemon may have been launched by an agent, but these are human
        // terminal sessions. Inherited agent markers make CLIs disable interaction.
        inherited.retain(|key, _| {
            !matches!(
                key.to_str(),
                Some(
                    "CODEX_CI"
                        | "CODEX_THREAD_ID"
                        | "CODEX_SANDBOX"
                        | "CODEX_SANDBOX_NETWORK_DISABLED"
                        | "CODEX_INTERNAL_ORIGINATOR_OVERRIDE"
                        | "CLAUDECODE"
                        | "CLAUDE_CODE_ENTRYPOINT"
                        | "CLINE_ACTIVE"
                        | "CURSOR_AGENT"
                        | "GEMINI_CLI"
                        | "OPENCODE"
                        | "OPENCLAW_SHELL"
                        | "ANTIGRAVITY_CLI_ALIAS"
                )
            )
        });
        let environment = inherited
            .into_iter()
            .map(|(key, value)| {
                let mut entry = key.into_vec();
                entry.push(b'=');
                entry.extend(value.into_vec());
                CString::new(entry).map_err(|_| invalid_child_value("environment"))
            })
            .collect::<io::Result<Vec<_>>>()?;
        let mut environment_pointers = environment
            .iter()
            .map(|entry| entry.as_ptr())
            .collect::<Vec<_>>();
        environment_pointers.push(std::ptr::null());

        Ok(Self {
            cwd,
            shell,
            login_shell,
            _environment: environment,
            environment_pointers,
        })
    }

    fn exec(&self) -> ! {
        // After forkpty only async-signal-safe operations are valid. In particular,
        // Rust's current-directory and environment APIs may acquire inherited locks.
        if unsafe { libc::chdir(self.cwd.as_ptr()) } != 0 {
            unsafe { libc::_exit(126) }
        }
        let argv = [self.login_shell.as_ptr(), std::ptr::null()];
        unsafe {
            libc::execve(
                self.shell.as_ptr(),
                argv.as_ptr(),
                self.environment_pointers.as_ptr(),
            );
            libc::_exit(127);
        }
    }
}

fn invalid_child_value(name: &str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidInput, format!("invalid child {name}"))
}

impl Session {
    fn new(request: &AttachRequest, state: Weak<DaemonState>) -> io::Result<Arc<Self>> {
        let child_launch = ChildLaunch::new(request)?;
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
            child_launch.exec();
        }

        let session = Arc::new(Self {
            session_id: request.session_id.clone(),
            master_fd,
            child_pid: pid,
            exited: AtomicBool::new(false),
            interrupt_reconciliation_running: AtomicBool::new(false),
            attached_client_count: AtomicUsize::new(0),
            terminal: Mutex::new(TerminalState::new(size.ws_row, size.ws_col)),
            metadata: Mutex::new(SessionMetadata::new(request)),
            clients: Mutex::new(Vec::new()),
            state,
        });
        Self::start_reader(session.clone());
        Ok(session)
    }

    fn attach_client(
        &self,
        sender: Sender<SessionEvent>,
        history_lines: usize,
    ) -> TerminalSnapshot {
        let terminal = self.terminal.lock().expect("terminal lock poisoned");
        self.clients
            .lock()
            .expect("clients lock poisoned")
            .push(sender);
        terminal.snapshot(history_lines)
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
        if let Some(last_command_at) = update.last_command_at {
            metadata.last_command_at = Some(last_command_at);
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
        let completion = if history_has_unfinished_command(&history) {
            // ponytail: exit status is unknown for old incomplete replays; 0 restores input.
            let bytes = SYNTHETIC_COMMAND_FINISHED_MARKER.to_vec();
            Some((terminal.record(bytes.clone()), bytes))
        } else {
            None
        };
        drop(terminal);
        self.clear_running_command();
        if let Some((sequence, bytes)) = completion {
            self.broadcast(SessionEvent::Output { sequence, bytes });
        }
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

    fn interrupt(self: &Arc<Self>) {
        self.write_input(&[0x03]);
        // A command can catch SIGINT and return a retryable status; interrupt its shell too.
        unsafe {
            libc::kill(self.child_pid, libc::SIGINT);
        }
        if self
            .interrupt_reconciliation_running
            .swap(true, Ordering::SeqCst)
        {
            return;
        }
        let session = self.clone();
        thread::spawn(move || {
            while !session.exited.load(Ordering::SeqCst) {
                thread::sleep(std::time::Duration::from_millis(10));
                if shell_is_foreground(&session) {
                    session.report_interrupted_command_completion();
                    break;
                }
            }
            session
                .interrupt_reconciliation_running
                .store(false, Ordering::SeqCst);
        });
    }

    fn report_interrupted_command_completion(&self) {
        let bytes = INTERRUPTED_COMMAND_FINISHED_MARKER.to_vec();
        let mut terminal = self.terminal.lock().expect("terminal lock poisoned");
        let history = terminal.snapshot(MAX_SCROLLBACK_LINES).history;
        if !history_has_unfinished_command(&history) {
            return;
        }
        let sequence = terminal.record(bytes.clone());
        drop(terminal);
        self.clear_running_command();
        self.broadcast(SessionEvent::Output { sequence, bytes });
    }

    fn kill(&self) {
        unsafe {
            libc::kill(-self.child_pid, libc::SIGTERM);
            libc::kill(self.child_pid, libc::SIGTERM);
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
            unsafe {
                libc::close(session.master_fd);
            }
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
            last_command_at: None,
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
        Some("serve") => match args.next().as_deref() {
            None => serve(false),
            Some("--replace-socket") if args.next().is_none() => serve(true),
            _ => usage(),
        },
        _ => usage(),
    }
}

fn usage() -> io::Result<()> {
    eprintln!("usage: portal-sessiond serve [--replace-socket]");
    std::process::exit(64);
}

fn serve(replace_socket: bool) -> io::Result<()> {
    let socket_path = socket_path()?;
    if let Some(parent) = socket_path.parent() {
        fs::create_dir_all(parent)?;
        fs::set_permissions(parent, fs::Permissions::from_mode(0o700))?;
    }
    let (listener, _ownership) = claim_daemon_socket(&socket_path, replace_socket)?;
    let state = Arc::new(DaemonState {
        sessions: Mutex::new(HashMap::new()),
    });

    for stream in listener.incoming() {
        match stream {
            Ok(stream) => {
                let state = state.clone();
                thread::spawn(move || {
                    if let Err(error) = handle_client(stream, state) {
                        eprintln!("portal-sessiond client error: {error}");
                    }
                });
            }
            Err(error) => eprintln!("portal-sessiond accept error: {error}"),
        }
    }
    Ok(())
}

fn claim_daemon_socket(
    socket_path: &Path,
    replace_socket: bool,
) -> io::Result<(UnixListener, File)> {
    claim_daemon_socket_with_wait(socket_path, replace_socket, || {
        // v0.22 does not participate in the ownership lock. Give an adjacent
        // daemon already being spawned time to bind before reclaiming a stale path.
        thread::sleep(std::time::Duration::from_millis(25));
    })
}

fn claim_daemon_socket_with_wait(
    socket_path: &Path,
    replace_socket: bool,
    mut wait_for_adjacent_daemon: impl FnMut(),
) -> io::Result<(UnixListener, File)> {
    let ownership_path = socket_path.with_extension("lock");
    let ownership = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .mode(0o600)
        .open(ownership_path)?;
    if unsafe { libc::flock(ownership.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
        return Err(io::Error::last_os_error());
    }

    if replace_socket {
        if let Ok(metadata) = fs::symlink_metadata(socket_path)
            && !metadata.file_type().is_socket()
        {
            return Err(io::Error::new(
                io::ErrorKind::AddrInUse,
                format!(
                    "refusing to replace non-socket path {}",
                    socket_path.display()
                ),
            ));
        }
        let listener = publish_replacement_socket(socket_path)?;
        return Ok((listener, ownership));
    }

    for _ in 0..DAEMON_STARTUP_PROBES {
        if UnixStream::connect(socket_path).is_ok() {
            return Err(io::Error::new(
                io::ErrorKind::AddrInUse,
                "session daemon is already running",
            ));
        }
        wait_for_adjacent_daemon();
    }
    let listener = match UnixListener::bind(socket_path) {
        Ok(listener) => listener,
        Err(error) if error.kind() == io::ErrorKind::AddrInUse => {
            if let Ok(metadata) = fs::symlink_metadata(socket_path) {
                if !metadata.file_type().is_socket() {
                    return Err(io::Error::new(
                        io::ErrorKind::AddrInUse,
                        format!(
                            "refusing to replace non-socket path {}",
                            socket_path.display()
                        ),
                    ));
                }
            }

            if UnixStream::connect(socket_path).is_ok() {
                return Err(io::Error::new(
                    io::ErrorKind::AddrInUse,
                    "session daemon is already running",
                ));
            }
            publish_replacement_socket(socket_path)?
        }
        Err(error) => return Err(error),
    };
    fs::set_permissions(socket_path, fs::Permissions::from_mode(0o600))?;
    Ok((listener, ownership))
}

fn publish_replacement_socket(socket_path: &Path) -> io::Result<UnixListener> {
    // Bind before publishing so replacement is atomic and there is never an
    // unbound canonical socket path.
    let replacement_path = socket_path.with_extension("replacement");
    if let Ok(metadata) = fs::symlink_metadata(&replacement_path) {
        if !metadata.file_type().is_socket() {
            return Err(io::Error::new(
                io::ErrorKind::AddrInUse,
                format!(
                    "refusing to replace non-socket path {}",
                    replacement_path.display()
                ),
            ));
        }
        fs::remove_file(&replacement_path)?;
    }
    let replacement = UnixListener::bind(&replacement_path)?;
    fs::set_permissions(&replacement_path, fs::Permissions::from_mode(0o600))?;
    if let Err(error) = fs::rename(&replacement_path, socket_path) {
        drop(replacement);
        let _ = fs::remove_file(&replacement_path);
        return Err(error);
    }
    Ok(replacement)
}

fn handle_client(mut stream: UnixStream, state: Arc<DaemonState>) -> io::Result<()> {
    validate_peer(&stream)?;

    let reader_stream = stream.try_clone()?;
    let mut reader = BufReader::new(reader_stream);
    let mut line = String::new();
    if reader.read_line(&mut line)? == 0 {
        return Ok(());
    }

    if line.trim_end() == "PROTOCOLS" {
        writeln!(
            stream,
            "PROTOCOLS {PREVIOUS_PROTOCOL_VERSION} {CURRENT_PROTOCOL_VERSION}"
        )?;
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
    } else if !request.allows_creation {
        writeln!(stream, "NOT_FOUND")?;
        return Ok(());
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
    let history_lines = if request.protocol_version >= CURRENT_PROTOCOL_VERSION {
        INITIAL_HISTORY_LINES
    } else {
        // v1 clients predate paging and require the complete replay in HISTORY.
        usize::MAX
    };
    let snapshot = session.attach_client(tx, history_lines);
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
            state
                .sessions
                .lock()
                .expect("sessions lock poisoned")
                .remove(&request.session_id);
            session.kill();
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
    let (protocol_version, client_role, field_offset, allows_creation) = match parts.as_slice() {
        ["ATTACH", ..] if parts.len() == 5 => (PREVIOUS_PROTOCOL_VERSION, ClientRole::Mac, 1, true),
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
            (version, role, 4, true)
        }
        ["JOIN2", version, role, _client_id, ..] if parts.len() == 5 => {
            let version = version.parse::<u16>().map_err(|_| {
                io::Error::new(io::ErrorKind::InvalidInput, "invalid protocol version")
            })?;
            if version != CURRENT_PROTOCOL_VERSION {
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
            let session_id = decode_string(parts[4])?;
            return Ok(AttachRequest {
                session_id,
                cwd: PathBuf::new(),
                shell: String::new(),
                environment: Vec::new(),
                protocol_version: version,
                client_role: role,
                allows_creation: false,
            });
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
        allows_creation,
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

fn validate_peer(stream: &UnixStream) -> io::Result<()> {
    macos_peer::validate_client(stream)
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
    use std::os::unix::fs::MetadataExt;
    use std::time::Duration;

    fn encoded(value: &str) -> String {
        BASE64.encode(value)
    }

    fn wait_for_history(session: &Session, needle: &[u8], occurrences: usize) -> bool {
        let deadline = std::time::Instant::now() + Duration::from_secs(2);
        while std::time::Instant::now() < deadline {
            let history = session
                .terminal
                .lock()
                .expect("terminal lock poisoned")
                .snapshot(MAX_SCROLLBACK_LINES)
                .history;
            if history
                .windows(needle.len())
                .filter(|bytes| *bytes == needle)
                .count()
                >= occurrences
            {
                return true;
            }
            thread::sleep(Duration::from_millis(10));
        }
        false
    }

    #[test]
    fn snapshot_preserves_fullscreen_and_input_modes() {
        let mut terminal = TerminalState::new(24, 80);
        terminal.record(b"\x1b[?1049h\x1b[?1hfullscreen".to_vec());
        let snapshot = terminal.snapshot(INITIAL_HISTORY_LINES);
        let mut restored = vt100::Parser::new(24, 80, 0);
        restored.process(&snapshot.screen);
        assert!(restored.screen().alternate_screen());
        assert!(restored.screen().application_cursor());
        assert!(restored.screen().contents().contains("fullscreen"));
    }

    #[test]
    fn parse_attach_accepts_expected_wire_shape() {
        let line = format!(
            "ATTACH {} {} {} {}",
            encoded("session-1"),
            encoded("/tmp"),
            encoded("/bin/sh"),
            encoded("TERM=xterm-256color\0PORTAL=1")
        );

        let request = parse_attach(&line).expect("attach request should parse");

        assert_eq!(request.session_id, "session-1");
        assert_eq!(request.cwd, PathBuf::from("/tmp"));
        assert_eq!(request.shell, "/bin/sh");
        assert_eq!(
            request.environment,
            vec![
                ("TERM".to_owned(), "xterm-256color".to_owned()),
                ("PORTAL".to_owned(), "1".to_owned())
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
    fn terminal_state_preserves_complete_v1_history() {
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
            MAX_SCROLLBACK_LINES + 1
        );
        assert_eq!(snapshot.history_start_sequence, 1);
    }

    #[test]
    fn terminal_state_compacts_fullscreen_replay() {
        let mut terminal = TerminalState::new(24, 80);
        terminal.record(b"\x1b]133;C;build\x07\x1b[?1h\x1b[?10".to_vec());
        terminal.record(b"49hfirst frame\n".to_vec());
        for _ in 0..=INITIAL_HISTORY_LINES {
            terminal.record(b"next frame\n".to_vec());
        }
        terminal.record(b"\x1b[?1l\x1b[?1049lafter\n\x1b]133;D;0\x07".to_vec());
        for _ in 0..=INITIAL_HISTORY_LINES {
            terminal.record(b"tail\n".to_vec());
        }

        let snapshot = terminal.snapshot(INITIAL_HISTORY_LINES);

        assert!(
            snapshot
                .history
                .windows(COMMAND_STARTED_MARKER.len())
                .any(|bytes| { bytes == COMMAND_STARTED_MARKER })
        );
        assert!(
            snapshot
                .history
                .windows(8)
                .any(|bytes| bytes == b"\x1b[?1049h")
        );
        assert!(
            snapshot
                .history
                .windows(8)
                .any(|bytes| bytes == b"\x1b[?1049l")
        );
        assert!(
            snapshot
                .history
                .windows(5)
                .any(|bytes| bytes == b"\x1b[?1h")
        );
        assert!(
            snapshot
                .history
                .windows(5)
                .any(|bytes| bytes == b"\x1b[?1l")
        );
        assert!(snapshot.history.windows(6).any(|bytes| bytes == b"after\n"));
        assert!(!snapshot.history.windows(5).any(|bytes| bytes == b"frame"));
    }

    #[test]
    fn terminal_state_compacts_carriage_return_repaints() {
        let mut terminal = TerminalState::new(24, 80);
        terminal.record(b"\x1b]133;C;watch\x07progress 0%\r".to_vec());
        for percent in 1..=100 {
            terminal.record(format!("\x1b[2Kprogress {percent}%\r").into_bytes());
        }
        terminal.record(b"\x1b[2Kdone\nordinary\r\nlast status\r".to_vec());
        terminal.record(b"\x1b]133;D;0\x07".to_vec());

        let snapshot = terminal.snapshot(usize::MAX);

        assert!(
            snapshot
                .history
                .windows(COMMAND_STARTED_MARKER.len())
                .any(|bytes| bytes == COMMAND_STARTED_MARKER)
        );
        assert!(
            snapshot
                .history
                .windows(COMMAND_FINISHED_MARKER.len())
                .any(|bytes| bytes == COMMAND_FINISHED_MARKER)
        );
        assert!(snapshot.history.windows(5).any(|bytes| bytes == b"done\n"));
        assert!(
            snapshot
                .history
                .windows(9)
                .any(|bytes| bytes == b"ordinary\n")
        );
        assert!(
            snapshot
                .history
                .windows(11)
                .any(|bytes| bytes == b"last status")
        );
        assert!(
            !snapshot
                .history
                .windows(8)
                .any(|bytes| bytes == b"progress")
        );
        assert_eq!(
            snapshot
                .history
                .iter()
                .filter(|byte| **byte == b'\r')
                .count(),
            1
        );
        assert!(snapshot.history.len() < 128);
    }

    #[test]
    fn terminal_state_discards_transient_progress_bar_lines() {
        let mut terminal = TerminalState::new(24, 140);
        terminal.record(b"\x1b]133;C;build\x07".to_vec());
        for (padding, percent) in [("", 0), (" ", 0), ("  ", 46), ("", 82), ("", 100)] {
            let repaint = format!(
                "{padding}{percent}% \x1b[32m\x1b[1m[\x1b[0m\x1b[32m{}{}\x1b[0m\x1b[32m\x1b[1m]\x1b[0m\n",
                "=".repeat(percent),
                "-".repeat(100 - percent)
            );
            for chunk in repaint.as_bytes().chunks(7) {
                terminal.record(chunk.to_vec());
            }
        }
        terminal.record(b"Build succeeded\n\x1b]133;D;0\x07".to_vec());

        let snapshot = terminal.snapshot(usize::MAX);

        assert!(
            snapshot
                .history
                .windows(16)
                .any(|bytes| bytes == b"Build succeeded\n")
        );
        assert!(!snapshot.history.contains(&b'%'));
    }

    #[test]
    fn terminal_state_discards_echoed_portal_envelope_before_command_marker() {
        let mut terminal = TerminalState::new(24, 80);
        terminal.record(
            b"\x15__portal_cmd='fork'; __portal_command_b64='Zm9yaw=='; printf '\\033]133;C;%s\\a' \"$__portal_command_b64\"; __portal_typeahead_b64=''; printf '\\033]133;D;%s\\a' \"$__portal_status\"\r\n"
                .to_vec(),
        );
        terminal.record(b"\x1b]133;C;Zm9yaw==\x07forked\n\x1b]133;D;0\x07".to_vec());

        let snapshot = terminal.snapshot(usize::MAX);

        assert!(
            !snapshot
                .history
                .windows(8)
                .any(|bytes| bytes == b"__portal")
        );
        assert!(snapshot.history.starts_with(b"\x1b]133;C;Zm9yaw==\x07"));
    }

    #[test]
    fn terminal_state_preserves_pending_carriage_return_for_v1() {
        let mut terminal = TerminalState::new(24, 80);
        terminal.record(b"progress 99%\r".to_vec());

        let snapshot = terminal.snapshot(usize::MAX);

        assert_eq!(snapshot.history, b"progress 99%\r");
    }

    #[test]
    fn terminal_state_bounds_current_history_pages_by_bytes() {
        let mut terminal = TerminalState::new(24, 80);
        terminal.record(b"\x1b]133;C;stream\x07".to_vec());
        for _ in 0..100 {
            terminal.record(vec![b'x'; 4 * 1024]);
        }

        let current = terminal.snapshot(INITIAL_HISTORY_LINES);
        let previous = terminal.snapshot(usize::MAX);

        assert!(current.history.len() <= MAX_HISTORY_PAGE_BYTES + 4 * 1024);
        assert!(current.has_older_history);
        assert!(current.history.starts_with(b"\x1b]133;C;stream\x07"));
        let older_page = terminal.history_before(terminal.next_sequence, INITIAL_HISTORY_LINES);
        assert!(older_page.history.starts_with(b"\x1b]133;C;stream\x07"));
        assert_eq!(
            previous.history.len(),
            COMMAND_STARTED_MARKER.len() + 7 + 100 * 4 * 1024
        );
        assert!(!previous.has_older_history);
    }

    #[test]
    fn terminal_state_preserves_active_fullscreen_for_v1() {
        let mut terminal = TerminalState::new(24, 80);
        terminal.record(b"\x1b]133;C;watch\x07\x1b[?1049hold screen".to_vec());
        terminal.record(b"\x1b[2J\x1b[Hcurrent screen".to_vec());

        let current = terminal.snapshot(INITIAL_HISTORY_LINES);
        let previous = terminal.snapshot(usize::MAX);

        assert!(
            !current
                .history
                .windows(14)
                .any(|bytes| bytes == b"current screen")
        );
        assert!(
            current
                .screen
                .windows(14)
                .any(|bytes| bytes == b"current screen")
        );
        assert!(
            previous
                .history
                .windows(14)
                .any(|bytes| bytes == b"current screen")
        );
        assert!(
            !previous
                .history
                .windows(10)
                .any(|bytes| bytes == b"old screen")
        );
    }

    #[test]
    fn state_update_accepts_json_or_base64_json() {
        let json = r#"{"title":"build","cwd":"/repo","commandCount":3,"lastCommandAt":42,"runningCommand":"cargo test","commandHistory":["cargo test"]}"#;
        let direct = decode_state_update(json).expect("direct JSON should parse");
        let base64 = decode_state_update(&encoded(json)).expect("base64 JSON should parse");

        assert_eq!(direct.title.as_deref(), Some("build"));
        assert_eq!(base64.cwd.as_deref(), Some("/repo"));
        assert_eq!(base64.command_count, Some(3));
        assert_eq!(base64.last_command_at, Some(42.0));
        assert_eq!(base64.command_history, Some(vec!["cargo test".to_owned()]));
    }

    #[test]
    fn previous_session_metadata_decodes_without_command_recency() {
        let json = r#"{"sessionId":"session-1","title":"build","cwd":"/repo","createdAt":1,"commandCount":3,"runningCommand":null,"commandHistory":[],"attachedClientCount":0}"#;

        let metadata: SessionMetadata =
            serde_json::from_str(json).expect("previous metadata should decode");

        assert_eq!(metadata.last_command_at, None);
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
            allows_creation: true,
        };
        let metadata = SessionMetadata::new(&request);

        assert_eq!(metadata.session_id, "session-1");
        assert_eq!(metadata.title, "project");
        assert_eq!(metadata.cwd, "/tmp/project");
        assert_eq!(metadata.command_count, 0);
    }

    #[test]
    fn daemon_socket_ownership_prevents_unlink_race() {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("clock should be valid")
            .as_nanos();
        let directory = PathBuf::from("/tmp").join(format!(
            "portal-sessiond-ownership-{}-{unique}",
            std::process::id()
        ));
        fs::create_dir_all(&directory).expect("temporary directory should be created");
        let socket_path = directory.join("sessiond.sock");
        let (listener, ownership) =
            claim_daemon_socket(&socket_path, false).expect("first daemon should own socket");
        let original_inode = fs::metadata(&socket_path)
            .expect("owned socket should exist")
            .ino();

        let error = claim_daemon_socket(&socket_path, false)
            .expect_err("second daemon must not claim or unlink the socket");

        assert_eq!(error.kind(), io::ErrorKind::WouldBlock);
        assert_eq!(
            fs::metadata(&socket_path)
                .expect("first daemon socket should remain")
                .ino(),
            original_inode
        );
        UnixStream::connect(&socket_path).expect("first daemon socket should remain connectable");

        drop(listener);
        drop(ownership);
        fs::remove_dir_all(directory).expect("temporary directory should be removed");
    }

    #[test]
    fn daemon_socket_grace_preserves_adjacent_daemon_startup() {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("clock should be valid")
            .as_nanos();
        let directory = PathBuf::from("/tmp").join(format!(
            "portal-adjacent-daemon-{}-{unique}",
            std::process::id()
        ));
        fs::create_dir_all(&directory).expect("temporary directory should be created");
        let socket_path = directory.join("sessiond.sock");
        let mut adjacent_listener = None;
        let mut waits = 0;

        let error = claim_daemon_socket_with_wait(&socket_path, false, || {
            waits += 1;
            if waits == DAEMON_STARTUP_PROBES {
                adjacent_listener = Some(
                    UnixListener::bind(&socket_path)
                        .expect("adjacent daemon should bind after the final probe"),
                );
            }
        })
        .expect_err("current daemon must preserve adjacent daemon startup");

        assert_eq!(error.kind(), io::ErrorKind::AddrInUse);
        UnixStream::connect(&socket_path).expect("adjacent daemon should remain connectable");

        drop(adjacent_listener);
        fs::remove_dir_all(directory).expect("temporary directory should be removed");
    }

    #[test]
    fn daemon_socket_reclaims_unresponsive_existing_path() {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("clock should be valid")
            .as_nanos();
        let directory = PathBuf::from("/tmp").join(format!(
            "portal-stale-daemon-{}-{unique}",
            std::process::id()
        ));
        fs::create_dir_all(&directory).expect("temporary directory should be created");
        let socket_path = directory.join("sessiond.sock");
        let stale_listener =
            UnixListener::bind(&socket_path).expect("stale socket should be created");
        drop(stale_listener);
        let original_inode = fs::metadata(&socket_path)
            .expect("stale socket should remain")
            .ino();

        let (listener, ownership) = claim_daemon_socket_with_wait(&socket_path, false, || {})
            .expect("stale socket should be replaced");

        assert_ne!(
            fs::metadata(&socket_path)
                .expect("replacement socket should exist")
                .ino(),
            original_inode
        );
        UnixStream::connect(&socket_path).expect("replacement socket should be connectable");

        drop(listener);
        drop(ownership);
        fs::remove_dir_all(directory).expect("temporary directory should be removed");
    }

    #[test]
    fn explicit_socket_replacement_keeps_existing_connections_alive() {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("clock should be valid")
            .as_nanos();
        let directory = PathBuf::from("/tmp").join(format!(
            "portal-live-daemon-{}-{unique}",
            std::process::id()
        ));
        fs::create_dir_all(&directory).expect("temporary directory should be created");
        let socket_path = directory.join("sessiond.sock");
        let old_listener = UnixListener::bind(&socket_path).expect("old daemon should bind");
        let mut old_client = UnixStream::connect(&socket_path).expect("old client should connect");
        let (mut old_server, _) = old_listener.accept().expect("old daemon should accept");
        let old_inode = fs::metadata(&socket_path)
            .expect("old socket should exist")
            .ino();

        let (new_listener, ownership) = claim_daemon_socket(&socket_path, true)
            .expect("explicit replacement should publish a new listener");
        assert_ne!(
            fs::metadata(&socket_path)
                .expect("new socket should exist")
                .ino(),
            old_inode
        );
        let _new_client = UnixStream::connect(&socket_path).expect("new client should connect");
        let (_new_server, _) = new_listener.accept().expect("new daemon should accept");

        old_client
            .write_all(b"x")
            .expect("old connection should remain writable");
        let mut byte = [0_u8; 1];
        use std::io::Read;
        old_server
            .read_exact(&mut byte)
            .expect("old connection should remain readable");
        assert_eq!(byte, *b"x");

        drop(ownership);
        drop(old_listener);
        fs::remove_dir_all(directory).expect("temporary directory should be removed");
    }

    #[test]
    fn killing_session_returns_without_waiting_for_pty_reader() {
        let request = AttachRequest {
            session_id: "kill-test".to_owned(),
            cwd: env::temp_dir(),
            shell: "/bin/sh".to_owned(),
            environment: Vec::new(),
            protocol_version: CURRENT_PROTOCOL_VERSION,
            client_role: ClientRole::Mac,
            allows_creation: true,
        };
        let state = Arc::new(DaemonState {
            sessions: Mutex::new(HashMap::new()),
        });
        let session =
            Session::new(&request, Arc::downgrade(&state)).expect("test session should start");
        let (finished_tx, finished_rx) = mpsc::channel();

        thread::spawn(move || {
            session.kill();
            let _ = finished_tx.send(());
        });

        assert!(
            finished_rx.recv_timeout(Duration::from_secs(1)).is_ok(),
            "kill must not block on a PTY read owned by another thread"
        );
    }

    #[test]
    fn human_shell_does_not_inherit_agent_identity() {
        let request = AttachRequest {
            session_id: "human-shell-test".to_owned(),
            cwd: env::temp_dir(),
            shell: "/bin/sh".to_owned(),
            environment: vec![(
                "CODEX_INTERNAL_ORIGINATOR_OVERRIDE".to_owned(),
                "Codex Desktop".to_owned(),
            )],
            protocol_version: CURRENT_PROTOCOL_VERSION,
            client_role: ClientRole::Mac,
            allows_creation: true,
        };
        let state = Arc::new(DaemonState {
            sessions: Mutex::new(HashMap::new()),
        });
        let session = Session::new(&request, Arc::downgrade(&state)).unwrap();
        // Match Stripe's login decision: a real stdin TTY and no inherited agent identity.
        session.write_input(b"test -t 0 && test -z \"$CODEX_CI$CODEX_THREAD_ID$CODEX_INTERNAL_ORIGINATOR_OVERRIDE\" && printf '__HUMAN_%s__' terminal; exit\n");
        assert!(
            wait_for_history(&session, b"__HUMAN_terminal__", 1),
            "human terminal was classified as an AI agent or had no stdin TTY"
        );
    }

    #[test]
    fn child_exec_applies_prepared_cwd_and_environment() {
        let cwd = fs::canonicalize(env::temp_dir()).expect("temporary directory should resolve");
        let request = AttachRequest {
            session_id: "child-launch-test".to_owned(),
            cwd: cwd.clone(),
            shell: "/bin/sh".to_owned(),
            environment: vec![("PORTAL_CHILD_TEST".to_owned(), "ready".to_owned())],
            protocol_version: CURRENT_PROTOCOL_VERSION,
            client_role: ClientRole::Mac,
            allows_creation: true,
        };
        let state = Arc::new(DaemonState {
            sessions: Mutex::new(HashMap::new()),
        });
        let session =
            Session::new(&request, Arc::downgrade(&state)).expect("test session should start");
        session.write_input(
            b"printf '__PORTAL_CHILD__%s:%s\\n' \"$PORTAL_CHILD_TEST\" \"$PWD\"; exit\n",
        );

        let expected = format!("__PORTAL_CHILD__ready:{}", cwd.display());
        assert!(
            wait_for_history(&session, expected.as_bytes(), 1),
            "child did not inherit the prepared cwd and environment"
        );
    }

    #[test]
    fn interrupt_reaches_raw_mode_programs_as_ctrl_c_input() {
        let request = AttachRequest {
            session_id: "interrupt-test".to_owned(),
            cwd: env::temp_dir(),
            shell: "/bin/zsh".to_owned(),
            environment: Vec::new(),
            protocol_version: CURRENT_PROTOCOL_VERSION,
            client_role: ClientRole::Mac,
            allows_creation: true,
        };
        let state = Arc::new(DaemonState {
            sessions: Mutex::new(HashMap::new()),
        });
        let session =
            Session::new(&request, Arc::downgrade(&state)).expect("test session should start");
        session.write_input(b"unsetopt zle; stty -echo; printf '__PORTAL_SETUP__\\n'\n");
        let setup_complete = wait_for_history(&session, b"__PORTAL_SETUP__", 2);
        if setup_complete {
            session.write_input(
                b"/usr/bin/perl -e '$SIG{INT}=sub {}; system q(stty raw -echo); print qq(__PORTAL_RAW_READY__\\n); while (!defined sysread(STDIN, $c, 1)) { next if $!{EINTR}; die $! } print qq(__PORTAL_CTRL_C_RECEIVED__\\n)'\n",
            );
        }
        let ready = setup_complete && wait_for_history(&session, b"__PORTAL_RAW_READY__", 1);
        if ready {
            session.interrupt();
        }
        let received_ctrl_c = ready && wait_for_history(&session, b"__PORTAL_CTRL_C_RECEIVED__", 1);
        session.kill();

        assert!(setup_complete, "test shell did not finish setup");
        assert!(ready, "raw-mode test program did not start");
        assert!(received_ctrl_c, "Ctrl-C was not delivered through the PTY");
    }

    #[test]
    fn interrupt_stops_a_retry_loop() {
        let request = AttachRequest {
            session_id: "interrupt-loop-test".to_owned(),
            cwd: env::temp_dir(),
            shell: "/bin/zsh".to_owned(),
            environment: Vec::new(),
            protocol_version: CURRENT_PROTOCOL_VERSION,
            client_role: ClientRole::Mac,
            allows_creation: true,
        };
        let state = Arc::new(DaemonState {
            sessions: Mutex::new(HashMap::new()),
        });
        let session =
            Session::new(&request, Arc::downgrade(&state)).expect("test session should start");
        session.write_input(b"unsetopt zle; stty -echo; printf '__PORTAL_SETUP__\\n'\n");
        let setup_complete = wait_for_history(&session, b"__PORTAL_SETUP__", 2);
        if setup_complete {
            session.write_input(
                b"printf '\\033]133;C;retry-loop\\a'; until /usr/bin/perl -e '$SIG{INT}=sub { select undef,undef,undef,0.2; exit 1 }; print qq(__PORTAL_LOOP_READY__\\n); sleep 30'; do :; done; printf '\\033]133;D;0\\a'\n",
            );
        }
        let ready = setup_complete && wait_for_history(&session, b"__PORTAL_LOOP_READY__", 1);
        if ready {
            session.interrupt();
        }
        thread::sleep(Duration::from_millis(500));
        let stopped = ready && shell_is_foreground(&session);
        session.kill();

        assert!(setup_complete, "test shell did not finish setup");
        assert!(ready, "retry loop did not start");
        assert!(stopped, "Ctrl-C did not stop the retry loop");
    }

    #[test]
    fn interrupt_reports_completion_after_shell_discards_wrapper_tail() {
        let request = AttachRequest {
            session_id: "interrupt-completion-test".to_owned(),
            cwd: env::temp_dir(),
            shell: "/bin/zsh".to_owned(),
            environment: Vec::new(),
            protocol_version: CURRENT_PROTOCOL_VERSION,
            client_role: ClientRole::Mac,
            allows_creation: true,
        };
        let state = Arc::new(DaemonState {
            sessions: Mutex::new(HashMap::new()),
        });
        let session =
            Session::new(&request, Arc::downgrade(&state)).expect("test session should start");
        let (client, events) = mpsc::channel();
        session.attach_client(client, INITIAL_HISTORY_LINES);
        session.write_input(b"unsetopt zle; stty -echo; printf '__PORTAL_SETUP__\\n'\n");
        let setup_complete = wait_for_history(&session, b"__PORTAL_SETUP__", 2);
        if setup_complete {
            session.write_input(
                b"printf '\\033]133;C;test\\a'; /usr/bin/perl -e '$SIG{INT}=sub { select undef,undef,undef,3; $SIG{INT}=q(DEFAULT); kill q(INT),$$ }; print qq(__PORTAL_DELAY_READY__\\n); sleep 30'; printf '\\033]133;D;0\\a'\n",
            );
        }
        let command_started =
            setup_complete && wait_for_history(&session, COMMAND_STARTED_MARKER, 1);
        let child_ready =
            command_started && wait_for_history(&session, b"__PORTAL_DELAY_READY__", 1);
        if child_ready {
            session.interrupt();
        }
        let completion_reported = child_ready
            && loop {
                match events.recv_timeout(Duration::from_secs(5)) {
                    Ok(SessionEvent::Output { bytes, .. })
                        if bytes == INTERRUPTED_COMMAND_FINISHED_MARKER =>
                    {
                        break true;
                    }
                    Ok(_) => continue,
                    Err(_) => break false,
                }
            };
        session.kill();

        assert!(setup_complete, "test shell did not finish setup");
        assert!(command_started, "test command did not start");
        assert!(child_ready, "delayed interrupt test program did not start");
        assert!(
            completion_reported,
            "shell became idle without reporting the interrupted command's completion"
        );
    }

    #[test]
    fn idle_reconciliation_notifies_attached_clients() {
        let request = AttachRequest {
            session_id: "idle-reconciliation-test".to_owned(),
            cwd: env::temp_dir(),
            shell: "/bin/zsh".to_owned(),
            environment: Vec::new(),
            protocol_version: CURRENT_PROTOCOL_VERSION,
            client_role: ClientRole::Mac,
            allows_creation: true,
        };
        let state = Arc::new(DaemonState {
            sessions: Mutex::new(HashMap::new()),
        });
        let session =
            Session::new(&request, Arc::downgrade(&state)).expect("test session should start");
        let (client, events) = mpsc::channel();
        session.attach_client(client, INITIAL_HISTORY_LINES);
        let shell_ready = (0..200).any(|_| {
            let ready = shell_is_foreground(&session);
            if !ready {
                thread::sleep(Duration::from_millis(10));
            }
            ready
        });
        if shell_ready {
            session
                .terminal
                .lock()
                .expect("terminal lock poisoned")
                .record(b"\x1b]133;C;test\x07".to_vec());
            _ = session.metadata_snapshot();
        }
        let completion_reported = shell_ready
            && loop {
                match events.recv_timeout(Duration::from_secs(2)) {
                    Ok(SessionEvent::Output { bytes, .. })
                        if bytes == SYNTHETIC_COMMAND_FINISHED_MARKER =>
                    {
                        break true;
                    }
                    Ok(_) => continue,
                    Err(_) => break false,
                }
            };
        session.kill();

        assert!(shell_ready, "test shell did not become idle");
        assert!(
            completion_reported,
            "idle reconciliation did not notify the attached client"
        );
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
            allows_creation: true,
        };
        let session = Session {
            session_id: request.session_id.clone(),
            master_fd: -1,
            child_pid: 0,
            exited: AtomicBool::new(false),
            interrupt_reconciliation_running: AtomicBool::new(false),
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
