//! Gitinuum's event-driven relay. Authentication, encryption and APNs adapted from Canopy.
use aes_gcm::{
    Aes256Gcm, Nonce,
    aead::{Aead, KeyInit as AeadKeyInit},
};
use anyhow::{Context, Result};
use axum::{
    Json, Router,
    body::Bytes,
    extract::{DefaultBodyLimit, Query, State},
    http::{HeaderMap, StatusCode, header},
    response::{Html, IntoResponse, Redirect, Response},
    routing::{get, post},
};
use chrono::{DateTime, Utc};
use hmac::{Hmac, Mac};
use jsonwebtoken::{Algorithm, EncodingKey, Header, encode};
use reqwest::Client;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::Sha256;
use sqlx::{
    Row, SqlitePool,
    sqlite::{SqliteConnectOptions, SqliteJournalMode, SqlitePoolOptions, SqliteSynchronous},
};
use std::{
    collections::{HashMap, HashSet},
    env,
    fs::{File, OpenOptions},
    os::unix::fs::OpenOptionsExt,
    path::{Path, PathBuf},
    sync::Arc,
    time::Duration,
};
use tracing::{error, info, warn};
use uuid::Uuid;

type WebResult<T> = Result<T, WebError>;
type HmacSha256 = Hmac<Sha256>;
#[derive(Clone)]
struct AppState {
    db: SqlitePool,
    http: Client,
    config: Arc<Config>,
    sync_lock: Arc<tokio::sync::Mutex<()>>,
}
struct Config {
    webhook_secret: String,
    github_client_id: String,
    github_client_secret: String,
    github_app_slug: String,
    github_app_id: String,
    github_key: EncodingKey,
    github_notifications_client_id: String,
    github_notifications_client_secret: String,
    encryption_key: [u8; 32],
    apns_team_id: String,
    apns_topic: String,
    apns_sandbox: ApnsCredentials,
    apns_production: ApnsCredentials,
}
struct ApnsCredentials {
    key_id: String,
    key: EncodingKey,
}
fn required(name: &str) -> Result<String> {
    env::var(name).with_context(|| format!("{name} is required"))
}
fn apns_credentials(environment: &str) -> Result<ApnsCredentials> {
    Ok(ApnsCredentials {
        key_id: required(&format!("APNS_{environment}_KEY_ID"))?,
        key: EncodingKey::from_ec_pem(
            required(&format!("APNS_{environment}_P8"))?
                .replace("\\n", "\n")
                .as_bytes(),
        )?,
    })
}
impl Config {
    fn from_env() -> Result<Self> {
        Ok(Self {
            webhook_secret: required("GITINUUM_WEBHOOK_SECRET")?,
            github_client_id: required("GITINUUM_GITHUB_CLIENT_ID")?,
            github_client_secret: required("GITINUUM_GITHUB_CLIENT_SECRET")?,
            github_app_slug: required("GITINUUM_GITHUB_APP_SLUG")?,
            github_app_id: required("GITINUUM_GITHUB_APP_ID")?,
            github_key: EncodingKey::from_rsa_pem(
                required("GITINUUM_GITHUB_PRIVATE_KEY")?
                    .replace("\\n", "\n")
                    .as_bytes(),
            )?,
            github_notifications_client_id: required("GITINUUM_NOTIFICATIONS_CLIENT_ID")?,
            github_notifications_client_secret: required("GITINUUM_NOTIFICATIONS_CLIENT_SECRET")?,
            encryption_key: hex::decode(required("GITINUUM_ENCRYPTION_KEY")?)?
                .try_into()
                .map_err(|_| anyhow::anyhow!("Encryption key must be 32 bytes"))?,
            apns_team_id: required("APPLE_TEAM_ID")?,
            apns_topic: "dev.mxcl.git-sync.menu-helper".into(),
            apns_sandbox: apns_credentials("SANDBOX")?,
            apns_production: apns_credentials("PRODUCTION")?,
        })
    }
}
async fn open_database(path: &Path) -> Result<(SqlitePool, File)> {
    // Canonicalize aliases so two processes cannot accidentally lock different sidecar files.
    let path = if path.exists() {
        path.canonicalize()?
    } else {
        path.parent()
            .filter(|p| !p.as_os_str().is_empty())
            .unwrap_or(Path::new("."))
            .canonicalize()?
            .join(path.file_name().context("Database filename is required")?)
    };
    let mut lock_path = path.as_os_str().to_os_string();
    lock_path.push(".lock");
    let lock = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .mode(0o600)
        .open(lock_path)?;
    lock.try_lock()
        .context("Another relay is using this SQLite database")?;
    OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .mode(0o600)
        .open(&path)?;
    let db = SqlitePoolOptions::new()
        .max_connections(1)
        .connect_with(
            SqliteConnectOptions::new()
                .filename(path)
                .foreign_keys(true)
                .journal_mode(SqliteJournalMode::Wal)
                .synchronous(SqliteSynchronous::Full)
                .busy_timeout(Duration::from_secs(5)),
        )
        .await?;
    let mut tx = db.begin().await?;
    let version: i64 = sqlx::query_scalar("PRAGMA user_version")
        .fetch_one(&mut *tx)
        .await?;
    match version {
        0 => {
            let tables: i64 = sqlx::query_scalar("SELECT count(*) FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'")
                .fetch_one(&mut *tx).await?;
            anyhow::ensure!(
                tables == 0,
                "Refusing to initialize an unrecognized SQLite database"
            );
            sqlx::raw_sql(include_str!("../schema.sql"))
                .execute(&mut *tx)
                .await?;
            sqlx::query("PRAGMA user_version=1")
                .execute(&mut *tx)
                .await?;
        }
        1 | 2 => {}
        _ => anyhow::bail!("Unsupported SQLite schema version: {version}"),
    }
    if version < 2 {
        sqlx::raw_sql(include_str!("../migration-2.sql"))
            .execute(&mut *tx)
            .await?;
        sqlx::query("PRAGMA user_version=2")
            .execute(&mut *tx)
            .await?;
    }
    tx.commit().await?;
    Ok((db, lock))
}

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::from_default_env())
        .init();
    let path =
        PathBuf::from(env::var("DATABASE_PATH").unwrap_or_else(|_| "gitinuum.sqlite3".into()));
    let (db, _database_lock) = open_database(&path).await?;
    sqlx::query("DELETE FROM oauth_states WHERE expires_at < unixepoch()")
        .execute(&db)
        .await?;
    sqlx::query("DELETE FROM devices WHERE user_id IS NULL AND created_at < unixepoch() - 86400")
        .execute(&db)
        .await?;
    sqlx::query("DELETE FROM deliveries WHERE created_at < unixepoch() - 2592000")
        .execute(&db)
        .await?;
    sqlx::query("DELETE FROM notifications WHERE updated_at < unixepoch() - 2592000 AND COALESCE(json_extract(note, '$.unread'),0)=0")
        .execute(&db)
        .await?;
    let state = AppState {
        db,
        config: Arc::new(Config::from_env()?),
        sync_lock: Arc::new(tokio::sync::Mutex::new(())),
        http: Client::builder()
            .timeout(Duration::from_secs(20))
            .redirect(reqwest::redirect::Policy::none())
            .user_agent("Gitinuum/1")
            .build()?,
    };
    let app = Router::new()
        .route("/heartbeat", get(|| async { StatusCode::OK }))
        .route("/webhook", post(webhook))
        .route("/connect", post(connect))
        .route("/oauth/hello", get(hello))
        .route("/sync", post(sync))
        .route("/ack", post(ack))
        .route("/disconnect", post(disconnect))
        .layer(DefaultBodyLimit::max(1_048_576))
        .with_state(state);
    let address = env::var("GITINUUM_LISTEN").unwrap_or_else(|_| "127.0.0.1:3022".into());
    info!(%address, "Gitinuum relay listening");
    axum::serve(tokio::net::TcpListener::bind(address).await?, app)
        .with_graceful_shutdown(async {
            let _ = tokio::signal::ctrl_c().await;
        })
        .await?;
    Ok(())
}
#[derive(Debug)]
struct WebError(StatusCode, String, Option<u64>);
impl WebError {
    fn bad_request(message: impl Into<String>) -> Self {
        Self(StatusCode::BAD_REQUEST, message.into(), None)
    }
    fn unauthorized() -> Self {
        Self(
            StatusCode::UNAUTHORIZED,
            "Connect GitHub again".into(),
            None,
        )
    }
    fn internal(error: impl std::fmt::Display) -> Self {
        error!(%error,"relay request failed");
        Self(
            StatusCode::INTERNAL_SERVER_ERROR,
            "Relay request failed".into(),
            None,
        )
    }
}
impl IntoResponse for WebError {
    fn into_response(self) -> Response {
        let mut response = (self.0, Json(json!({"reason":self.1}))).into_response();
        if let Some(seconds) = self.2 {
            response
                .headers_mut()
                .insert(header::RETRY_AFTER, seconds.to_string().parse().unwrap());
        }
        response
    }
}
impl From<sqlx::Error> for WebError {
    fn from(e: sqlx::Error) -> Self {
        Self::internal(e)
    }
}
impl From<reqwest::Error> for WebError {
    fn from(e: reqwest::Error) -> Self {
        Self::internal(e.without_url())
    }
}
async fn checked(response: reqwest::Response) -> WebResult<reqwest::Response> {
    if response.status() == StatusCode::UNAUTHORIZED {
        return Err(WebError::unauthorized());
    }
    if response.status() == StatusCode::TOO_MANY_REQUESTS
        || response.status() == StatusCode::FORBIDDEN
    {
        let seconds = response
            .headers()
            .get("retry-after")
            .and_then(|v| v.to_str().ok())
            .and_then(|s| s.parse::<u64>().ok())
            .or_else(|| {
                response
                    .headers()
                    .get("x-ratelimit-reset")
                    .and_then(|v| v.to_str().ok())
                    .and_then(|s| s.parse::<i64>().ok())
                    .map(|t| (t - Utc::now().timestamp()).max(1) as u64)
            })
            .unwrap_or(60);
        return Err(WebError(
            StatusCode::TOO_MANY_REQUESTS,
            "GitHub access or rate limit; retry later".into(),
            Some(seconds),
        ));
    }
    Ok(response.error_for_status()?)
}
fn check_protocol(headers: &HeaderMap) -> WebResult<()> {
    if headers
        .get("gitinuum-protocol")
        .and_then(|v| v.to_str().ok())
        != Some("1")
    {
        return Err(WebError::bad_request("Unsupported Gitinuum relay protocol"));
    }
    Ok(())
}
fn bearer(headers: &HeaderMap) -> WebResult<Uuid> {
    check_protocol(headers)?;
    headers
        .get(header::AUTHORIZATION)
        .and_then(|v| v.to_str().ok())
        .and_then(|s| s.strip_prefix("Bearer "))
        .and_then(|s| Uuid::parse_str(s).ok())
        .ok_or_else(WebError::unauthorized)
}
async fn authenticated(state: &AppState, headers: &HeaderMap) -> WebResult<Uuid> {
    let id = bearer(headers)?;
    if !sqlx::query_scalar::<_, bool>("SELECT EXISTS(SELECT 1 FROM devices WHERE id=$1)")
        .bind(id)
        .fetch_one(&state.db)
        .await?
    {
        return Err(WebError::unauthorized());
    }
    Ok(id)
}
#[derive(Serialize, Deserialize)]
struct GitHubToken {
    access_token: String,
    refresh_token: Option<String>,
    expires_in: Option<i64>,
    scope: Option<String>,
    #[serde(default)]
    expires_at: Option<i64>,
}
fn encrypt(key: &[u8; 32], value: &GitHubToken) -> WebResult<(Vec<u8>, Vec<u8>)> {
    let cipher = Aes256Gcm::new_from_slice(key).map_err(WebError::internal)?;
    let nonce = Uuid::new_v4().as_bytes()[..12].to_vec();
    let data = serde_json::to_vec(value).map_err(WebError::internal)?;
    let encrypted = cipher
        .encrypt(
            &Nonce::try_from(nonce.as_slice()).map_err(WebError::internal)?,
            data.as_slice(),
        )
        .map_err(WebError::internal)?;
    Ok((encrypted, nonce))
}
fn decrypt(key: &[u8; 32], data: &[u8], nonce: &[u8]) -> WebResult<GitHubToken> {
    if nonce.len() != 12 {
        return Err(WebError::internal("Invalid credential nonce"));
    }
    let cipher = Aes256Gcm::new_from_slice(key).map_err(WebError::internal)?;
    let bytes = cipher
        .decrypt(&Nonce::try_from(nonce).map_err(WebError::internal)?, data)
        .map_err(WebError::internal)?;
    serde_json::from_slice(&bytes).map_err(WebError::internal)
}
async fn exchange(state: &AppState, kind: &str, mut body: Value) -> WebResult<GitHubToken> {
    let (client, secret) = if kind == "app" {
        (
            &state.config.github_client_id,
            &state.config.github_client_secret,
        )
    } else {
        (
            &state.config.github_notifications_client_id,
            &state.config.github_notifications_client_secret,
        )
    };
    body["client_id"] = json!(client);
    body["client_secret"] = json!(secret);
    let mut token: GitHubToken = checked(
        state
            .http
            .post("https://github.com/login/oauth/access_token")
            .header(header::ACCEPT, "application/json")
            .json(&body)
            .send()
            .await?,
    )
    .await?
    .json()
    .await?;
    token.expires_at = token
        .expires_in
        .map(|seconds| Utc::now().timestamp() + seconds);
    Ok(token)
}
async fn store_token(
    state: &AppState,
    device: Uuid,
    kind: &str,
    token: &GitHubToken,
) -> WebResult<()> {
    let (data, nonce) = encrypt(&state.config.encryption_key, token)?;
    let query = if kind == "app" {
        "UPDATE devices SET app_credentials=$2,app_nonce=$3 WHERE id=$1"
    } else {
        "UPDATE devices SET inbox_credentials=$2,inbox_nonce=$3 WHERE id=$1"
    };
    sqlx::query(query)
        .bind(device)
        .bind(data)
        .bind(nonce)
        .execute(&state.db)
        .await?;
    Ok(())
}
async fn token(state: &AppState, device: Uuid, kind: &str) -> WebResult<String> {
    let query = if kind == "app" {
        "SELECT app_credentials AS data,app_nonce AS nonce FROM devices WHERE id=$1"
    } else {
        "SELECT inbox_credentials AS data,inbox_nonce AS nonce FROM devices WHERE id=$1"
    };
    let row = sqlx::query(query).bind(device).fetch_one(&state.db).await?;
    let data: Option<Vec<u8>> = row.get("data");
    let nonce: Option<Vec<u8>> = row.get("nonce");
    let mut value = decrypt(
        &state.config.encryption_key,
        &data.ok_or_else(WebError::unauthorized)?,
        &nonce.ok_or_else(WebError::unauthorized)?,
    )?;
    if value
        .expires_at
        .is_some_and(|t| t < Utc::now().timestamp() + 60)
    {
        value=exchange(state,kind,json!({"grant_type":"refresh_token","refresh_token":value.refresh_token.ok_or_else(WebError::unauthorized)?})).await?;
        store_token(state, device, kind, &value).await?;
    }
    Ok(value.access_token)
}
async fn oauth_url(state: &AppState, device: Uuid, kind: &str) -> WebResult<String> {
    let id = Uuid::new_v4();
    sqlx::query("INSERT INTO oauth_states(id,device,kind) VALUES($1,$2,$3)")
        .bind(id)
        .bind(device)
        .bind(kind)
        .execute(&state.db)
        .await?;
    let mut url = url::Url::parse("https://github.com/login/oauth/authorize").unwrap();
    url.query_pairs_mut()
        .append_pair(
            "client_id",
            if kind == "app" {
                &state.config.github_client_id
            } else {
                &state.config.github_notifications_client_id
            },
        )
        .append_pair("state", &id.to_string());
    if kind != "app" {
        url.query_pairs_mut().append_pair("scope", "notifications");
    }
    Ok(url.into())
}
async fn connect(State(state): State<AppState>, headers: HeaderMap) -> WebResult<Json<Value>> {
    check_protocol(&headers)?;
    let id = Uuid::new_v4();
    sqlx::query("INSERT INTO devices(id) VALUES($1)")
        .bind(id)
        .execute(&state.db)
        .await?;
    Ok(Json(
        json!({"session":id,"url":oauth_url(&state,id,"app").await?}),
    ))
}
#[derive(Deserialize)]
struct Hello {
    state: Uuid,
    code: String,
}
async fn hello(State(state): State<AppState>, Query(input): Query<Hello>) -> WebResult<Response> {
    let row = sqlx::query(
        "DELETE FROM oauth_states WHERE id=$1 AND expires_at>unixepoch() RETURNING device,kind",
    )
    .bind(input.state)
    .fetch_optional(&state.db)
    .await?
    .ok_or_else(|| WebError::bad_request("Expired sign-in; connect again"))?;
    let device: Uuid = row.get("device");
    let kind: String = row.get("kind");
    let credentials = exchange(&state, &kind, json!({"code":input.code})).await?;
    let user: Value = checked(
        state
            .http
            .get("https://api.github.com/user")
            .bearer_auth(&credentials.access_token)
            .send()
            .await?,
    )
    .await?
    .json()
    .await?;
    let user_id = user["id"].as_i64().ok_or_else(WebError::unauthorized)?;
    if kind == "app" {
        sqlx::query("UPDATE devices SET user_id=$2 WHERE id=$1")
            .bind(device)
            .bind(user_id)
            .execute(&state.db)
            .await?;
    } else {
        let expected: Option<i64> = sqlx::query_scalar("SELECT user_id FROM devices WHERE id=$1")
            .bind(device)
            .fetch_one(&state.db)
            .await?;
        if expected != Some(user_id)
            || !credentials
                .scope
                .as_deref()
                .unwrap_or("")
                .split([',', ' '])
                .any(|s| s == "notifications")
        {
            return Err(WebError::unauthorized());
        }
    }
    store_token(&state, device, &kind, &credentials).await?;
    if kind == "app" {
        return Ok(Redirect::temporary(&oauth_url(&state, device, "inbox").await?).into_response());
    }
    Ok(Html("<!doctype html><meta name=viewport content='width=device-width'><title>Gitinuum</title><h1>GitHub connected</h1><p><a href='gitsync://github-connected'>Return to Gitinuum</a></p>").into_response())
}
async fn disconnect(State(state): State<AppState>, headers: HeaderMap) -> WebResult<StatusCode> {
    let id = authenticated(&state, &headers).await?;
    sqlx::query("DELETE FROM devices WHERE id=$1")
        .bind(id)
        .execute(&state.db)
        .await?;
    Ok(StatusCode::NO_CONTENT)
}
#[derive(Debug, Deserialize, Serialize, Clone)]
struct Work {
    id: Uuid,
    repository: String,
    kind: String,
}
#[derive(Debug, Deserialize, Serialize, Clone)]
#[serde(rename_all = "camelCase")]
struct MergeWork {
    id: Uuid,
    repository: String,
    source_repository: String,
    branch: String,
    oid: String,
    base_branch: String,
    default_branch: String,
    pull_request: u64,
    merged_at: String,
}

