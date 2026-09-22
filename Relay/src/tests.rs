use super::*;

#[test]
fn events_route_only_relevant_work() {
    assert_eq!(
        event_work("push", &json!({"ref":"refs/heads/main"})),
        vec!["fetch"]
    );
    assert!(event_work("push", &json!({"ref":"refs/tags/v1"})).is_empty());
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
        1
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
    sqlx::query("PRAGMA user_version=2").execute(&db).await?;
    db.close().await;
    drop(lock);
    assert!(open_database(&path).await.is_err());
    std::fs::remove_dir_all(directory)?;
    Ok(())
}
