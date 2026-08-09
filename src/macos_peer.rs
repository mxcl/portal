use std::io;
use std::os::unix::net::UnixStream;

#[cfg(target_os = "macos")]
use core_foundation::base::TCFType;
#[cfg(target_os = "macos")]
use core_foundation::data::CFData;
#[cfg(target_os = "macos")]
use security_framework::os::macos::code_signing::{
    Flags, GuestAttributes, SecCode, SecRequirement,
};
#[cfg(target_os = "macos")]
use std::os::fd::AsRawFd;

#[cfg(target_os = "macos")]
const CLIENT_REQUIREMENT: &str = concat!(
    "anchor apple generic and ",
    "certificate 1[field.1.2.840.113635.100.6.2.6] exists and ",
    "certificate leaf[field.1.2.840.113635.100.6.1.13] exists and ",
    "certificate leaf[subject.OU] = \"ZU76A67LGU\" and ",
    "(identifier \"dev.mxcl.portal\" or ",
    "identifier \"dev.mxcl.portal.session-bridge\" or ",
    "identifier \"dev.mxcl.portal.remote-agent\" or ",
    "identifier \"com.automicvault.vaultty\" or ",
    "identifier \"com.automicvault.vaultty.session-bridge\" or ",
    "identifier \"com.automicvault.vaultty.remote-agent\")",
);

#[cfg(target_os = "macos")]
const SERVER_REQUIREMENT: &str = concat!(
    "anchor apple generic and ",
    "certificate 1[field.1.2.840.113635.100.6.2.6] exists and ",
    "certificate leaf[field.1.2.840.113635.100.6.1.13] exists and ",
    "certificate leaf[subject.OU] = \"ZU76A67LGU\" and ",
    "identifier \"dev.mxcl.portal.sessiond\"",
);

#[cfg(target_os = "macos")]
const PREVIOUS_SERVER_REQUIREMENT: &str = concat!(
    "anchor apple generic and ",
    "certificate 1[field.1.2.840.113635.100.6.2.6] exists and ",
    "certificate leaf[field.1.2.840.113635.100.6.1.13] exists and ",
    "certificate leaf[subject.OU] = \"ZU76A67LGU\" and ",
    "identifier \"com.automicvault.vaultty.sessiond\"",
);

#[allow(dead_code)]
pub fn validate_client(stream: &UnixStream) -> io::Result<()> {
    validate_same_user(stream)?;
    #[cfg(target_os = "macos")]
    validate_code(stream, &[CLIENT_REQUIREMENT])?;
    Ok(())
}

#[allow(dead_code)]
pub fn validate_server(stream: &UnixStream, allow_previous: bool) -> io::Result<()> {
    validate_same_user(stream)?;
    #[cfg(target_os = "macos")]
    if allow_previous {
        validate_code(stream, &[SERVER_REQUIREMENT, PREVIOUS_SERVER_REQUIREMENT])?;
    } else {
        validate_code(stream, &[SERVER_REQUIREMENT])?;
    }
    Ok(())
}

fn validate_same_user(stream: &UnixStream) -> io::Result<()> {
    #[cfg(feature = "test-peer-validation-bypass")]
    if std::env::var_os("PORTAL_SESSIOND_DISABLE_PEER_VALIDATION").is_some() {
        return Ok(());
    }

    #[cfg(target_os = "macos")]
    {
        use std::os::fd::AsRawFd;

        let mut uid: libc::uid_t = 0;
        let mut gid: libc::gid_t = 0;
        let rc = unsafe { libc::getpeereid(stream.as_raw_fd(), &mut uid, &mut gid) };
        if rc != 0 {
            return Err(io::Error::last_os_error());
        }
        if uid != unsafe { libc::geteuid() } {
            return Err(io::Error::new(
                io::ErrorKind::PermissionDenied,
                "peer uid does not match process uid",
            ));
        }
    }

    Ok(())
}

#[cfg(target_os = "macos")]
fn validate_code(stream: &UnixStream, requirements: &[&str]) -> io::Result<()> {
    #[cfg(feature = "test-peer-validation-bypass")]
    if std::env::var_os("PORTAL_SESSIOND_DISABLE_PEER_VALIDATION").is_some() {
        return Ok(());
    }

    let token = peer_audit_token(stream)?;
    let token_data = CFData::from_buffer(&token);
    let mut attributes = GuestAttributes::new();
    attributes.set_audit_token(token_data.as_concrete_TypeRef());
    let code = SecCode::copy_guest_with_attribues(None, &attributes, Flags::NONE)
        .map_err(|error| security_error("resolve peer code", error))?;

    for text in requirements {
        let requirement: SecRequirement = text
            .parse()
            .map_err(|error| security_error("parse peer requirement", error))?;
        if code.check_validity(Flags::NONE, &requirement).is_ok() {
            return Ok(());
        }
    }

    Err(io::Error::new(
        io::ErrorKind::PermissionDenied,
        "peer does not satisfy the Portal code-signing requirement",
    ))
}

#[cfg(target_os = "macos")]
fn peer_audit_token(stream: &UnixStream) -> io::Result<[u8; 32]> {
    let mut token = [0_u8; 32];
    let mut length = token.len() as libc::socklen_t;
    let rc = unsafe {
        libc::getsockopt(
            stream.as_raw_fd(),
            libc::SOL_LOCAL,
            libc::LOCAL_PEERTOKEN,
            token.as_mut_ptr().cast(),
            &mut length,
        )
    };
    if rc != 0 {
        return Err(io::Error::last_os_error());
    }
    if length as usize != token.len() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "peer returned an invalid audit token",
        ));
    }
    Ok(token)
}

#[cfg(target_os = "macos")]
fn security_error(operation: &str, error: security_framework::base::Error) -> io::Error {
    io::Error::new(
        io::ErrorKind::PermissionDenied,
        format!("{operation} failed: {error}"),
    )
}

#[cfg(all(test, target_os = "macos"))]
mod tests {
    use super::*;

    #[test]
    fn code_signing_requirements_parse() {
        for text in [
            CLIENT_REQUIREMENT,
            SERVER_REQUIREMENT,
            PREVIOUS_SERVER_REQUIREMENT,
        ] {
            text.parse::<SecRequirement>()
                .expect("Portal code-signing requirement should parse");
        }
    }
}