fn merged_work(event: &str, payload: &Value) -> Option<MergeWork> {
    if event != "pull_request"
        || payload["action"] != "closed"
        || payload["pull_request"]["merged"] != true
    {
        return None;
    }
    let pr = &payload["pull_request"];
    let work = MergeWork {
        id: Uuid::new_v4(),
        repository: payload["repository"]["full_name"].as_str()?.to_lowercase(),
        source_repository: pr["head"]["repo"]["full_name"].as_str()?.to_lowercase(),
        branch: pr["head"]["ref"].as_str()?.into(),
        oid: pr["head"]["sha"].as_str()?.into(),
        base_branch: pr["base"]["ref"].as_str()?.into(),
        default_branch: pr["head"]["repo"]["default_branch"].as_str()?.into(),
        pull_request: payload["number"].as_u64()?,
        merged_at: pr["merged_at"].as_str()?.into(),
    };
    if !valid_repository(&work.repository)
        || !valid_repository(&work.source_repository)
        || ![40, 64].contains(&work.oid.len())
        || !work.oid.bytes().all(|b| b.is_ascii_hexdigit())
        || work.branch.is_empty()
        || work.pull_request == 0
        || chrono::DateTime::parse_from_rfc3339(&work.merged_at).is_err()
    {
        return None;
    }
    Some(work)
}

