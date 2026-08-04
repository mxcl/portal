use axum::Router;
use axum::body::Bytes;
use axum::extract::ws::{Message, WebSocket, WebSocketUpgrade};
use axum::extract::{DefaultBodyLimit, Path, State};
use axum::http::{HeaderMap, HeaderValue, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::routing::{any, get, post};
use futures_util::{SinkExt, StreamExt};
use std::collections::HashMap;
use std::env;
use std::hash::{DefaultHasher, Hash, Hasher};
use std::path::{Path as FilePath, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime};
use tokio::sync::{Mutex as AsyncMutex, broadcast, mpsc};

const MAX_MESSAGE_BYTES: usize = 1024 * 1024;
const CATALOG_RETENTION: Duration = Duration::from_secs(30 * 24 * 60 * 60);

#[derive(Clone)]
struct RelayState {
    rooms: Arc<Mutex<HashMap<String, Room>>>,
    catalog_directory: Arc<PathBuf>,
    temporary_file_counter: Arc<AtomicU64>,
    catalog_write_lock: Arc<AsyncMutex<()>>,
}

struct Room {
    credential: String,
    sender: broadcast::Sender<RoomMessage>,
}

#[derive(Clone)]
struct RoomMessage {
    sender_id: String,
    bytes: Bytes,
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let bind_address = env::var("VAULTTY_RELAY_BIND").unwrap_or_else(|_| "127.0.0.1:8787".into());
    let catalog_directory = env::var_os("VAULTTY_RELAY_DATA_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/var/lib/vaultty-relay"));
    let state = RelayState::new(catalog_directory).await?;
    let app = router(state);
    let listener = tokio::net::TcpListener::bind(&bind_address).await?;
    eprintln!("Portal relay listening on {bind_address}");
    axum::serve(listener, app)
        .with_graceful_shutdown(shutdown_signal())
        .await?;
    Ok(())
}

fn router(state: RelayState) -> Router {
    Router::new()
        .route("/health", get(|| async { StatusCode::NO_CONTENT }))
        .route("/v1/connect/{room}/{peer}", any(connect))
        .route("/v1/send/{room}/{peer}", post(send))
        .route("/v1/catalog/{room}", get(get_catalog).put(put_catalog))
        .layer(DefaultBodyLimit::max(MAX_MESSAGE_BYTES))
        .with_state(state)
}

impl RelayState {
    async fn new(catalog_directory: PathBuf) -> std::io::Result<Self> {
        tokio::fs::create_dir_all(&catalog_directory).await?;
        Ok(Self {
            rooms: Arc::new(Mutex::new(HashMap::new())),
            catalog_directory: Arc::new(catalog_directory),
            temporary_file_counter: Arc::new(AtomicU64::new(0)),
            catalog_write_lock: Arc::new(AsyncMutex::new(())),
        })
    }

    fn authorize(
        &self,
        room_id: &str,
        headers: &HeaderMap,
    ) -> Result<broadcast::Sender<RoomMessage>, StatusCode> {
        if !valid_identifier(room_id) {
            return Err(StatusCode::BAD_REQUEST);
        }
        let credential = bearer_credential(headers).ok_or(StatusCode::UNAUTHORIZED)?;
        let mut rooms = self.rooms.lock().expect("rooms lock poisoned");
        let room = rooms.entry(room_id.to_owned()).or_insert_with(|| {
            let (sender, _) = broadcast::channel(1024);
            Room {
                credential: credential.to_owned(),
                sender,
            }
        });
        if room.credential != credential {
            return Err(StatusCode::UNAUTHORIZED);
        }
        Ok(room.sender.clone())
    }

    fn catalog_path(&self, room_id: &str) -> PathBuf {
        self.catalog_directory.join(format!("{room_id}.catalog"))
    }
}

async fn connect(
    ws: WebSocketUpgrade,
    Path((room_id, peer_id)): Path<(String, String)>,
    State(state): State<RelayState>,
    headers: HeaderMap,
) -> Response {
    if !valid_peer_id(&peer_id) {
        return StatusCode::BAD_REQUEST.into_response();
    }
    let sender = match state.authorize(&room_id, &headers) {
        Ok(sender) => sender,
        Err(status) => return status.into_response(),
    };
    ws.max_message_size(MAX_MESSAGE_BYTES)
        .on_upgrade(move |socket| relay_socket(socket, sender, peer_id))
}

