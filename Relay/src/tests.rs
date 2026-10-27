use super::*;

#[test]
fn events_route_only_relevant_work() {
    assert_eq!(
        event_work("push", &json!({"ref":"refs/heads/main"})),
        vec!["fetch"]
    );
    assert_eq!(
        event_work("push", &json!({"ref":"refs/tags/v1"})),
        vec!["fetch"]
    );
    assert_eq!(
        event_work("create", &json!({"ref_type":"tag"})),
        vec!["fetch"]
    );
    assert!(event_work("push", &json!({"ref":"refs/tags/v1", "deleted":true})).is_empty());
    assert!(event_work("delete", &json!({"ref_type":"tag"})).is_empty());
    assert_eq!(
        event_work("create", &json!({"ref_type":"branch"})),
        vec!["fetch"]
    );
    assert_eq!(
        event_work("delete", &json!({"ref_type":"branch"})),
        vec!["fetch"]
    );
    assert_eq!(event_work("star", &json!({})), vec!["counts"]);
    assert_eq!(
        event_work("pull_request", &json!({})),
        vec!["counts", "notifications"]
    );
    assert_eq!(
        event_work("issues", &json!({})),
        vec!["counts", "notifications"]
    );
    assert_eq!(
        event_work("issue_comment", &json!({})),
        vec!["notifications"]
    );
    assert!(event_work("unknown", &json!({})).is_empty());
}

#[test]
fn separate_counts_and_notification_baseline() {
    assert_eq!(decode_counts(&json!({"data":{"repository":{"stargazerCount":10,"issues":{"totalCount":3},"pullRequests":{"totalCount":7}}}})).unwrap(),
        json!({"stars":10,"issues":3,"pullRequests":7}));
    assert!(decode_counts(&json!({"data":{"repository":null}})).is_err());
    let thread = json!({"id":"42","updated_at":"2026-09-22T12:00:00Z","repository":{"full_name":"owner/repo"},"reason":"review_requested",
        "subject":{"title":"Review","url":"https://api.github.com/repos/owner/repo/pulls/2"}});
    assert!(notification_note(&thread, false, &["someone/else".into()]).is_none());
    let baseline = notification_note(&thread, true, &["owner/repo".into()]).unwrap();
    let update = notification_note(&thread, false, &["owner/repo".into()]).unwrap();
    assert_eq!(baseline["alert"], false);
    assert_eq!(update["alert"], true);
    assert_eq!(baseline["id"], update["id"]);
    assert_eq!(update["url"], "https://github.com/owner/repo/pull/2");
    assert!(!valid_repository("../repo"));
    assert!(!valid_repository("owner/repo/escape"));
    assert!(valid_repository("owner/a-repo.name"));
}

#[tokio::test]
async fn release_notifications_use_browser_urls() {
    let thread = json!({"id":"42","updated_at":"2026-09-29T12:00:00Z",
        "repository":{"full_name":"automic-vault/automic-vault"},"reason":"subscribed",
        "subject":{"title":"Release title is not the tag","type":"Release",
            "url":"https://api.github.com/repos/automic-vault/automic-vault/releases/398703655"}});
    let mut note =
        notification_note(&thread, false, &["automic-vault/automic-vault".into()]).unwrap();
    assert_eq!(
        release_notification_api_url(&note).as_deref(),
        thread["subject"]["url"].as_str()
    );
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let server = tokio::spawn(async move {
        axum::serve(listener, Router::new().route("/release", get(|| async {
            Json(json!({"html_url":"https://github.com/automic-vault/automic-vault/releases/tag/4.13.0"}))
        })).route("/invalid", get(|| async {
            Json(json!({"html_url":"https://example.com/release"}))
        }))).await.unwrap();
    });
    let http = Client::new();
    let original = note.clone();
    assert!(
        resolve_release_notification(&mut note, http.get(format!("http://{address}/invalid")))
            .await
            .is_err()
    );
    assert_eq!(note, original);
    resolve_release_notification(&mut note, http.get(format!("http://{address}/release")))
        .await
        .unwrap();
    assert!(release_notification_api_url(&note).is_none());
    let mut unavailable = original.clone();
    resolve_release_notification(
        &mut unavailable,
        http.get(format!("http://{address}/missing")),
    )
    .await
    .unwrap();
    assert_eq!(
        unavailable["url"],
        "https://github.com/automic-vault/automic-vault/releases"
    );
    assert!(release_notification_api_url(&unavailable).is_none());
    assert_eq!(note["id"], original["id"]);
    assert_eq!(note["alert"], original["alert"]);
    server.abort();
    assert_eq!(
        note["url"],
        "https://github.com/automic-vault/automic-vault/releases/tag/4.13.0"
    );
}