async fn queue_merge(
    tx: &mut sqlx::SqliteConnection,
    device: Uuid,
    work: &MergeWork,
) -> Result<(), sqlx::Error> {
    sqlx::query("INSERT INTO merged_work(device,repository,id,pr,oid,record) VALUES($1,$2,$3,$4,$5,$6) ON CONFLICT DO NOTHING")
        .bind(device).bind(&work.repository).bind(work.id).bind(work.pull_request as i64)
        .bind(&work.oid).bind(sqlx::types::Json(work)).execute(tx).await?;
    Ok(())
}

async fn ack(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(ids): Json<Vec<Uuid>>,
) -> WebResult<StatusCode> {
    let device = authenticated(&state, &headers).await?;
    let mut tx = state.db.begin().await?;
    for id in ids {
        sqlx::query("UPDATE merged_work SET completed=1 WHERE device=$1 AND id=$2")
            .bind(device)
            .bind(id)
            .execute(&mut *tx)
            .await?;
        sqlx::query("DELETE FROM pending WHERE device=$1 AND kind='fetch' AND id=$2")
            .bind(device)
            .bind(id)
            .execute(&mut *tx)
            .await?;
    }
    tx.commit().await?;
    Ok(StatusCode::NO_CONTENT)
}
fn valid_repository(name: &str) -> bool {
    let parts: Vec<_> = name.split('/').collect();
    parts.len() == 2
        && parts.iter().all(|p| {
            !p.is_empty()
                && *p != "."
                && *p != ".."
                && p.len() <= 100
                && p.bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b"._-".contains(&b))
        })
}
#[derive(Clone)]
struct RepositoryAccess {
    id: i64,
    installation: i64,
}
async fn accessible_repositories(
    state: &AppState,
    token: &str,
    requested: &HashSet<String>,
) -> WebResult<HashMap<String, RepositoryAccess>> {
    let mut result = HashMap::new();
    for page in 1.. {
        let installations: Value = checked(
            state
                .http
                .get("https://api.github.com/user/installations")
                .bearer_auth(token)
                .query(&[("per_page", 100), ("page", page)])
                .send()
                .await?,
        )
        .await?
        .json()
        .await?;
        let items = installations["installations"]
            .as_array()
            .ok_or_else(|| WebError::internal("Invalid installation list"))?;
        for installation in items {
            if !installation["suspended_at"].is_null() {
                continue;
            }
            let id = installation["id"]
                .as_i64()
                .ok_or_else(|| WebError::internal("Invalid installation"))?;
            for page in 1.. {
                let repositories: Value = checked(
                    state
                        .http
                        .get(format!(
                            "https://api.github.com/user/installations/{id}/repositories"
                        ))
                        .bearer_auth(token)
                        .query(&[("per_page", 100), ("page", page)])
                        .send()
                        .await?,
                )
                .await?
                .json()
                .await?;
                let repos = repositories["repositories"]
                    .as_array()
                    .ok_or_else(|| WebError::internal("Invalid repository list"))?;
                for repo in repos {
                    if let (Some(name), Some(repo_id)) =
                        (repo["full_name"].as_str(), repo["id"].as_i64())
                    {
                        let name = name.to_lowercase();
                        if requested.contains(&name) {
                            result.insert(
                                name,
                                RepositoryAccess {
                                    id: repo_id,
                                    installation: id,
                                },
                            );
                        }
                    }
                }
                if repos.len() < 100 {
                    break;
                }
            }
        }
        if items.len() < 100 {
            break;
        }
    }
    Ok(result)
}
async fn installation_token(state: &AppState, installation: i64) -> WebResult<String> {
    let now = Utc::now().timestamp();
    let jwt = encode(
        &Header::new(Algorithm::RS256),
        &json!({"iss":state.config.github_app_id,"iat":now-60,"exp":now+540}),
        &state.config.github_key,
    )
    .map_err(WebError::internal)?;
    let result: Value = checked(
        state
            .http
            .post(format!(
                "https://api.github.com/app/installations/{installation}/access_tokens"
            ))
            .bearer_auth(jwt)
            .json(
                &json!({"permissions":{"metadata":"read","issues":"read","pull_requests":"read"}}),
            )
            .send()
            .await?,
    )
    .await?
    .json()
    .await?;
    result["token"]
        .as_str()
        .map(str::to_owned)
        .ok_or_else(|| WebError::internal("Missing installation token"))
}
const COUNTS_QUERY: &str = "query($owner:String!,$name:String!){repository(owner:$owner,name:$name){stargazerCount issues(states:OPEN){totalCount} pullRequests(states:OPEN){totalCount}}}";
fn decode_counts(value: &Value) -> WebResult<Value> {
    let repo = &value["data"]["repository"];
    let count = |path: &str| {
        repo.pointer(path)
            .and_then(Value::as_u64)
            .ok_or_else(|| WebError::internal("GitHub counts unavailable"))
    };
    Ok(
        json!({"stars":count("/stargazerCount")?,"issues":count("/issues/totalCount")?,"pullRequests":count("/pullRequests/totalCount")?}),
    )
}
async fn counts(state: &AppState, repo: &str, access: &RepositoryAccess) -> WebResult<Value> {
    let (owner, name) = repo
        .split_once('/')
        .ok_or_else(|| WebError::bad_request("Invalid repository"))?;
    let value: Value = checked(
        state
            .http
            .post("https://api.github.com/graphql")
            .bearer_auth(installation_token(state, access.installation).await?)
            .json(&json!({"query":COUNTS_QUERY,"variables":{"owner":owner,"name":name}}))
            .send()
            .await?,
    )
    .await?
    .json()
    .await?;
    decode_counts(&value)
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct SyncInput {
    repositories: HashSet<String>,
    #[serde(default)]
    catch_up: bool,
    #[serde(default)]
    refresh_inbox: bool,
    token: Option<String>,
    environment: String,
}
async fn sync(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(input): Json<SyncInput>,
) -> WebResult<Json<Value>> {
    let device = authenticated(&state, &headers).await?;
    if input.repositories.len() > 1000
        || !input.repositories.iter().all(|s| valid_repository(s))
        || !["production", "sandbox"].contains(&input.environment.as_str())
        || input.token.as_ref().is_some_and(|s| {
            !(32..=256).contains(&s.len()) || !s.bytes().all(|b| b.is_ascii_hexdigit())
        })
    {
        return Err(WebError::bad_request("Invalid device registration"));
    }
    // ponytail: one refresh at a time; use keyed locks if multi-user throughput needs it.
    // Webhooks still enqueue work while network requests are in flight; no SQL transaction is held.
    let _refresh = state.sync_lock.try_lock().map_err(|_| {
        WebError(
            StatusCode::TOO_MANY_REQUESTS,
            "Refresh in progress".into(),
            Some(2),
        )
    })?;
    sqlx::query("UPDATE devices SET token=$2,environment=$3 WHERE id=$1")
        .bind(device)
        .bind(&input.token)
        .bind(&input.environment)
        .execute(&state.db)
        .await?;
    let app_token = token(&state, device, "app").await?;
    let requested = input
        .repositories
        .iter()
        .map(|s| s.to_lowercase())
        .collect();
    let accessible = accessible_repositories(&state, &app_token, &requested).await?;
    let names = accessible.keys().cloned().collect::<Vec<_>>();
    sqlx::query("DELETE FROM tracked WHERE device=$1 AND repository NOT IN (SELECT value FROM json_each($2))")
        .bind(device)
        .bind(sqlx::types::Json(&names))
        .execute(&state.db)
        .await?;
    sqlx::query("DELETE FROM notifications WHERE device=$1 AND repository NOT IN (SELECT value FROM json_each($2))")
        .bind(device)
        .bind(sqlx::types::Json(&names))
        .execute(&state.db)
        .await?;
    for (name, repo) in &accessible {
        let new=sqlx::query("INSERT INTO tracked(device,repository,repository_id,installation_id) VALUES($1,$2,$3,$4) ON CONFLICT DO NOTHING")
            .bind(device).bind(name).bind(repo.id).bind(repo.installation).execute(&state.db).await?.rows_affected()>0;
        sqlx::query("UPDATE tracked SET repository_id=$3,installation_id=$4 WHERE device=$1 AND repository=$2")
            .bind(device).bind(name).bind(repo.id).bind(repo.installation).execute(&state.db).await?;
        if new || input.catch_up {
            // Explicit catch-up also reconciles read status, even without a new thread update.
            sqlx::query("UPDATE devices SET last_modified=NULL WHERE id=$1")
                .bind(device)
                .execute(&state.db)
                .await?;
            for kind in ["fetch", "counts", "notifications"] {
                queue(&state.db, device, name, kind).await?;
            }
        }
    }
    if input.refresh_inbox {
        queue_inbox_refresh(&state.db, device, &names).await?;
    }
    let work = sqlx::query("SELECT id,repository,kind FROM pending WHERE device=$1")
        .bind(device)
        .fetch_all(&state.db)
        .await?
        .iter()
        .map(|r| Work {
            id: r.get("id"),
            repository: r.get("repository"),
            kind: r.get("kind"),
        })
        .collect::<Vec<_>>();
    let mut retry_after = None;
    let mut errors = Vec::new();
    // ponytail: sequential count requests; batch GraphQL if large project sets hit HTTP timeouts.
    for item in work.iter().filter(|w| w.kind == "counts") {
        let Some(access) = accessible.get(&item.repository) else {
            continue;
        };
        match counts(&state, &item.repository, access).await {
            Ok(value) => {
                let mut tx = state.db.begin().await?;
                sqlx::query("UPDATE tracked SET counts=$3 WHERE device=$1 AND repository=$2")
                    .bind(device)
                    .bind(&item.repository)
                    .bind(value)
                    .execute(&mut *tx)
                    .await?;
                sqlx::query("DELETE FROM pending WHERE device=$1 AND id=$2")
                    .bind(device)
                    .bind(item.id)
                    .execute(&mut *tx)
                    .await?;
                tx.commit().await?;
            }
            Err(e) => {
                retry_after = Some(e.2.unwrap_or(30));
                errors.push(e.1);
                break;
            }
        }
    }
    let notification_work = work
        .iter()
        .filter(|w| w.kind == "notifications")
        .map(|w| w.id)
        .collect::<Vec<_>>();
    if !notification_work.is_empty() {
        match refresh_notifications(&state, device, &names, &notification_work).await {
            Ok(delay) => {
                if let Some(delay) = delay {
                    retry_after = Some(retry_after.unwrap_or(0).max(delay));
                }
            }
            Err(e) => {
                retry_after = Some(retry_after.unwrap_or(0).max(e.2.unwrap_or(30)));
                errors.push(e.1);
            }
        }
    }
    let rows =
        sqlx::query("SELECT repository,counts FROM tracked WHERE device=$1 AND counts IS NOT NULL")
            .bind(device)
            .fetch_all(&state.db)
            .await?;
    let counts = rows
        .iter()
        .map(|r| {
            (
                r.get::<String, _>("repository"),
                r.get::<Value, _>("counts"),
            )
        })
        .collect::<HashMap<_, _>>();
    let mut notes = sqlx::query_scalar::<_, Value>(
        "SELECT note FROM notifications WHERE device=$1 ORDER BY json_extract(note, '$.unread') DESC, updated_at DESC LIMIT 200",
    )
    .bind(device)
    .fetch_all(&state.db)
    .await?;
    // Resolve both new and previously cached release IDs before sending browser links.
    let mut resolve_releases = true;
    for note in &mut notes {
        let Some(api_url) = release_notification_api_url(note) else {
            continue;
        };
        if resolve_releases {
            match resolve_release_notification(
                note,
                state.http.get(api_url).bearer_auth(&app_token),
            )
            .await
            {
                Ok(()) => {
                    sqlx::query("UPDATE notifications SET note=json_set(note, '$.url', $3) WHERE device=$1 AND id=$2")
                        .bind(device).bind(note["id"].as_str()).bind(note["url"].as_str())
                        .execute(&state.db).await?;
                    continue;
                }
                Err(error) => {
                    retry_after = Some(retry_after.unwrap_or(0).max(error.2.unwrap_or(60)));
                    errors.push(error.1);
                    resolve_releases = false;
                }
            }
        }
        // Keep the ID in storage for a later retry, but never send a broken browser URL.
        note["url"] = json!(format!(
            "https://github.com/{}/releases",
            note["repository"].as_str().unwrap()
        ));
    }
    let has_unread = sqlx::query_scalar::<_, bool>(
        "SELECT EXISTS(SELECT 1 FROM notifications WHERE device=$1 AND json_extract(note, '$.unread')=1)",
    ).bind(device).fetch_one(&state.db).await?;
    let merges = sqlx::query_scalar::<_, Value>(
        "SELECT record FROM merged_work WHERE device=$1 AND completed=0",
    )
    .bind(device)
    .fetch_all(&state.db)
    .await?;
    Ok(Json(
        json!({"merges":merges,"counts":counts,"notifications":notes,"hasUnreadNotifications":has_unread,"authorizedRepositories":names,
        "fetches":work.into_iter().filter(|w|w.kind=="fetch").collect::<Vec<_>>(),"retryAfter":retry_after,
        "errors":errors,"installationURL":format!("https://github.com/apps/{}/installations/new",state.config.github_app_slug)}),
    ))
}
// Read-state reconciliation must not enqueue repository fetches or counts.
async fn queue_inbox_refresh(db: &SqlitePool, device: Uuid, names: &[String]) -> WebResult<()> {
    sqlx::query("UPDATE devices SET last_modified=NULL WHERE id=$1")
        .bind(device)
        .execute(db)
        .await?;
    for name in names {
        // Keep a webhook's UUID and indexing retry if work is already pending.
        sqlx::query("INSERT INTO pending(device,repository,kind,id,attempts) VALUES($1,$2,'notifications',$3,1) ON CONFLICT DO NOTHING")
            .bind(device).bind(name).bind(Uuid::new_v4()).execute(db).await?;
    }
    Ok(())
}
async fn queue(db: &SqlitePool, device: Uuid, repo: &str, kind: &str) -> WebResult<()> {
    sqlx::query("INSERT INTO pending(device,repository,kind,id,attempts) VALUES($1,$2,$3,$4,1) ON CONFLICT(device,repository,kind) DO UPDATE SET id=EXCLUDED.id,attempts=EXCLUDED.attempts")
        .bind(device).bind(repo).bind(kind).bind(Uuid::new_v4()).execute(db).await?;
    Ok(())
}
fn release_notification_api_url(note: &Value) -> Option<String> {
    let repo = note["repository"].as_str()?;
    if !valid_repository(repo) {
        return None;
    }
    let id = note["url"]
        .as_str()?
        .strip_prefix(&format!("https://github.com/{repo}/releases/"))?;
    if id.is_empty() || !id.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    Some(format!("https://api.github.com/repos/{repo}/releases/{id}"))
}
async fn resolve_release_notification(
    note: &mut Value,
    request: reqwest::RequestBuilder,
) -> WebResult<()> {
    let response = request.send().await?;
    if response.status() == StatusCode::NOT_FOUND {
        note["url"] = json!(format!(
            "https://github.com/{}/releases",
            note["repository"].as_str().unwrap()
        ));
        return Ok(());
    }
    let release: Value = checked(response).await?.json().await?;
    let url = release["html_url"]
        .as_str()
        .filter(|url| {
            url.starts_with(&format!(
                "https://github.com/{}/releases/",
                note["repository"].as_str().unwrap()
            ))
        })
        .ok_or_else(|| WebError::internal("Invalid release browser URL"))?;
    note["url"] = json!(url);
    Ok(())
}
fn notification_note(thread: &Value, baseline: bool, names: &[String]) -> Option<Value> {
    let repo = thread
        .pointer("/repository/full_name")?
        .as_str()?
        .to_lowercase();
    if !names.contains(&repo) {
        return None;
    }
    let updated = thread["updated_at"].as_str()?;
    let id = thread["id"].as_str()?;
    let subject = thread
        .pointer("/subject/url")
        .and_then(Value::as_str)
        .unwrap_or("");
    let suffix = subject
        .strip_prefix(&format!("https://api.github.com/repos/{repo}/"))
        .unwrap_or("");
    let suffix = suffix
        .replacen("pulls/", "pull/", 1)
        .replacen("commits/", "commit/", 1);
    Some(
        json!({"id":format!("{id}:{updated}"),"repository":repo,"title":thread.pointer("/subject/title")?.as_str()?,
        "body":format!("{} · {}",repo,thread["reason"].as_str().unwrap_or("notification").replace('_'," ")),
        "url":format!("https://github.com/{repo}/{suffix}"),"alert":!baseline}),
    )
}
async fn refresh_notifications(
    state: &AppState,
    device: Uuid,
    names: &[String],
    work: &[Uuid],
) -> WebResult<Option<u64>> {
    let row = sqlx::query("SELECT user_id,initialized,CASE WHEN EXISTS(SELECT 1 FROM notifications WHERE device=$1 AND json_extract(note, '$.unread') IS NULL) THEN NULL ELSE last_modified END AS last_modified FROM devices WHERE id=$1")
        .bind(device)
        .fetch_one(&state.db)
        .await?;
    let user: i64 = row.get("user_id");
    sqlx::query("INSERT INTO inbox_limits(user_id) VALUES($1) ON CONFLICT DO NOTHING")
        .bind(user)
        .execute(&state.db)
        .await?;
    let next: Option<i64> =
        sqlx::query_scalar("SELECT next_poll_at FROM inbox_limits WHERE user_id=$1")
            .bind(user)
            .fetch_one(&state.db)
            .await?;
    if let Some(next) = next {
        let seconds = next - Utc::now().timestamp();
        if seconds >= 0 {
            return Ok(Some(seconds as u64 + 1));
        }
    }
    sqlx::query("UPDATE inbox_limits SET next_poll_at=unixepoch()+60 WHERE user_id=$1")
        .bind(user)
        .execute(&state.db)
        .await?;
    let credential = token(state, device, "inbox").await?;
    let baseline = !row.get::<bool, _>("initialized");
    let modified: Option<String> = row.get("last_modified");
    let mut threads = Vec::new();
    let mut last_modified = None;
    let mut unchanged = false;
    for page in 1.. {
        let mut request = state
            .http
            .get("https://api.github.com/notifications")
            .bearer_auth(&credential)
            .query(&[("per_page", 100), ("page", page)]);
        if page == 1
            && let Some(value) = &modified
        {
            request = request.header(header::IF_MODIFIED_SINCE, value);
        }
        let response = match checked(request.send().await?).await {
            Ok(response) => response,
            Err(error) => {
                sqlx::query("UPDATE inbox_limits SET next_poll_at=unixepoch()+$2 WHERE user_id=$1")
                    .bind(user)
                    .bind(error.2.unwrap_or(60).min(i64::MAX as u64) as i64)
                    .execute(&state.db)
                    .await?;
                return Err(error);
            }
        };
        let interval = response
            .headers()
            .get("x-poll-interval")
            .and_then(|v| v.to_str().ok())
            .and_then(|v| v.parse::<i64>().ok())
            .unwrap_or(60)
            .max(1);
        // Persist the throttle even when a later page or decode fails.
        sqlx::query("UPDATE inbox_limits SET next_poll_at=unixepoch()+$2 WHERE user_id=$1")
            .bind(user)
            .bind(interval)
            .execute(&state.db)
            .await?;
        if page == 1 {
            last_modified = response
                .headers()
                .get(header::LAST_MODIFIED)
                .and_then(|v| v.to_str().ok())
                .map(str::to_owned);
        }
        if response.status() == StatusCode::NOT_MODIFIED {
            unchanged = true;
            break;
        }
        let items: Vec<Value> = response.json().await?;
        let done = items.len() < 100;
        threads.extend(items);
        if done {
            break;
        }
    }
    let mut tx = state.db.begin().await?;
    let mut inserted = false;
    for thread in &threads {
        if let Some(note) = notification_note(thread, baseline, names) {
            let updated = thread["updated_at"]
                .as_str()
                .and_then(|s| s.parse::<DateTime<Utc>>().ok())
                .ok_or_else(|| WebError::internal("Invalid notification timestamp"))?;
            let result = sqlx::query("INSERT INTO notifications(device,id,repository,updated_at,note) VALUES($1,$2,$3,$4,$5) ON CONFLICT(device,id) DO NOTHING")
                .bind(device).bind(note["id"].as_str()).bind(note["repository"].as_str()).bind(updated.timestamp()).bind(&note).execute(&mut *tx).await?;
            inserted = inserted || result.rows_affected() > 0;
        }
    }
    if !unchanged {
        let unread_ids = threads
            .iter()
            .filter(|thread| thread["unread"].as_bool() == Some(true))
            .filter_map(|thread| notification_note(thread, baseline, names))
            .filter_map(|note| note["id"].as_str().map(str::to_owned))
            .collect::<Vec<_>>();
        update_unread_notifications(&mut tx, device, &unread_ids).await?;
    }
    sqlx::query(
        "UPDATE devices SET initialized=true,last_modified=COALESCE($2,last_modified) WHERE id=$1",
    )
    .bind(device)
    .bind(last_modified)
    .execute(&mut *tx)
    .await?;
    let retry = finish_notification_work(&mut tx, device, work, baseline || inserted).await?;
    tx.commit().await?;
    if retry {
        let next: Option<i64> =
            sqlx::query_scalar("SELECT next_poll_at FROM inbox_limits WHERE user_id=$1")
                .bind(user)
                .fetch_one(&state.db)
                .await?;
        return Ok(Some(
            next.map(|t| (t - Utc::now().timestamp()).max(1) as u64 + 1)
                .unwrap_or(60),
        ));
    }
    Ok(None)
}
// Update only after every inbox page succeeds; history and banner deduplication remain intact.
async fn update_unread_notifications(
    tx: &mut sqlx::SqliteConnection,
    device: Uuid,
    unread_ids: &[String],
) -> Result<(), sqlx::Error> {
    sqlx::query("UPDATE notifications SET note=json_set(note, '$.unread', json(CASE WHEN id IN (SELECT value FROM json_each($2)) THEN 'true' ELSE 'false' END)) WHERE device=$1")
        .bind(device).bind(json!(unread_ids)).execute(tx).await?;
    Ok(())
}
// A webhook may precede inbox indexing. Retry an empty result once, without an idle poll loop.
async fn finish_notification_work(
    tx: &mut sqlx::SqliteConnection,
    device: Uuid,
    work: &[Uuid],
    complete: bool,
) -> WebResult<bool> {
    let mut retry = false;
    for id in work {
        sqlx::query("DELETE FROM pending WHERE device=$1 AND id=$2 AND (attempts>=1 OR $3)")
            .bind(device)
            .bind(id)
            .bind(complete)
            .execute(&mut *tx)
            .await?;
        retry |= sqlx::query("UPDATE pending SET attempts=attempts+1 WHERE device=$1 AND id=$2")
            .bind(device)
            .bind(id)
            .execute(&mut *tx)
            .await?
            .rows_affected()
            > 0;
    }
    Ok(retry)
}

fn event_work(event: &str, payload: &Value) -> Vec<&'static str> {
    let mut work = Vec::new();
    if (event == "push"
        && payload["ref"].as_str().is_some_and(|s| {
            s.starts_with("refs/heads/")
                || (s.starts_with("refs/tags/") && payload["deleted"] != true)
        }))
        || (["create", "delete"].contains(&event) && payload["ref_type"] == "branch")
        || (event == "create" && payload["ref_type"] == "tag")
    {
        work.push("fetch");
    }
    if ["star", "watch", "issues", "pull_request"].contains(&event) {
        work.push("counts");
    }
    if event_may_create_github_notification(event) {
        work.push("notifications");
    }
    work
}
async fn webhook(
    State(state): State<AppState>,
    headers: HeaderMap,
    body: Bytes,
) -> WebResult<StatusCode> {
    verify_webhook(&state.config.webhook_secret, &headers, &body)?;
    let event = required_header(&headers, "x-github-event")?;
    let delivery = required_header(&headers, "x-github-delivery")?;
    let payload: Value =
        serde_json::from_slice(&body).map_err(|_| WebError::bad_request("Invalid JSON"))?;
    let mut tx = state.db.begin().await?;
    let inserted = sqlx::query("INSERT INTO deliveries(id) VALUES($1) ON CONFLICT DO NOTHING")
        .bind(delivery)
        .execute(&mut *tx)
        .await?
        .rows_affected()
        > 0;
    if !inserted {
        return Ok(StatusCode::OK);
    }
    let merge = merged_work(&event, &payload);
    let installation = payload.pointer("/installation/id").and_then(Value::as_i64);
    let mut devices = Vec::new();
    if event == "installation" || event == "installation_repositories" {
        devices = sqlx::query_scalar::<_, Uuid>(
            "SELECT DISTINCT device FROM tracked WHERE installation_id=$1",
        )
        .bind(installation)
        .fetch_all(&mut *tx)
        .await?;
        if ["deleted", "suspend"].contains(&payload["action"].as_str().unwrap_or("")) {
            sqlx::query("DELETE FROM tracked WHERE installation_id=$1")
                .bind(installation)
                .execute(&mut *tx)
                .await?;
        }
        if let Some(removed) = payload["repositories_removed"].as_array() {
            for repo in removed {
                sqlx::query("DELETE FROM tracked WHERE installation_id=$1 AND repository_id=$2")
                    .bind(installation)
                    .bind(repo["id"].as_i64())
                    .execute(&mut *tx)
                    .await?;
            }
        }
        // A lifecycle wake causes the client to revalidate its complete requested repository set.
    } else if let Some(repo_id) = payload.pointer("/repository/id").and_then(Value::as_i64) {
        let tracked = sqlx::query(
            "SELECT device,repository FROM tracked WHERE installation_id=$1 AND repository_id=$2",
        )
        .bind(installation)
        .bind(repo_id)
        .fetch_all(&mut *tx)
        .await?;
        for row in tracked {
            let device: Uuid = row.get("device");
            let repo: String = row.get("repository");
            let work = event_work(&event, &payload);
            if let Some(merge) = &merge {
                if merge.repository == repo {
                    queue_merge(&mut tx, device, merge).await?;
                }
            }
            if !work.is_empty() || merge.is_some() {
                devices.push(device);
            }
            for kind in work {
                sqlx::query("INSERT INTO pending(device,repository,kind,id) VALUES($1,$2,$3,$4) ON CONFLICT(device,repository,kind) DO UPDATE SET id=EXCLUDED.id,attempts=0")
                    .bind(device).bind(&repo).bind(kind).bind(Uuid::new_v4()).execute(&mut *tx).await?;
            }
        }
    }
    tx.commit().await?;
    for device in devices {
        if let Some(row) =
            sqlx::query("SELECT token,environment FROM devices WHERE id=$1 AND token IS NOT NULL")
                .bind(device)
                .fetch_optional(&state.db)
                .await?
        {
            send_apns(
                &state,
                row.get("token"),
                row.get("environment"),
                "background",
                Some("github-work"),
                json!({"aps":{"content-available":1},"gitinuumWork":true}),
            )
            .await;
        }
    }
    Ok(StatusCode::OK)
}