async fn relay_socket(socket: WebSocket, sender: broadcast::Sender<RoomMessage>, peer_id: String) {
    let mut receiver = sender.subscribe();
    let (mut websocket_sender, mut websocket_receiver) = socket.split();
    let (control_sender, mut control_receiver) = mpsc::unbounded_channel();
    let incoming_sender = sender.clone();
    let incoming_peer_id = peer_id.clone();

    let incoming = async move {
        while let Some(message) = websocket_receiver.next().await {
            match message {
                Ok(Message::Binary(bytes)) if bytes.len() <= MAX_MESSAGE_BYTES => {
                    let _ = incoming_sender.send(RoomMessage {
                        sender_id: incoming_peer_id.clone(),
                        bytes,
                    });
                }
                Ok(Message::Ping(bytes)) => {
                    if control_sender.send(Message::Pong(bytes)).is_err() {
                        break;
                    }
                }
                Ok(Message::Pong(_)) => {}
                Ok(Message::Close(_)) | Err(_) => break,
                Ok(Message::Text(_) | Message::Binary(_)) => break,
            }
        }
    };

    let outgoing = async move {
        loop {
            let message = tokio::select! {
                biased;
                message = control_receiver.recv() => match message {
                    Some(message) => message,
                    None => break,
                },
                message = receiver.recv() => match message {
                    Ok(message) if message.sender_id != peer_id => Message::Binary(message.bytes),
                    Ok(_) | Err(broadcast::error::RecvError::Lagged(_)) => continue,
                    Err(broadcast::error::RecvError::Closed) => break,
                },
            };
            if websocket_sender.send(message).await.is_err() {
                break;
            }
        }
    };

    tokio::select! {
        _ = incoming => {}
        _ = outgoing => {}
    }
}

async fn send(
    Path((room_id, peer_id)): Path<(String, String)>,
    State(state): State<RelayState>,
    headers: HeaderMap,
    body: Bytes,
) -> Result<StatusCode, StatusCode> {
    if !valid_peer_id(&peer_id) {
        return Err(StatusCode::BAD_REQUEST);
    }
    let sender = state.authorize(&room_id, &headers)?;
    if body.is_empty() || body.len() > MAX_MESSAGE_BYTES {
        return Err(StatusCode::PAYLOAD_TOO_LARGE);
    }
    let _ = sender.send(RoomMessage {
        sender_id: peer_id,
        bytes: body,
    });
    Ok(StatusCode::NO_CONTENT)
}

async fn put_catalog(
    Path(room_id): Path<String>,
    State(state): State<RelayState>,
    headers: HeaderMap,
    body: Bytes,
) -> Result<StatusCode, StatusCode> {
    state.authorize(&room_id, &headers)?;
    if body.is_empty() || body.len() > MAX_MESSAGE_BYTES {
        return Err(StatusCode::PAYLOAD_TOO_LARGE);
    }
    let _write_guard = state.catalog_write_lock.lock().await;
    let path = state.catalog_path(&room_id);
    let current = match tokio::fs::read(&path).await {
        Ok(bytes) => Some(bytes),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => None,
        Err(_) => return Err(StatusCode::INTERNAL_SERVER_ERROR),
    };
    if let Some(expected) = headers.get(axum::http::header::IF_MATCH) {
        let matches = expected.to_str().ok().is_some_and(|expected| {
            current
                .as_deref()
                .is_some_and(|bytes| catalog_etag(bytes) == expected)
        });
        if !matches {
            return Err(StatusCode::PRECONDITION_FAILED);
        }
    }
    if headers
        .get(axum::http::header::IF_NONE_MATCH)
        .is_some_and(|value| value == "*")
        && current.is_some()
    {
        return Err(StatusCode::PRECONDITION_FAILED);
    }
    let suffix = state.temporary_file_counter.fetch_add(1, Ordering::Relaxed);
    let temporary_path = path.with_extension(format!("catalog.{}.{}", std::process::id(), suffix));
    tokio::fs::write(&temporary_path, body)
        .await
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    tokio::fs::rename(&temporary_path, &path)
        .await
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    Ok(StatusCode::NO_CONTENT)
}

