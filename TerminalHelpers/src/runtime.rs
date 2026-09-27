use std::path::PathBuf;
use std::{env, io};

pub fn socket_path() -> io::Result<PathBuf> {
    if let Some(path) = env::var_os("GITINUUM_SESSIOND_SOCKET") {
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
            .join("Gitinuum/Terminal")
            .join("runtime")
            .join("sessiond.sock"));
    }

    #[cfg(not(target_os = "macos"))]
    {
        let state_home = env::var_os("XDG_STATE_HOME")
            .map(PathBuf::from)
            .unwrap_or_else(|| home.join(".local").join("state"));
        Ok(state_home.join("gitinuum-terminal").join("sessiond.sock"))
    }
}