fn verify_webhook(secret: &str, headers: &HeaderMap, body: &[u8]) -> WebResult<()> {
    let supplied = required_header(headers, "x-hub-signature-256")?;
    let signature = supplied
        .strip_prefix("sha256=")
        .ok_or_else(WebError::unauthorized)?;
    let bytes = hex::decode(signature).map_err(|_| WebError::unauthorized())?;
    let mut mac = HmacSha256::new_from_slice(secret.as_bytes()).map_err(WebError::internal)?;
    mac.update(body);
    mac.verify_slice(&bytes)
        .map_err(|_| WebError::unauthorized())
}

fn required_header(headers: &HeaderMap, name: &'static str) -> WebResult<String> {
    headers
        .get(name)
        .and_then(|x| x.to_str().ok())
        .map(str::to_owned)
        .ok_or_else(|| WebError::bad_request(format!("Missing {name}")))
}

fn event_may_create_github_notification(event_type: &str) -> bool {
    matches!(
        event_type,
        "issues"
            | "issue_comment"
            | "pull_request"
            | "pull_request_review"
            | "pull_request_review_comment"
            | "release"
            | "workflow_run"
            | "check_run"
            | "check_suite"
            | "deployment_status"
            | "dependabot_alert"
    )
}

#[derive(Serialize)]
struct ApnsClaims<'a> {
    iss: &'a str,
    iat: i64,
}