#[test]
fn signatures_and_encrypted_credentials() {
    let mut version = HeaderMap::new();
    assert!(check_protocol(&version).is_err());
    version.insert("gitinuum-protocol", "99".parse().unwrap());
    assert!(check_protocol(&version).is_err());
    version.insert("gitinuum-protocol", "1".parse().unwrap());
    assert!(check_protocol(&version).is_ok());
    let body = b"test";
    let mut mac = HmacSha256::new_from_slice(b"secret").unwrap();
    mac.update(body);
    let mut headers = HeaderMap::new();
    headers.insert(
        "x-hub-signature-256",
        format!("sha256={}", hex::encode(mac.finalize().into_bytes()))
            .parse()
            .unwrap(),
    );
    assert!(verify_webhook("secret", &headers, body).is_ok());
    assert!(verify_webhook("wrong", &headers, body).is_err());
    let token = GitHubToken {
        access_token: "private".into(),
        refresh_token: None,
        expires_in: None,
        expires_at: None,
        scope: None,
    };
    let (encrypted, nonce) = encrypt(&[1; 32], &token).unwrap();
    assert_eq!(
        decrypt(&[1; 32], &encrypted, &nonce).unwrap().access_token,
        "private"
    );
    assert!(decrypt(&[2; 32], &encrypted, &nonce).is_err());
    assert!(decrypt(&[1; 32], &encrypted, &[0; 1]).is_err());
}

