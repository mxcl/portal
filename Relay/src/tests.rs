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
#[ignore = "Requires TEST_DATABASE_URL pointing to disposable PostgreSQL; creates an isolated schema"]
async fn durable_pending_work_and_deduplication() -> Result<()> {
    let admin = PgPool::connect(&required("TEST_DATABASE_URL")?).await?;
    let schema = format!("test_{}", Uuid::new_v4().simple());
    sqlx::query(sqlx::AssertSqlSafe(format!("CREATE SCHEMA {schema}")))
        .execute(&admin)
        .await?;
    let search = schema.clone();
    let db = PgPoolOptions::new()
        .after_connect(move |connection, _| {
            let sql = format!("SET search_path TO {search}");
            Box::pin(async move {
                sqlx::query(sqlx::AssertSqlSafe(sql))
                    .execute(connection)
                    .await?;
                Ok(())
            })
        })
        .connect(&required("TEST_DATABASE_URL")?)
        .await?;
    sqlx::raw_sql(include_str!("../schema.sql"))
        .execute(&db)
        .await?;
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
    sqlx::query("DELETE FROM pending WHERE device=$1 AND id=$2")
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
    sqlx::query(
        "INSERT INTO inbox_limits(user_id,next_poll_at) VALUES(42,now()+interval '1 hour')",
    )
    .execute(&db)
    .await?;
    assert_eq!(
        sqlx::query_scalar::<_, i64>("SELECT count(*) FROM pending")
            .fetch_one(&db)
            .await?,
        3
    );
    for _ in 0..2 {
        sqlx::query("INSERT INTO notifications(device,id,repository,updated_at,note) VALUES($1,'thread:updated','owner/repo',now(),'{}') ON CONFLICT DO NOTHING").bind(device).execute(&db).await?;
    }
    assert_eq!(
        sqlx::query_scalar::<_, i64>("SELECT count(*) FROM notifications")
            .fetch_one(&db)
            .await?,
        1
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
    sqlx::query(sqlx::AssertSqlSafe(format!("DROP SCHEMA {schema} CASCADE")))
        .execute(&admin)
        .await?;
    Ok(())
}