async fn send_apns(
    state: &AppState,
    device_token: &str,
    environment: &str,
    push_type: &str,
    collapse_id: Option<&str>,
    payload: Value,
) {
    let (host, credentials) = if environment == "sandbox" {
        ("api.sandbox.push.apple.com", &state.config.apns_sandbox)
    } else {
        ("api.push.apple.com", &state.config.apns_production)
    };
    let mut jwt_header = Header::new(Algorithm::ES256);
    jwt_header.kid = Some(credentials.key_id.clone());
    let jwt = match encode(
        &jwt_header,
        &ApnsClaims {
            iss: &state.config.apns_team_id,
            iat: Utc::now().timestamp(),
        },
        &credentials.key,
    ) {
        Ok(jwt) => jwt,
        Err(error) => {
            error!(%error, "failed to create APNs token");
            return;
        }
    };
    let mut request = state
        .http
        .post(format!("https://{host}/3/device/{device_token}"))
        .bearer_auth(jwt)
        .header("apns-topic", &state.config.apns_topic)
        .header("apns-push-type", push_type)
        .header(
            "apns-priority",
            if push_type == "background" { "5" } else { "10" },
        )
        .json(&payload);
    if let Some(id) = collapse_id {
        request = request.header("apns-collapse-id", id);
    }
    match request.send().await {
        Ok(response) if response.status().is_success() => {}
        Ok(response) => warn!(status=%response.status(), "APNs rejected notification"),
        Err(error) => warn!(%error, "APNs request failed"),
    }
}

#[cfg(test)]
mod tests;