#[tokio::test]
async fn durable_pending_work_and_deduplication() -> Result<()> {
    let directory = env::temp_dir().join(format!("gitinuum-{}", Uuid::new_v4()));
    std::fs::create_dir(&directory)?;
    let path = directory.join("relay.sqlite3");
    let (db, lock) = open_database(&path).await?;
    assert!(open_database(&path).await.is_err());
    assert_eq!(
        sqlx::query_scalar::<_, String>("PRAGMA journal_mode")
            .fetch_one(&db)
            .await?,
        "wal"
    );
    assert_eq!(
        sqlx::query_scalar::<_, i64>("PRAGMA foreign_keys")
            .fetch_one(&db)
            .await?,
        1
    );
    assert_eq!(
        sqlx::query_scalar::<_, i64>("PRAGMA synchronous")
            .fetch_one(&db)
            .await?,
        2
    );
    let alias = directory.join("alias.sqlite3");
    std::os::unix::fs::symlink(&path, &alias)?;
    assert!(open_database(&alias).await.is_err());
    let device = Uuid::new_v4();
    sqlx::query("INSERT INTO devices(id) VALUES($1)")
        .bind(device)
        .execute(&db)
        .await?;
    sqlx::query("INSERT INTO tracked(device,repository,repository_id,installation_id) VALUES($1,'owner/repo',1,2)").bind(device).execute(&db).await?;
    queue(&db, device, "owner/repo", "fetch")
        .await
        .map_err(|e| anyhow::anyhow!(e.1))?;
    let old: Uuid = sqlx::query_scalar("SELECT id FROM pending")
        .fetch_one(&db)
        .await?;
    queue(&db, device, "owner/repo", "fetch")
        .await
        .map_err(|e| anyhow::anyhow!(e.1))?;
    queue(&db, device, "owner/repo", "counts")
        .await
        .map_err(|e| anyhow::anyhow!(e.1))?;
    sqlx::query("DELETE FROM pending WHERE device=$1 AND kind='fetch' AND id=$2")
        .bind(device)
        .bind(old)
        .execute(&db)
        .await?;
    assert_eq!(
        sqlx::query_scalar::<_, i64>("SELECT count(*) FROM pending")
            .fetch_one(&db)
            .await?,
        2
    );
    // A throttled inbox request must retain work; an acknowledgement from an earlier epoch cannot erase it.
    queue(&db, device, "owner/repo", "notifications")
        .await
        .map_err(|e| anyhow::anyhow!(e.1))?;
    sqlx::query("INSERT INTO inbox_limits(user_id,next_poll_at) VALUES(42,unixepoch()+3600)")
        .execute(&db)
        .await?;
    assert_eq!(
        sqlx::query_scalar::<_, i64>("SELECT count(*) FROM pending")
            .fetch_one(&db)
            .await?,
        3
    );
    for _ in 0..2 {
        sqlx::query("INSERT INTO notifications(device,id,repository,updated_at,note) VALUES($1,'thread:updated','owner/repo',unixepoch(),'{}') ON CONFLICT DO NOTHING").bind(device).execute(&db).await?;
    }
    assert_eq!(
        sqlx::query_scalar::<_, i64>("SELECT count(*) FROM notifications")
            .fetch_one(&db)
            .await?,
        1
    );
    assert_eq!(
        sqlx::query_scalar::<_, Value>("SELECT note FROM notifications")
            .fetch_one(&db)
            .await?,
        json!({})
    );
    sqlx::query("DELETE FROM tracked WHERE device=$1")
        .bind(device)
        .execute(&db)
        .await?;
    assert_eq!(
        sqlx::query_scalar::<_, i64>("SELECT count(*) FROM pending")
            .fetch_one(&db)
            .await?,
        0
    );
    db.close().await;
    drop(lock);
    let (db, lock) = open_database(&path).await?;
    assert_eq!(
        sqlx::query_scalar::<_, i64>("PRAGMA user_version")
            .fetch_one(&db)
            .await?,
        2
    );
    assert!(
        sqlx::query_scalar::<_, i64>("SELECT next_poll_at FROM inbox_limits WHERE user_id=42")
            .fetch_one(&db)
            .await?
            > Utc::now().timestamp()
    );
    assert_eq!(
        sqlx::query_scalar::<_, Uuid>("SELECT id FROM devices")
            .fetch_one(&db)
            .await?,
        device
    );
    db.close().await;
    drop(lock);
    std::fs::remove_dir_all(directory)?;
    Ok(())
}

