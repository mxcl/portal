use std::collections::{HashMap, HashSet};
use std::env;
use std::ffi::OsString;
use std::fs;
use std::io::{self, BufRead, BufReader, Read, Write};
use std::net::Shutdown;
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::thread;
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};

const VERSION: &str = env!("CARGO_PKG_VERSION");

fn main() -> io::Result<()> {
    let mut args = env::args().skip(1);
    match args.next().as_deref() {
        Some("--version") | Some("version") => {
            println!("portal-session-bridge {VERSION}");
            Ok(())
        }
        Some("--socket-path") => {
            println!("{}", socket_path()?.display());
            Ok(())
        }
        Some("--capabilities") => {
            println!("completion-v1");
            println!("git-status-v1");
            println!("{}", session_protocol_capability()?);
            Ok(())
        }
        Some("complete-path") => complete_path_stdio(),
        Some("complete-commands") => complete_commands_stdio(),
        Some("run-generator") => run_generator_stdio(),
        Some("git-status") => git_status_stdio(),
        Some(arg) => {
            eprintln!(
                "usage: portal-session-bridge [--version|--socket-path|--capabilities|complete-path|complete-commands|run-generator|git-status]"
            );
            eprintln!("unexpected argument: {arg}");
            std::process::exit(64);
        }
        None => run_bridge(),
    }
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct PathCompletionRequest {
    cwd: String,
    prefix: String,
    folders_only: bool,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct CommandCompletionRequest {
    prefix: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct GeneratorRequest {
    command_line: String,
    cwd: String,
    environment: Option<Vec<EnvironmentPair>>,
    timeout_ms: Option<u64>,
    output_limit: Option<usize>,
}

#[derive(Debug, Deserialize)]
struct EnvironmentPair {
    key: String,
    value: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct CompletionResponse {
    suggestions: Vec<CompletionSuggestion>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct CompletionSuggestion {
    display_text: String,
    insert_text: String,
    description: Option<String>,
    kind: &'static str,
    priority: i32,
    source: String,
    is_executable: bool,
}

#[derive(Debug, Serialize)]
struct GeneratorOutput {
    stdout: String,
    stderr: String,
    status: i32,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct GitStatusRequest {
    cwd: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct GitStatusResponse {
    summary: Option<GitStatusSummary>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct GitStatusSummary {
    worktree_path: String,
    branch: String,
    is_dirty: bool,
    insertions: i32,
    deletions: i32,
}

fn complete_path_stdio() -> io::Result<()> {
    let request: PathCompletionRequest = read_json_stdin()?;
    write_json_stdout(&CompletionResponse {
        suggestions: complete_path(&request)?,
    })
}

fn complete_commands_stdio() -> io::Result<()> {
    let request: CommandCompletionRequest = read_json_stdin()?;
    write_json_stdout(&CompletionResponse {
        suggestions: complete_commands_from_path(completion_path(), &request.prefix),
    })
}

fn run_generator_stdio() -> io::Result<()> {
    let request: GeneratorRequest = read_json_stdin()?;
    write_json_stdout(&run_generator(&request))
}

fn git_status_stdio() -> io::Result<()> {
    let request: GitStatusRequest = read_json_stdin()?;
    write_json_stdout(&git_status(&request))
}

fn read_json_stdin<T: for<'de> Deserialize<'de>>() -> io::Result<T> {
    let mut input = Vec::new();
    io::stdin().lock().read_to_end(&mut input)?;
    serde_json::from_slice(&input).map_err(invalid_input)
}

fn write_json_stdout<T: Serialize>(value: &T) -> io::Result<()> {
    let mut stdout = io::stdout().lock();
    serde_json::to_writer(&mut stdout, value).map_err(io::Error::other)?;
    stdout.write_all(b"\n")?;
    stdout.flush()
}

fn complete_path(request: &PathCompletionRequest) -> io::Result<Vec<CompletionSuggestion>> {
    if is_remote_path_prefix(&request.prefix) {
        return Ok(Vec::new());
    }

    let expanded = expand_tilde(&request.prefix);
    let (directory, file_prefix) = path_search_parts(&expanded, &request.cwd);
    let mut suggestions = Vec::new();

    for entry in fs::read_dir(&directory)? {
        let entry = entry?;
        let name = entry.file_name().to_string_lossy().into_owned();
        if name == "." || name == ".." {
            continue;
        }
        if !file_prefix.starts_with('.') && name.starts_with('.') {
            continue;
        }
        if !file_prefix.is_empty() && !has_case_insensitive_prefix(&name, &file_prefix) {
            continue;
        }

        let metadata = match entry.metadata() {
            Ok(metadata) => metadata,
            Err(_) => continue,
        };
        let is_directory = metadata.is_dir();
        if request.folders_only && !is_directory {
            continue;
        }

        let visible_name = if is_directory {
            format!("{name}/")
        } else {
            name.clone()
        };
        suggestions.push(CompletionSuggestion {
            display_text: visible_name.clone(),
            insert_text: path_insert_value(&request.prefix, &visible_name, is_directory),
            description: None,
            kind: if is_directory { "folder" } else { "file" },
            priority: if is_directory { 60 } else { 55 },
            source: directory.to_string_lossy().into_owned(),
            is_executable: is_directory || metadata.permissions().mode() & 0o111 != 0,
        });
        if suggestions.len() >= 512 {
            break;
        }
    }

    Ok(suggestions)
}

fn complete_commands_from_path(path: Option<OsString>, prefix: &str) -> Vec<CompletionSuggestion> {
    let mut sources = HashMap::new();
    let Some(path) = path else {
        return Vec::new();
    };

    for directory in env::split_paths(&path) {
        let Ok(entries) = fs::read_dir(&directory) else {
            continue;
        };
        for entry in entries.flatten() {
            let name = entry.file_name().to_string_lossy().into_owned();
            if !prefix.is_empty() && !has_case_insensitive_prefix(&name, prefix) {
                continue;
            }
            let path = entry.path();
            if is_executable(&path) {
                sources
                    .entry(name)
                    .or_insert_with(|| path.to_string_lossy().into_owned());
            }
        }
    }

    sources
        .into_iter()
        .map(|(name, source)| CompletionSuggestion {
            display_text: name.clone(),
            insert_text: format!("{name} "),
            description: None,
            kind: "command",
            priority: 50,
            source,
            is_executable: true,
        })
        .collect()
}

fn run_generator(request: &GeneratorRequest) -> GeneratorOutput {
    let timeout = Duration::from_millis(request.timeout_ms.unwrap_or(10_000).clamp(1, 15_000));
    let output_limit = request
        .output_limit
        .unwrap_or(64 * 1024)
        .clamp(1, 128 * 1024);
    let shell = env::var("SHELL").unwrap_or_else(|_| "/bin/sh".to_owned());
    let command_line = shell_command_line_for(&shell, &request.command_line);

    let mut command = Command::new(shell);
    command
        .arg("-lc")
        .arg(command_line)
        .current_dir(&request.cwd)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    if let Some(path) = completion_path() {
        command.env("PATH", path);
    }
    if let Some(environment) = &request.environment {
        for pair in environment {
            if should_forward_environment_key(&pair.key) {
                command.env(&pair.key, &pair.value);
            }
        }
    }

    let mut child = match command.spawn() {
        Ok(child) => child,
        Err(error) => {
            return GeneratorOutput {
                stdout: String::new(),
                stderr: error.to_string(),
                status: 1,
            };
        }
    };

    let stdout = child.stdout.take();
    let stderr = child.stderr.take();
    let stdout_thread = thread::spawn(move || read_limited(stdout, output_limit));
    let stderr_thread = thread::spawn(move || read_limited(stderr, output_limit));
    let deadline = Instant::now() + timeout;
    let mut timed_out = false;
    let status = loop {
        match child.try_wait() {
            Ok(Some(status)) => break status.code().unwrap_or(1),
            Ok(None) if Instant::now() < deadline => thread::sleep(Duration::from_millis(10)),
            Ok(None) => {
                timed_out = true;
                let _ = child.kill();
                let _ = child.wait();
                break 124;
            }
            Err(error) => {
                return GeneratorOutput {
                    stdout: String::new(),
                    stderr: error.to_string(),
                    status: 1,
                };
            }
        }
    };

    let stdout = stdout_thread.join().unwrap_or_default();
    let mut stderr = stderr_thread.join().unwrap_or_default();
    if timed_out {
        if !stderr.is_empty() {
            stderr.push('\n');
        }
        stderr.push_str("portal-session-bridge: generator timed out");
    }

    GeneratorOutput {
        stdout,
        stderr,
        status,
    }
}

fn git_status(request: &GitStatusRequest) -> GitStatusResponse {
    let Some(worktree_path) = git_stdout(&request.cwd, &["rev-parse", "--show-toplevel"]) else {
        return GitStatusResponse { summary: None };
    };
    let worktree_path = worktree_path.trim();
    let Some(status_output) = git_stdout(
        worktree_path,
        &[
            "--no-optional-locks",
            "status",
            "--porcelain=v1",
            "--branch",
            "--untracked-files=normal",
        ],
    ) else {
        return GitStatusResponse { summary: None };
    };
    let Some((branch, is_dirty)) = parse_git_status(&status_output) else {
        return GitStatusResponse { summary: None };
    };
    let (insertions, deletions) = if is_dirty {
        git_stdout(
            worktree_path,
            &["--no-optional-locks", "diff", "--numstat", "HEAD", "--"],
        )
        .map(|output| parse_numstat(&output))
        .unwrap_or((0, 0))
    } else {
        (0, 0)
    };

    GitStatusResponse {
        summary: Some(GitStatusSummary {
            worktree_path: worktree_path.to_owned(),
            branch,
            is_dirty,
            insertions,
            deletions,
        }),
    }
}

fn git_stdout(cwd: &str, arguments: &[&str]) -> Option<String> {
    let output = Command::new("git")
        .arg("-C")
        .arg(cwd)
        .args(arguments)
        .env("GIT_TERMINAL_PROMPT", "0")
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    Some(String::from_utf8_lossy(&output.stdout).into_owned())
}

fn parse_git_status(output: &str) -> Option<(String, bool)> {
    let mut branch = None;
    let mut is_dirty = false;
    for line in output.lines() {
        if let Some(rest) = line.strip_prefix("## ") {
            branch = branch_name_from_status(rest);
            continue;
        }
        let mut chars = line.chars();
        let index_status = chars.next().unwrap_or(' ');
        let worktree_status = chars.next().unwrap_or(' ');
        is_dirty = is_dirty || index_status != ' ' || worktree_status != ' ';
    }
    branch.map(|branch| (branch, is_dirty))
}

fn branch_name_from_status(value: &str) -> Option<String> {
    let mut value = value.to_owned();
    if let Some(index) = value.find(" [") {
        value.truncate(index);
    }
    if let Some(index) = value.find("...") {
        value.truncate(index);
    }
    if let Some(rest) = value.strip_prefix("Initial commit on ") {
        value = rest.to_owned();
    }
    if let Some(rest) = value.strip_prefix("No commits yet on ") {
        value = rest.to_owned();
    }
    if value == "HEAD (no branch)" {
        value = "HEAD".to_owned();
    }
    let value = value.trim();
    (!value.is_empty()).then(|| value.to_owned())
}

fn parse_numstat(output: &str) -> (i32, i32) {
    let mut insertions = 0;
    let mut deletions = 0;
    for line in output.lines() {
        let mut fields = line.splitn(3, '\t');
        if let Some(value) = fields.next().and_then(|value| value.parse::<i32>().ok()) {
            insertions += value;
        }
        if let Some(value) = fields.next().and_then(|value| value.parse::<i32>().ok()) {
            deletions += value;
        }
    }
    (insertions, deletions)
}

fn path_search_parts(expanded: &str, cwd: &str) -> (PathBuf, String) {
    if expanded.ends_with('/') {
        let directory = if expanded.starts_with('/') {
            PathBuf::from(expanded)
        } else {
            Path::new(cwd).join(expanded)
        };
        return (directory, String::new());
    }

    let (directory_part, file_prefix) = match expanded.rsplit_once('/') {
        Some(("", file_prefix)) => ("/", file_prefix),
        Some((directory_part, file_prefix)) => (directory_part, file_prefix),
        None => ("", expanded),
    };
    if directory_part.is_empty() || directory_part == "." {
        (PathBuf::from(cwd), file_prefix.to_owned())
    } else if directory_part.starts_with('/') {
        (PathBuf::from(directory_part), file_prefix.to_owned())
    } else {
        (Path::new(cwd).join(directory_part), file_prefix.to_owned())
    }
}

fn expand_tilde(prefix: &str) -> String {
    if prefix == "~" {
        env::var("HOME").unwrap_or_else(|_| prefix.to_owned())
    } else if let Some(rest) = prefix.strip_prefix("~/") {
        match env::var("HOME") {
            Ok(home) => format!("{home}/{rest}"),
            Err(_) => prefix.to_owned(),
        }
    } else {
        prefix.to_owned()
    }
}

fn path_insert_value(prefix: &str, suggestion_name: &str, is_directory: bool) -> String {
    let base_prefix = if prefix.ends_with('/') {
        prefix.to_owned()
    } else {
        let path = Path::new(prefix);
        let directory_name = path
            .parent()
            .map(|parent| parent.to_string_lossy().into_owned())
            .unwrap_or_default();
        if directory_name.is_empty() {
            String::new()
        } else if directory_name == "/" {
            "/".to_owned()
        } else if directory_name == "." {
            if prefix.starts_with("./") {
                "./".to_owned()
            } else {
                String::new()
            }
        } else {
            format!("{directory_name}/")
        }
    };
    let raw = format!("{base_prefix}{suggestion_name}");
    format!(
        "{}{}",
        shell_escape_path(&raw),
        if is_directory { "" } else { " " }
    )
}

fn shell_escape_path(path: &str) -> String {
    if path
        .chars()
        .all(|character| character.is_ascii_alphanumeric() || "-_./~".contains(character))
    {
        return path.to_owned();
    }
    let mut escaped = String::new();
    for character in path.chars() {
        if character == '\'' {
            escaped.push_str("'\\''");
        } else {
            escaped.push(character);
        }
    }
    format!("'{escaped}'")
}

fn shell_command_line_for(shell: &str, command_line: &str) -> String {
    if Path::new(shell).file_name().and_then(|name| name.to_str()) == Some("zsh") {
        return command_line.to_owned();
    }
    if let Some(rest) = command_line.strip_prefix("noglob ") {
        format!("set -f; {rest}")
    } else {
        command_line.to_owned()
    }
}

fn completion_path() -> Option<OsString> {
    let mut paths = Vec::new();
    append_split_paths(&mut paths, path_from_user_shell());
    append_split_paths(&mut paths, env::var_os("PATH"));
    if let Some(home) = env::var_os("HOME").map(PathBuf::from) {
        paths.push(home.join(".local").join("bin"));
        paths.push(home.join(".cargo").join("bin"));
    }
    paths.push(PathBuf::from("/opt/homebrew/bin"));
    paths.push(PathBuf::from("/usr/local/bin"));

    let mut seen = HashSet::new();
    paths.retain(|path| seen.insert(path.clone()));
    env::join_paths(paths).ok()
}

fn append_split_paths(paths: &mut Vec<PathBuf>, path: Option<OsString>) {
    if let Some(path) = path {
        paths.extend(env::split_paths(&path));
    }
}

fn path_from_user_shell() -> Option<OsString> {
    let shell = env::var_os("SHELL")?;
    let shell_path = PathBuf::from(&shell);
    let shell_name = shell_path.file_name().and_then(|name| name.to_str());
    let shell_flag = match shell_name {
        Some("bash" | "zsh") => "-lic",
        _ => "-lc",
    };
    let output = Command::new(&shell)
        .arg(shell_flag)
        .arg("printf '%s' \"$PATH\"")
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let path = String::from_utf8_lossy(&output.stdout).trim().to_owned();
    if path.is_empty() {
        None
    } else {
        Some(OsString::from(path))
    }
}

fn should_forward_environment_key(key: &str) -> bool {
    !matches!(key, "PATH" | "SHELL" | "HOME" | "USER" | "LOGNAME" | "PWD")
}

fn read_limited(pipe: Option<impl Read>, limit: usize) -> String {
    let Some(mut pipe) = pipe else {
        return String::new();
    };
    let mut output = Vec::new();
    let mut buffer = [0; 8192];
    loop {
        let Ok(count) = pipe.read(&mut buffer) else {
            break;
        };
        if count == 0 {
            break;
        }
        let remaining = limit.saturating_sub(output.len());
        if remaining > 0 {
            output.extend_from_slice(&buffer[..count.min(remaining)]);
        }
    }
    String::from_utf8_lossy(&output).into_owned()
}

fn has_case_insensitive_prefix(value: &str, prefix: &str) -> bool {
    value
        .get(..prefix.len())
        .map(|head| head.eq_ignore_ascii_case(prefix))
        .unwrap_or(false)
}

fn is_remote_path_prefix(prefix: &str) -> bool {
    prefix.contains(':') && !prefix.starts_with("./") && !prefix.starts_with("../")
}

fn invalid_input(error: serde_json::Error) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidInput, error)
}

fn run_bridge() -> io::Result<()> {
    ensure_daemon_is_running()?;
    let stream = connect_to_daemon()?;
    proxy_stdio(stream)
}

fn proxy_stdio(stream: UnixStream) -> io::Result<()> {
    let mut input_stream = stream.try_clone()?;
    let output_stream = stream;

    let input_thread = thread::spawn(move || {
        let mut stdin = io::stdin().lock();
        let result = io::copy(&mut stdin, &mut input_stream);
        let _ = input_stream.shutdown(Shutdown::Write);
        result.map(|_| ())
    });

    let output_thread = thread::spawn(move || {
        let mut output_stream = output_stream;
        let mut stdout = io::stdout().lock();
        let result = io::copy(&mut output_stream, &mut stdout);
        let _ = stdout.flush();
        result.map(|_| ())
    });

    let input_result = join_io_thread(input_thread);
    let output_result = join_io_thread(output_thread);
    tolerate_broken_pipe(input_result)?;
    output_result
}

fn join_io_thread(thread: thread::JoinHandle<io::Result<()>>) -> io::Result<()> {
    match thread.join() {
        Ok(result) => result,
        Err(_) => Err(io::Error::other("bridge proxy thread panicked")),
    }
}

fn tolerate_broken_pipe(result: io::Result<()>) -> io::Result<()> {
    match result {
        Err(error) if error.kind() == io::ErrorKind::BrokenPipe => Ok(()),
        result => result,
    }
}

fn ensure_daemon_is_running() -> io::Result<()> {
    let socket_path = socket_path()?;
    match daemon_inventory_is_empty() {
        Ok(_) => return Ok(()),
        Err(error) if connect_to_daemon().is_ok() => return Err(error),
        Err(_) => {}
    }

    let daemon = sessiond_path()?;
    if let Some(parent) = socket_path.parent() {
        fs::create_dir_all(parent)?;
        fs::set_permissions(parent, fs::Permissions::from_mode(0o700))?;
    }
    let _ = fs::remove_file(&socket_path);

    Command::new(daemon)
        .arg("serve")
        .env("VAULTTY_SESSIOND_SOCKET", &socket_path)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()?;

    let deadline = Instant::now() + Duration::from_secs(2);
    let mut last_error = None;
    while Instant::now() < deadline {
        match daemon_inventory_is_empty() {
            Ok(_) => {
                return Ok(());
            }
            Err(error) => {
                last_error = Some(error);
                thread::sleep(Duration::from_millis(50));
            }
        }
    }

    Err(last_error.unwrap_or_else(|| io::Error::other("could not connect to portal-sessiond")))
}

fn daemon_inventory_is_empty() -> io::Result<bool> {
    let mut stream = connect_to_daemon()?;
    let _ = stream.set_read_timeout(Some(Duration::from_millis(500)));
    let _ = stream.set_write_timeout(Some(Duration::from_millis(500)));
    stream.write_all(b"LIST\n")?;
    stream.flush()?;

    let mut reader = BufReader::new(stream);
    let mut line = String::new();
    let count = reader.read_line(&mut line)?;
    if count > 0 && line.starts_with("SESSIONS ") {
        return Ok(line.trim_end() == "SESSIONS W10=");
    }

    Err(daemon_inventory_error())
}

fn daemon_protocol_versions() -> io::Result<Vec<u16>> {
    let mut stream = connect_to_daemon()?;
    let _ = stream.set_read_timeout(Some(Duration::from_millis(500)));
    let _ = stream.set_write_timeout(Some(Duration::from_millis(500)));
    stream.write_all(b"PROTOCOLS\n")?;
    stream.flush()?;

    let mut line = String::new();
    BufReader::new(stream).read_line(&mut line)?;
    parse_supported_protocols(&line).ok_or_else(|| io::Error::other("legacy session daemon"))
}

fn session_protocol_capability() -> io::Result<String> {
    ensure_daemon_is_running()?;
    let versions = daemon_protocol_versions().unwrap_or_else(|_| vec![1]);
    Ok(format!(
        "session-wire={}",
        versions
            .iter()
            .map(u16::to_string)
            .collect::<Vec<_>>()
            .join(",")
    ))
}

fn parse_supported_protocols(line: &str) -> Option<Vec<u16>> {
    let versions = line
        .trim_end()
        .strip_prefix("PROTOCOLS ")?
        .split_whitespace()
        .map(str::parse)
        .collect::<Result<Vec<u16>, _>>()
        .ok()?;
    (!versions.is_empty()).then_some(versions)
}

fn daemon_inventory_error() -> io::Error {
    let base = "portal-sessiond accepted a connection but did not answer LIST";
    #[cfg(target_os = "macos")]
    if let Some(diagnostic) = bridge_signature_diagnostic() {
        return io::Error::new(
            io::ErrorKind::PermissionDenied,
            format!("{base}. {diagnostic}"),
        );
    }
    io::Error::other(base)
}

#[cfg(target_os = "macos")]
fn bridge_signature_diagnostic() -> Option<String> {
    let path = env::current_exe().ok()?;
    let output = Command::new("/usr/bin/codesign")
        .args(["-dv", "--verbose=4"])
        .arg(&path)
        .output()
        .ok()?;
    let text = String::from_utf8_lossy(&output.stderr);
    if !output.status.success()
        || text.contains("Signature=adhoc")
        || text.contains("TeamIdentifier=not set")
    {
        return Some(format!(
            "The remote bridge at {} is not Developer ID signed, so the daemon rejected it. Reinstall or re-enroll the signed Portal Terminal helpers on this host, then verify with: codesign -dv --verbose=4 {}",
            path.display(),
            path.display()
        ));
    }
    Some(format!(
        "This usually means the daemon rejected the bridge during peer validation. Verify the remote bridge and daemon are signed Portal Terminal helpers: codesign -dv --verbose=4 {}",
        path.display()
    ))
}

fn connect_to_daemon() -> io::Result<UnixStream> {
    UnixStream::connect(socket_path()?)
}

fn sessiond_path() -> io::Result<PathBuf> {
    if let Some(path) = env::var_os("VAULTTY_SESSIOND") {
        let path = PathBuf::from(path);
        if is_executable(&path) {
            return Ok(path);
        }
    }

    if let Ok(current_exe) = env::current_exe()
        && let Some(dir) = current_exe.parent()
    {
        let sibling = dir.join("vaultty-sessiond");
        if is_executable(&sibling) {
            return Ok(sibling);
        }
    }

    if let Some(path) = find_on_path("vaultty-sessiond") {
        return Ok(path);
    }

    Err(io::Error::new(
        io::ErrorKind::NotFound,
        "vaultty-sessiond was not found next to the bridge or on PATH",
    ))
}

fn find_on_path(name: &str) -> Option<PathBuf> {
    let paths = env::var_os("PATH")?;
    env::split_paths(&paths)
        .map(|dir| dir.join(name))
        .find(|path| is_executable(path))
}

fn is_executable(path: &Path) -> bool {
    fs::metadata(path)
        .map(|metadata| metadata.is_file() && metadata.permissions().mode() & 0o111 != 0)
        .unwrap_or(false)
}

fn socket_path() -> io::Result<PathBuf> {
    if let Some(path) = env::var_os("VAULTTY_SESSIOND_SOCKET") {
        return Ok(PathBuf::from(path));
    }

    let home = env::var_os("HOME").ok_or_else(|| {
        io::Error::new(io::ErrorKind::NotFound, "HOME is required for socket path")
    })?;
    let home = PathBuf::from(home);

    #[cfg(target_os = "macos")]
    {
        return Ok(home
            .join("Library")
            .join("Application Support")
            .join("Vaultty")
            .join("runtime")
            .join("sessiond.sock"));
    }

    #[cfg(not(target_os = "macos"))]
    {
        let state_home = env::var_os("XDG_STATE_HOME")
            .map(PathBuf::from)
            .unwrap_or_else(|| home.join(".local").join("state"));
        Ok(state_home.join("vaultty").join("sessiond.sock"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{SystemTime, UNIX_EPOCH};

    struct TempDir {
        path: PathBuf,
    }

    impl TempDir {
        fn new(name: &str) -> Self {
            let unique = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .expect("clock should be valid")
                .as_nanos();
            let path = env::temp_dir().join(format!(
                "portal-session-bridge-{name}-{}-{unique}",
                std::process::id()
            ));
            fs::create_dir_all(&path).expect("temp dir should be created");
            Self { path }
        }
    }

    impl Drop for TempDir {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.path);
        }
    }

    fn names(suggestions: &[CompletionSuggestion]) -> Vec<String> {
        let mut names = suggestions
            .iter()
            .map(|suggestion| suggestion.display_text.clone())
            .collect::<Vec<_>>();
        names.sort();
        names
    }

    #[test]
    fn session_protocol_capability_parses_daemon_versions() {
        assert_eq!(
            parse_supported_protocols("PROTOCOLS 1 2\n"),
            Some(vec![1, 2])
        );
        assert_eq!(parse_supported_protocols(""), None);
        assert_eq!(parse_supported_protocols("PROTOCOLS nope"), None);
    }

    fn git(temp: &TempDir, arguments: &[&str]) {
        let output = Command::new("git")
            .arg("-C")
            .arg(&temp.path)
            .args(arguments)
            .env("GIT_TERMINAL_PROMPT", "0")
            .output()
            .expect("git should run");
        assert!(
            output.status.success(),
            "git {:?} failed: {}",
            arguments,
            String::from_utf8_lossy(&output.stderr)
        );
    }

    fn init_git_repo(temp: &TempDir) {
        git(temp, &["init"]);
        git(temp, &["checkout", "-b", "vaultty-test"]);
        git(temp, &["config", "user.email", "vaultty@example.invalid"]);
        git(temp, &["config", "user.name", "Vaultty Test"]);
        fs::write(temp.path.join("tracked.txt"), b"one\n").expect("tracked file should be written");
        git(temp, &["add", "tracked.txt"]);
        git(temp, &["commit", "-m", "initial"]);
    }

    #[test]
    fn path_completion_handles_relative_prefixes_and_spaces() {
        let temp = TempDir::new("path-relative");
        fs::create_dir(temp.path.join("src")).expect("folder should be created");
        fs::write(temp.path.join("space file.txt"), b"ok").expect("file should be created");

        let suggestions = complete_path(&PathCompletionRequest {
            cwd: temp.path.to_string_lossy().into_owned(),
            prefix: "s".to_owned(),
            folders_only: false,
        })
        .expect("path completion should succeed");
        assert_eq!(names(&suggestions), vec!["space file.txt", "src/"]);
        let spaced = suggestions
            .iter()
            .find(|suggestion| suggestion.display_text == "space file.txt")
            .expect("spaced file should be suggested");
        assert_eq!(spaced.insert_text, "'space file.txt' ");
    }

    #[test]
    fn path_completion_keeps_absolute_root_prefix() {
        assert_eq!(path_insert_value("/op", "opt/", true), "/opt/");
    }

    #[test]
    fn path_completion_respects_folder_only_and_hidden_prefixes() {
        let temp = TempDir::new("path-filter");
        fs::create_dir(temp.path.join("alpha")).expect("folder should be created");
        fs::write(temp.path.join("atom"), b"ok").expect("file should be created");
        fs::write(temp.path.join(".secret"), b"ok").expect("hidden file should be created");

        let folders = complete_path(&PathCompletionRequest {
            cwd: temp.path.to_string_lossy().into_owned(),
            prefix: "a".to_owned(),
            folders_only: true,
        })
        .expect("path completion should succeed");
        assert_eq!(names(&folders), vec!["alpha/"]);

        let hidden = complete_path(&PathCompletionRequest {
            cwd: temp.path.to_string_lossy().into_owned(),
            prefix: ".".to_owned(),
            folders_only: false,
        })
        .expect("path completion should succeed");
        assert_eq!(names(&hidden), vec![".secret"]);
    }

    #[test]
    fn command_completion_scans_executables_from_path() {
        let temp = TempDir::new("commands");
        let executable = temp.path.join("vault-command");
        let non_executable = temp.path.join("vault-note");
        fs::write(&executable, b"#!/bin/sh\n").expect("executable should be created");
        fs::write(&non_executable, b"note").expect("file should be created");
        fs::set_permissions(&executable, fs::Permissions::from_mode(0o755))
            .expect("permissions should be updated");
        fs::set_permissions(&non_executable, fs::Permissions::from_mode(0o644))
            .expect("permissions should be updated");

        let suggestions =
            complete_commands_from_path(Some(OsString::from(temp.path.as_os_str())), "vault-");
        assert_eq!(names(&suggestions), vec!["vault-command"]);
    }

    #[test]
    fn git_status_returns_none_outside_repo() {
        let temp = TempDir::new("git-none");
        let response = git_status(&GitStatusRequest {
            cwd: temp.path.to_string_lossy().into_owned(),
        });
        assert!(response.summary.is_none());
    }

    #[test]
    fn git_status_reports_clean_repo() {
        let temp = TempDir::new("git-clean");
        init_git_repo(&temp);

        let response = git_status(&GitStatusRequest {
            cwd: temp.path.to_string_lossy().into_owned(),
        });
        let summary = response.summary.expect("git summary should exist");
        assert_eq!(summary.branch, "vaultty-test");
        assert!(!summary.is_dirty);
        assert_eq!(summary.insertions, 0);
        assert_eq!(summary.deletions, 0);
    }

    #[test]
    fn git_status_reports_dirty_line_counts() {
        let temp = TempDir::new("git-dirty");
        init_git_repo(&temp);
        fs::write(temp.path.join("tracked.txt"), b"one\ntwo\n")
            .expect("tracked file should be modified");

        let response = git_status(&GitStatusRequest {
            cwd: temp.path.to_string_lossy().into_owned(),
        });
        let summary = response.summary.expect("git summary should exist");
        assert_eq!(summary.branch, "vaultty-test");
        assert!(summary.is_dirty);
        assert_eq!(summary.insertions, 1);
        assert_eq!(summary.deletions, 0);
    }

    #[test]
    fn generator_runs_with_cwd_environment_and_output_limit() {
        let temp = TempDir::new("generator");
        let output = run_generator(&GeneratorRequest {
            command_line: "printf '%s:%s' \"$VAULTTY_TEST_VALUE\" \"$(pwd)\"".to_owned(),
            cwd: temp.path.to_string_lossy().into_owned(),
            environment: Some(vec![EnvironmentPair {
                key: "VAULTTY_TEST_VALUE".to_owned(),
                value: "remote".to_owned(),
            }]),
            timeout_ms: Some(2_000),
            output_limit: Some(8),
        });
        assert_eq!(output.status, 0);
        assert_eq!(output.stdout, "remote:/");
    }

    #[test]
    fn generator_times_out() {
        let temp = TempDir::new("generator-timeout");
        let output = run_generator(&GeneratorRequest {
            command_line: "sleep 2".to_owned(),
            cwd: temp.path.to_string_lossy().into_owned(),
            environment: None,
            timeout_ms: Some(20),
            output_limit: Some(1024),
        });
        assert_eq!(output.status, 124);
        assert!(output.stderr.contains("timed out"));
    }
}