async fn get_catalog(
    Path(room_id): Path<String>,
    State(state): State<RelayState>,
    headers: HeaderMap,
) -> Result<(HeaderMap, Bytes), StatusCode> {
    state.authorize(&room_id, &headers)?;
    let path = state.catalog_path(&room_id);
    if catalog_expired(&path).await? {
        let _ = tokio::fs::remove_file(&path).await;
        return Err(StatusCode::NOT_FOUND);
    }
    let bytes = tokio::fs::read(path).await.map_err(|error| {
        if error.kind() == std::io::ErrorKind::NotFound {
            StatusCode::NOT_FOUND
        } else {
            StatusCode::INTERNAL_SERVER_ERROR
        }
    })?;
    let mut response_headers = HeaderMap::new();
    response_headers.insert(
        axum::http::header::ETAG,
        HeaderValue::from_str(&catalog_etag(&bytes))
            .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?,
    );
    response_headers.insert(
        axum::http::header::CACHE_CONTROL,
        HeaderValue::from_static("no-store"),
    );
    Ok((response_headers, Bytes::from(bytes)))
}

fn catalog_etag(bytes: &[u8]) -> String {
    let mut hasher = DefaultHasher::new();
    bytes.hash(&mut hasher);
    format!("\"{:016x}\"", hasher.finish())
}

async fn catalog_expired(path: &FilePath) -> Result<bool, StatusCode> {
    let metadata = match tokio::fs::metadata(path).await {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(false),
        Err(_) => return Err(StatusCode::INTERNAL_SERVER_ERROR),
    };
    let modified = metadata
        .modified()
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    Ok(SystemTime::now()
        .duration_since(modified)
        .is_ok_and(|age| age > CATALOG_RETENTION))
}

fn bearer_credential(headers: &HeaderMap) -> Option<&str> {
    headers
        .get(axum::http::header::AUTHORIZATION)?
        .to_str()
        .ok()?
        .strip_prefix("Bearer ")
        .filter(|credential| valid_identifier(credential))
}

fn valid_identifier(value: &str) -> bool {
    value.len() == 43
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-' || byte == b'_')
}

fn valid_peer_id(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 128
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-' || byte == b'_')
}