#[tokio::test]
async fn sqlite_roundtrips_and_bounded_notification_work() -> Result<()> {
    let directory = env::temp_dir().join(format!("gitinuum-{}", Uuid::new_v4()));
    std::fs::create_dir(&directory)?;
    let path = directory.join("relay.sqlite3");
    let (db, lock) = open_database(&path).await?;
    let device = Uuid::new_v4();
    sqlx::query("INSERT INTO devices(id) VALUES($1)")
        .bind(device)
        .execute(&db)
        .await?;
    sqlx::query("UPDATE devices SET app_credentials=$2,app_nonce=$3 WHERE id=$1")
        .bind(device)
        .bind(vec![1u8, 2, 3])
        .bind(vec![4u8; 12])
        .execute(&db)
        .await?;
    assert_eq!(
        sqlx::query_scalar::<_, Vec<u8>>("SELECT app_credentials FROM devices")
            .fetch_one(&db)
            .await?,
        vec![1, 2, 3]
    );
    sqlx::query("INSERT INTO tracked(device,repository,repository_id,installation_id) VALUES($1,'owner/repo',1,2)")
        .bind(device).execute(&db).await?;
    let counts = json!({"stars":10,"issues":3,"pullRequests":7});
    sqlx::query("UPDATE tracked SET counts=$3 WHERE device=$1 AND repository=$2")
        .bind(device)
        .bind("owner/repo")
        .bind(&counts)
        .execute(&db)
        .await?;
    assert_eq!(
        sqlx::query_scalar::<_, Value>("SELECT counts FROM tracked")
            .fetch_one(&db)
            .await?,
        counts
    );
    let work = Uuid::new_v4();
    sqlx::query(
        "INSERT INTO pending(device,repository,kind,id) VALUES($1,'owner/repo','notifications',$2)",
    )
    .bind(device)
    .bind(work)
    .execute(&db)
    .await?;
    let mut tx = db.begin().await?;
    assert!(
        finish_notification_work(&mut tx, device, &[work], false)
            .await
            .map_err(|e| anyhow::anyhow!(e.1))?
    );
    tx.commit().await?;
    // The single retry survives restart.
    db.close().await;
    drop(lock);
    let (db, lock) = open_database(&path).await?;
    let mut tx = db.begin().await?;
    assert!(
        !finish_notification_work(&mut tx, device, &[work], false)
            .await
            .map_err(|e| anyhow::anyhow!(e.1))?
    );
    tx.commit().await?;
    assert_eq!(
        sqlx::query_scalar::<_, i64>("SELECT count(*) FROM pending")
            .fetch_one(&db)
            .await?,
        0
    );
    let names = vec!["owner/repo"];
    sqlx::query("DELETE FROM tracked WHERE device=$1 AND repository NOT IN (SELECT value FROM json_each($2))")
        .bind(device).bind(sqlx::types::Json(&names)).execute(&db).await?;
    assert_eq!(
        sqlx::query_scalar::<_, i64>("SELECT count(*) FROM tracked")
            .fetch_one(&db)
            .await?,
        1
    );
    let mut tx = db.begin().await?;
    sqlx::query("INSERT INTO deliveries(id) VALUES('rolled-back')")
        .execute(&mut *tx)
        .await?;
    tx.rollback().await?;
    assert_eq!(
        sqlx::query_scalar::<_, i64>("SELECT count(*) FROM deliveries")
            .fetch_one(&db)
            .await?,
        0
    );
    sqlx::query("UPDATE devices SET initialized=true WHERE id=$1")
        .bind(device)
        .execute(&db)
        .await?;
    assert!(
        sqlx::query_scalar::<_, bool>("SELECT initialized FROM devices")
            .fetch_one(&db)
            .await?
    );
    sqlx::query("DELETE FROM devices WHERE id=$1")
        .bind(device)
        .execute(&db)
        .await?;
    assert!(sqlx::query("INSERT INTO tracked(device,repository,repository_id,installation_id) VALUES($1,'owner/repo',1,2)")
        .bind(device).execute(&db).await.is_err());
    // Unknown schema versions must be preserved, never rebuilt.
    sqlx::query("PRAGMA user_version=99").execute(&db).await?;
    db.close().await;
    drop(lock);
    assert!(open_database(&path).await.is_err());
    std::fs::remove_dir_all(directory)?;
    Ok(())
}

#[tokio::test]
async fn unread_snapshot_preserves_history_and_device_isolation() -> Result<()> {
    let directory = env::temp_dir().join(format!("gitinuum-unread-{}", Uuid::new_v4()));
    std::fs::create_dir(&directory)?;
    let (db, lock) = open_database(&directory.join("relay.sqlite3")).await?;
    let device = Uuid::new_v4();
    let other = Uuid::new_v4();
    for id in [device, other] {
        sqlx::query("INSERT INTO devices(id) VALUES($1)")
            .bind(id)
            .execute(&db)
            .await?;
        for note in ["old", "new"] {
            sqlx::query("INSERT INTO notifications(device,id,repository,updated_at,note) VALUES($1,$2,'owner/repo',unixepoch(),$3)")
                .bind(id).bind(note).bind(json!({"id":note,"alert":false})).execute(&db).await?;
        }
    }
    let mut tx = db.begin().await?;
    update_unread_notifications(&mut tx, device, &["new".into()]).await?;
    tx.commit().await?;
    let notes: Vec<Value> =
        sqlx::query_scalar("SELECT note FROM notifications WHERE device=$1 ORDER BY id")
            .bind(device)
            .fetch_all(&db)
            .await?;
    assert_eq!(notes[0]["unread"], true);
    assert_eq!(notes[1]["unread"], false);
    assert_eq!(notes[0]["alert"], false); // Initial history still never banners.
    let untouched: Value =
        sqlx::query_scalar("SELECT note FROM notifications WHERE device=$1 LIMIT 1")
            .bind(other)
            .fetch_one(&db)
            .await?;
    assert!(untouched.get("unread").is_none());
    let mut tx = db.begin().await?;
    update_unread_notifications(&mut tx, device, &[]).await?;
    tx.rollback().await?; // Failed batches keep the last successful unread snapshot.
    assert_eq!(
        sqlx::query_scalar::<_, i64>(
            "SELECT count(*) FROM notifications WHERE device=$1 AND json_extract(note,'$.unread')=1"
        )
        .bind(device)
        .fetch_one(&db)
        .await?,
        1
    );
    let mut tx = db.begin().await?;
    update_unread_notifications(&mut tx, device, &[]).await?;
    tx.commit().await?;
    assert_eq!(
        sqlx::query_scalar::<_, i64>(
            "SELECT count(*) FROM notifications WHERE device=$1 AND json_extract(note,'$.unread')=1"
        )
        .bind(device)
        .fetch_one(&db)
        .await?,
        0
    );
    assert_eq!(
        sqlx::query_scalar::<_, i64>("SELECT count(*) FROM notifications WHERE device=$1")
            .bind(device)
            .fetch_one(&db)
            .await?,
        2
    );
    db.close().await;
    drop(lock);
    std::fs::remove_dir_all(directory)?;
    Ok(())
}

#[tokio::test]
async fn inbox_refresh_only_queues_notifications_and_preserves_throttle() -> Result<()> {
    let directory = env::temp_dir().join(format!("gitinuum-{}", Uuid::new_v4()));
    std::fs::create_dir(&directory)?;
    let (db, lock) = open_database(&directory.join("relay.sqlite3")).await?;
    let device = Uuid::new_v4();
    sqlx::query("INSERT INTO devices(id,user_id,last_modified) VALUES($1,42,'cached')")
        .bind(device)
        .execute(&db)
        .await?;
    sqlx::query("INSERT INTO tracked(device,repository,repository_id,installation_id) VALUES($1,'owner/repo',1,2)")
        .bind(device).execute(&db).await?;
    sqlx::query("INSERT INTO inbox_limits(user_id,next_poll_at) VALUES(42,9999999999)")
        .execute(&db)
        .await?;
    for _ in 0..2 {
        queue_inbox_refresh(&db, device, &["owner/repo".into()])
            .await
            .map_err(|e| anyhow::anyhow!(e.1))?;
    }
    assert_eq!(
        sqlx::query_scalar::<_, String>("SELECT kind FROM pending")
            .fetch_all(&db)
            .await?,
        vec!["notifications"]
    );
    assert_eq!(
        sqlx::query_scalar::<_, Option<String>>("SELECT last_modified FROM devices")
            .fetch_one(&db)
            .await?,
        None
    );
    assert_eq!(
        sqlx::query_scalar::<_, i64>("SELECT next_poll_at FROM inbox_limits")
            .fetch_one(&db)
            .await?,
        9999999999
    );
    let pending_id: Uuid = sqlx::query_scalar("SELECT id FROM pending")
        .fetch_one(&db)
        .await?;
    sqlx::query("UPDATE pending SET attempts=0")
        .execute(&db)
        .await?;
    queue_inbox_refresh(&db, device, &["owner/repo".into()])
        .await
        .map_err(|e| anyhow::anyhow!(e.1))?;
    assert_eq!(
        sqlx::query_scalar::<_, Uuid>("SELECT id FROM pending")
            .fetch_one(&db)
            .await?,
        pending_id
    );
    assert_eq!(
        sqlx::query_scalar::<_, i64>("SELECT attempts FROM pending")
            .fetch_one(&db)
            .await?,
        0
    );
    let legacy: SyncInput =
        serde_json::from_value(json!({"repositories":[],"environment":"production"}))?;
    assert!(!legacy.refresh_inbox);
    let inbox: SyncInput = serde_json::from_value(
        json!({"repositories":[],"environment":"production","refreshInbox":true}),
    )?;
    assert!(inbox.refresh_inbox);
    assert!(!inbox.catch_up);
    db.close().await;
    drop(lock);
    std::fs::remove_dir_all(directory)?;
    Ok(())
}