async fn shutdown_signal() {
    let _ = tokio::signal::ctrl_c().await;
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio_tungstenite::connect_async;
    use tokio_tungstenite::tungstenite::client::IntoClientRequest;

    fn catalog_body(response: Result<(HeaderMap, Bytes), StatusCode>) -> Result<Bytes, StatusCode> {
        response.map(|(_, body)| body)
    }

    #[test]
    fn identifiers_are_strictly_url_safe() {
        assert!(valid_identifier(&"a".repeat(43)));
        assert!(!valid_identifier(&"a".repeat(42)));
        assert!(!valid_identifier(&format!("{}+", "a".repeat(42))));
        assert!(valid_peer_id("mac-A1_2"));
        assert!(!valid_peer_id("two peers"));
    }

    #[test]
    fn bearer_auth_requires_expected_shape() {
        let credential = "c".repeat(43);
        let mut headers = HeaderMap::new();
        headers.insert(
            axum::http::header::AUTHORIZATION,
            format!("Bearer {credential}")
                .parse()
                .expect("valid header"),
        );
        assert_eq!(bearer_credential(&headers), Some(credential.as_str()));
    }

    #[tokio::test]
    async fn catalog_round_trips_opaque_bytes_and_rejects_other_credentials() {
        let directory = env::temp_dir().join(format!(
            "vaultty-relay-test-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(SystemTime::UNIX_EPOCH)
                .expect("clock after epoch")
                .as_nanos()
        ));
        let state = RelayState::new(directory.clone())
            .await
            .expect("test relay state");
        let room = "r".repeat(43);
        let mut headers = HeaderMap::new();
        headers.insert(
            axum::http::header::AUTHORIZATION,
            format!("Bearer {}", "c".repeat(43))
                .parse()
                .expect("valid header"),
        );

        assert_eq!(
            put_catalog(
                Path(room.clone()),
                State(state.clone()),
                headers.clone(),
                Bytes::from_static(b"opaque ciphertext")
            )
            .await,
            Ok(StatusCode::NO_CONTENT)
        );
        assert_eq!(
            catalog_body(
                get_catalog(Path(room.clone()), State(state.clone()), headers.clone()).await
            ),
            Ok(Bytes::from_static(b"opaque ciphertext"))
        );

        headers.insert(
            axum::http::header::AUTHORIZATION,
            format!("Bearer {}", "x".repeat(43))
                .parse()
                .expect("valid header"),
        );
        assert_eq!(
            catalog_body(get_catalog(Path(room), State(state), headers).await),
            Err(StatusCode::UNAUTHORIZED)
        );

        std::fs::remove_dir_all(directory).expect("remove isolated test directory");
    }

    #[tokio::test]
    async fn catalog_rejects_stale_conditional_write() {
        let directory = env::temp_dir().join(format!(
            "vaultty-relay-catalog-race-test-{}",
            SystemTime::now()
                .duration_since(SystemTime::UNIX_EPOCH)
                .expect("clock after epoch")
                .as_nanos()
        ));
        let state = RelayState::new(directory.clone())
            .await
            .expect("test relay state");
        let room = "r".repeat(43);
        let mut headers = HeaderMap::new();
        headers.insert(
            axum::http::header::AUTHORIZATION,
            format!("Bearer {}", "c".repeat(43))
                .parse()
                .expect("valid header"),
        );
        assert_eq!(
            put_catalog(
                Path(room.clone()),
                State(state.clone()),
                headers.clone(),
                Bytes::from_static(b"current ciphertext")
            )
            .await,
            Ok(StatusCode::NO_CONTENT)
        );
        let read_headers = headers.clone();
        let (catalog_headers, catalog) = get_catalog(
            Path(room.clone()),
            State(state.clone()),
            read_headers.clone(),
        )
        .await
        .expect("current catalog");
        assert_eq!(catalog, Bytes::from_static(b"current ciphertext"));
        let current_etag = catalog_headers
            .get(axum::http::header::ETAG)
            .expect("catalog ETag")
            .clone();
        assert_eq!(
            catalog_headers.get(axum::http::header::CACHE_CONTROL),
            Some(&HeaderValue::from_static("no-store"))
        );

        let mut first_writer_headers = headers.clone();
        first_writer_headers.insert(axum::http::header::IF_MATCH, current_etag.clone());
        assert_eq!(
            put_catalog(
                Path(room.clone()),
                State(state.clone()),
                first_writer_headers,
                Bytes::from_static(b"fresh ciphertext")
            )
            .await,
            Ok(StatusCode::NO_CONTENT)
        );

        headers.insert(axum::http::header::IF_MATCH, current_etag);
        assert_eq!(
            put_catalog(
                Path(room.clone()),
                State(state.clone()),
                headers,
                Bytes::from_static(b"stale ciphertext")
            )
            .await,
            Err(StatusCode::PRECONDITION_FAILED)
        );
        assert_eq!(
            catalog_body(get_catalog(Path(room), State(state), read_headers).await),
            Ok(Bytes::from_static(b"fresh ciphertext"))
        );

        std::fs::remove_dir_all(directory).expect("remove isolated test directory");
    }

    #[tokio::test]
    async fn urgent_send_broadcasts_opaque_bytes() {
        let directory = env::temp_dir().join(format!(
            "vaultty-relay-urgent-test-{}",
            SystemTime::now()
                .duration_since(SystemTime::UNIX_EPOCH)
                .expect("clock after epoch")
                .as_nanos()
        ));
        let state = RelayState::new(directory.clone())
            .await
            .expect("test relay state");
        let room = "r".repeat(43);
        let mut headers = HeaderMap::new();
        headers.insert(
            axum::http::header::AUTHORIZATION,
            format!("Bearer {}", "c".repeat(43))
                .parse()
                .expect("valid header"),
        );
        let sender = state
            .authorize(&room, &headers)
            .expect("authorize receiver");
        let mut receiver = sender.subscribe();
        let payload = Bytes::from_static(b"opaque interrupt ciphertext");

        assert_eq!(
            send(
                Path((room, "phone".to_owned())),
                State(state),
                headers,
                payload.clone()
            )
            .await,
            Ok(StatusCode::NO_CONTENT)
        );
        let message = receiver.recv().await.expect("urgent broadcast");
        assert_eq!(message.sender_id, "phone");
        assert_eq!(message.bytes, payload);

        std::fs::remove_dir_all(directory).expect("remove isolated test directory");
    }

    #[tokio::test]
    async fn websocket_fanout_is_byte_exact_and_does_not_echo() {
        let directory = env::temp_dir().join(format!(
            "vaultty-relay-ws-test-{}",
            SystemTime::now()
                .duration_since(SystemTime::UNIX_EPOCH)
                .expect("clock after epoch")
                .as_nanos()
        ));
        let state = RelayState::new(directory.clone())
            .await
            .expect("test relay state");
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
            .await
            .expect("bind test relay");
        let address = listener.local_addr().expect("test relay address");
        let server = tokio::spawn(async move {
            axum::serve(listener, router(state))
                .await
                .expect("serve test relay");
        });
        let room = "r".repeat(43);
        let credential = "c".repeat(43);

        let connect = |peer: &str| {
            let mut request = format!("ws://{address}/v1/connect/{room}/{peer}")
                .into_client_request()
                .expect("websocket request");
            request.headers_mut().insert(
                axum::http::header::AUTHORIZATION,
                format!("Bearer {credential}").parse().expect("auth header"),
            );
            connect_async(request)
        };
        let (mut first, _) = connect("first").await.expect("first websocket");
        let (mut second, _) = connect("second").await.expect("second websocket");
        let payload = Bytes::from_static(&[0, 1, 2, 3, 255]);
        first
            .send(tokio_tungstenite::tungstenite::Message::Binary(
                payload.clone(),
            ))
            .await
            .expect("send opaque frame");

        let received = tokio::time::timeout(Duration::from_secs(1), second.next())
            .await
            .expect("fanout deadline")
            .expect("second socket open")
            .expect("valid websocket frame");
        assert_eq!(received.into_data(), payload);
        assert!(
            tokio::time::timeout(Duration::from_millis(50), first.next())
                .await
                .is_err()
        );

        server.abort();
        std::fs::remove_dir_all(directory).expect("remove isolated test directory");
    }

    #[tokio::test]
    async fn websocket_answers_ping_without_broadcasting_it() {
        let directory = env::temp_dir().join(format!(
            "vaultty-relay-ping-test-{}",
            SystemTime::now()
                .duration_since(SystemTime::UNIX_EPOCH)
                .expect("clock after epoch")
                .as_nanos()
        ));
        let state = RelayState::new(directory.clone())
            .await
            .expect("test relay state");
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
            .await
            .expect("bind test relay");
        let address = listener.local_addr().expect("test relay address");
        let server = tokio::spawn(async move {
            axum::serve(listener, router(state))
                .await
                .expect("serve test relay");
        });
        let room = "r".repeat(43);
        let credential = "c".repeat(43);
        let mut request = format!("ws://{address}/v1/connect/{room}/peer")
            .into_client_request()
            .expect("websocket request");
        request.headers_mut().insert(
            axum::http::header::AUTHORIZATION,
            format!("Bearer {credential}").parse().expect("auth header"),
        );
        let (mut socket, _) = connect_async(request).await.expect("websocket");
        let payload = Bytes::from_static(b"keepalive");
        socket
            .send(tokio_tungstenite::tungstenite::Message::Ping(
                payload.clone(),
            ))
            .await
            .expect("send ping");

        let received = tokio::time::timeout(Duration::from_secs(1), socket.next())
            .await
            .expect("pong deadline")
            .expect("socket open")
            .expect("valid websocket frame");
        assert_eq!(
            received,
            tokio_tungstenite::tungstenite::Message::Pong(payload)
        );

        server.abort();
        std::fs::remove_dir_all(directory).expect("remove isolated test directory");
    }
}