fn merged_payload() -> Value {
    json!({"action":"closed","number":7,"repository":{"full_name":"owner/repo"},
        "pull_request":{"merged":true,"merged_at":"2026-09-27T12:00:00Z",
        "head":{"ref":"topic","sha":"1234567890123456789012345678901234567890",
        "repo":{"full_name":"fork/repo","default_branch":"main"}},"base":{"ref":"main"}}})
}

#[test]
fn only_verified_merge_shapes_produce_cleanup() {
    let payload = merged_payload();
    let work = merged_work("pull_request", &payload).unwrap();
    assert_eq!(work.source_repository, "fork/repo");
    assert_eq!(work.branch, "topic");
    assert_eq!(work.oid, payload["pull_request"]["head"]["sha"]);
    assert!(merged_work("push", &payload).is_none());
    for (field, value) in [
        ("merged", json!(false)),
        ("merged_at", Value::Null),
        ("head", Value::Null),
    ] {
        let mut invalid = payload.clone();
        invalid["pull_request"][field] = value;
        assert!(merged_work("pull_request", &invalid).is_none());
    }
    let mut reopened = payload;
    reopened["action"] = json!("reopened");
    assert!(merged_work("pull_request", &reopened).is_none());
}

#[tokio::test]
async fn merge_queue_migrates_and_retains_independent_idempotent_work() -> Result<()> {
    let directory = env::temp_dir().join(format!("gitinuum-merges-{}", Uuid::new_v4()));
    std::fs::create_dir(&directory)?;
    let path = directory.join("relay.sqlite3");
    let legacy = SqlitePoolOptions::new()
        .max_connections(1)
        .connect_with(
            SqliteConnectOptions::new()
                .filename(&path)
                .create_if_missing(true),
        )
        .await?;
    sqlx::raw_sql(include_str!("../schema.sql"))
        .execute(&legacy)
        .await?;
    sqlx::query("PRAGMA user_version=1")
        .execute(&legacy)
        .await?;
    let device = Uuid::new_v4();
    sqlx::query("INSERT INTO devices(id) VALUES($1)")
        .bind(device)
        .execute(&legacy)
        .await?;
    sqlx::query("INSERT INTO tracked(device,repository,repository_id,installation_id) VALUES($1,'owner/repo',1,2)")
        .bind(device).execute(&legacy).await?;
    legacy.close().await;
    let (db, lock) = open_database(&path).await?;
    let first = merged_work("pull_request", &merged_payload()).unwrap();
    let mut second = first.clone();
    second.id = Uuid::new_v4();
    second.pull_request += 1;
    let mut tx = db.begin().await?;
    queue_merge(&mut tx, device, &first).await?;
    queue_merge(&mut tx, device, &second).await?;
    let mut duplicate = first.clone();
    duplicate.id = Uuid::new_v4();
    queue_merge(&mut tx, device, &duplicate).await?;
    tx.commit().await?;
    db.close().await;
    drop(lock);
    let (db, lock) = open_database(&path).await?;
    assert_eq!(
        sqlx::query_scalar::<_, i64>("SELECT count(*) FROM merged_work WHERE completed=0")
            .fetch_one(&db)
            .await?,
        2
    );
    assert_eq!(
        sqlx::query_scalar::<_, Value>("SELECT record FROM merged_work WHERE id=$1")
            .bind(first.id)
            .fetch_one(&db)
            .await?["sourceRepository"],
        "fork/repo"
    );
    // Wrong-device and stale acknowledgements do not consume work.
    sqlx::query("UPDATE merged_work SET completed=1 WHERE device=$1 AND id=$2")
        .bind(Uuid::new_v4())
        .bind(first.id)
        .execute(&db)
        .await?;
    sqlx::query("UPDATE merged_work SET completed=1 WHERE device=$1 AND id=$2")
        .bind(device)
        .bind(duplicate.id)
        .execute(&db)
        .await?;
    assert_eq!(
        sqlx::query_scalar::<_, i64>("SELECT count(*) FROM merged_work WHERE completed=0")
            .fetch_one(&db)
            .await?,
        2
    );
    sqlx::query("UPDATE merged_work SET completed=1 WHERE device=$1 AND id=$2")
        .bind(device)
        .bind(first.id)
        .execute(&db)
        .await?;
    let mut tx = db.begin().await?;
    queue_merge(&mut tx, device, &duplicate).await?;
    tx.commit().await?;
    assert_eq!(
        sqlx::query_scalar::<_, i64>("SELECT count(*) FROM merged_work WHERE completed=0")
            .fetch_one(&db)
            .await?,
        1
    );
    db.close().await;
    drop(lock);
    std::fs::remove_dir_all(directory)?;
    Ok(())
}

#[test]
fn portal_protocol_supports_legacy_and_rejects_incompatible_versions() {
    let mut headers = HeaderMap::new();
    assert!(check_protocol(&headers).is_err());
    headers.insert("gitinuum-protocol", "1".parse().unwrap());
    assert!(check_protocol(&headers).is_ok());
    headers.insert("portal-protocol", "2".parse().unwrap());
    assert!(check_protocol(&headers).is_err());
    headers.insert("portal-protocol", "1".parse().unwrap());
    assert!(check_protocol(&headers).is_ok());
}

fn test_apns_credentials() -> ApnsCredentials {
    ApnsCredentials {
        provider_token: Mutex::new(None),
        key_id: "test-key".into(),
        key: EncodingKey::from_ec_pem(include_bytes!("../test-fixtures/apns-test.p8")).unwrap(),
    }
}

#[test]
fn apns_reuses_provider_token_and_refreshes_after_fifty_minutes() {
    let credentials = test_apns_credentials();
    let first = credentials.provider_token("test-team", 10_000).unwrap();
    for now in [10_001, 11_200, 12_999] {
        assert_eq!(credentials.provider_token("test-team", now).unwrap(), first);
    }
    let refreshed = credentials.provider_token("test-team", 13_000).unwrap();
    assert_ne!(refreshed, first);
    assert_eq!(
        credentials.provider_token("test-team", 13_001).unwrap(),
        refreshed
    );
}

#[test]
fn apns_concurrent_pushes_share_token_and_credentials_have_separate_caches() {
    let production = test_apns_credentials();
    let tokens = std::thread::scope(|scope| {
        let handles: Vec<_> = (0..16)
            .map(|_| {
                let credentials = &production;
                scope.spawn(move || credentials.provider_token("test-team", 10_000).unwrap())
            })
            .collect();
        handles
            .into_iter()
            .map(|handle| handle.join().unwrap())
            .collect::<Vec<_>>()
    });
    assert!(tokens.iter().all(|token| token == &tokens[0]));
    let sandbox = test_apns_credentials();
    assert!(sandbox.provider_token.lock().unwrap().is_none());
    let sandbox_token = sandbox.provider_token("test-team", 20_000).unwrap();
    assert_ne!(sandbox_token, tokens[0]);
    assert_eq!(
        production.provider_token("test-team", 10_100).unwrap(),
        tokens[0]
    );
}
