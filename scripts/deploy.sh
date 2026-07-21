#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEPLOY_HOST="${DEPLOY_HOST:-atlas}"
REMOTE_ROOT="${REMOTE_ROOT:-/apps/vaultty-relay}"
RELAY_PORT="${RELAY_PORT:-3006}"
PUBLIC_HOSTNAME="${PUBLIC_HOSTNAME:-vaultty-relay.mxcl.dev}"
ATLAS_PUBLIC_IPS="${ATLAS_PUBLIC_IPS:-16.58.147.215 13.59.178.38}"
REVISION="$(git -C "$ROOT_DIR" rev-parse --short=12 HEAD)"
RELEASE_ID="${REVISION}-$(date -u +%Y%m%d%H%M%S)"
RELEASE_DIR="$REMOTE_ROOT/releases/$RELEASE_ID"

if [[ ! "$REMOTE_ROOT" =~ ^/apps/[a-zA-Z0-9._-]+$ ]]; then
  echo "REMOTE_ROOT must be a direct child of /apps" >&2
  exit 1
fi

if [[ ! "$RELAY_PORT" =~ ^[0-9]+$ ]] || (( RELAY_PORT < 1024 || RELAY_PORT > 65535 )); then
  echo "RELAY_PORT must be between 1024 and 65535" >&2
  exit 1
fi

if [[ ! "$PUBLIC_HOSTNAME" =~ ^[a-zA-Z0-9.-]+$ ]]; then
  echo "PUBLIC_HOSTNAME is not a valid hostname" >&2
  exit 1
fi

echo "Preparing $RELEASE_ID on $DEPLOY_HOST"
ssh "$DEPLOY_HOST" bash -s -- "$REMOTE_ROOT" "$RELEASE_DIR" <<'REMOTE_PREPARE'
set -euo pipefail
remote_root="$1"
release_dir="$2"
remote_user="$(id -un)"
remote_group="$(id -gn)"

sudo install -d -o "$remote_user" -g "$remote_group" "$remote_root" "$remote_root/releases"
install -d "$release_dir/source/src"
REMOTE_PREPARE

rsync -a \
  "$ROOT_DIR/Cargo.toml" \
  "$ROOT_DIR/Cargo.lock" \
  "$ROOT_DIR/build.rs" \
  "$DEPLOY_HOST:$RELEASE_DIR/source/"

rsync -a \
  "$ROOT_DIR/src/relay" \
  "$ROOT_DIR/src/sessiond" \
  "$ROOT_DIR/src/session_bridge" \
  "$DEPLOY_HOST:$RELEASE_DIR/source/src/"

echo "Building and activating $RELEASE_ID"
ssh "$DEPLOY_HOST" bash -s -- \
  "$REMOTE_ROOT" \
  "$RELEASE_DIR" \
  "$RELAY_PORT" \
  "$PUBLIC_HOSTNAME" \
  "$ATLAS_PUBLIC_IPS" <<'REMOTE_DEPLOY'
set -euo pipefail
remote_root="$1"
release_dir="$2"
relay_port="$3"
public_hostname="$4"
atlas_public_ips="$5"
service_name="vaultty-relay"
service_user="vaultty-relay"

cd "$release_dir/source"
cargo build --locked --release --bin vaultty-relay
sudo install -o root -g root -m 0755 \
  target/release/vaultty-relay \
  "$release_dir/vaultty-relay"

if ! id "$service_user" >/dev/null 2>&1; then
  sudo useradd \
    --system \
    --home-dir /var/lib/vaultty-relay \
    --shell /sbin/nologin \
    "$service_user"
fi
sudo install -d -o "$service_user" -g "$service_user" -m 0750 /var/lib/vaultty-relay

unit_file="$(mktemp)"
trap 'rm -f "$unit_file"' EXIT
cat >"$unit_file" <<UNIT
[Unit]
Description=Vaultty encrypted session relay
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$service_user
Group=$service_user
WorkingDirectory=$remote_root/current
Environment=VAULTTY_RELAY_BIND=127.0.0.1:$relay_port
Environment=VAULTTY_RELAY_DATA_DIR=/var/lib/vaultty-relay
ExecStart=$remote_root/current/vaultty-relay
Restart=always
RestartSec=3
NoNewPrivileges=true
PrivateDevices=true
PrivateTmp=true
ProtectHome=true
ProtectKernelModules=true
ProtectKernelTunables=true
ProtectSystem=strict
ReadWritePaths=/var/lib/vaultty-relay
RestrictSUIDSGID=true

[Install]
WantedBy=multi-user.target
UNIT
sudo install -o root -g root -m 0644 "$unit_file" "/etc/systemd/system/$service_name.service"

sudo ln -sfn "$release_dir" "$remote_root/current.next"
sudo mv -Tf "$remote_root/current.next" "$remote_root/current"
sudo systemctl daemon-reload
sudo systemctl enable "$service_name.service" >/dev/null
sudo systemctl restart "$service_name.service"

curl --fail --silent --show-error \
  --retry 10 \
  --retry-connrefused \
  --retry-delay 1 \
  "http://127.0.0.1:$relay_port/health" \
  --output /dev/null

dns_points_to_atlas=false
while read -r resolved_ip; do
  for atlas_ip in $atlas_public_ips; do
    if [[ "$resolved_ip" == "$atlas_ip" ]]; then
      dns_points_to_atlas=true
    fi
  done
done < <(getent ahostsv4 "$public_hostname" 2>/dev/null | awk '{print $1}' | sort -u)

if [[ "$dns_points_to_atlas" == true ]]; then
  nginx_file="$(mktemp)"
  cat >"$nginx_file" <<NGINX_HTTP
server {
    listen 80;
    listen [::]:80;
    server_name $public_hostname;

    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }

    location / {
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_pass http://127.0.0.1:$relay_port;
    }
}
NGINX_HTTP
  sudo install -o root -g root -m 0644 "$nginx_file" "/etc/nginx/conf.d/$service_name.conf"
  sudo nginx -t
  sudo systemctl reload nginx

  if [[ ! -f "/etc/letsencrypt/live/$public_hostname/fullchain.pem" ]]; then
    sudo certbot certonly \
      --webroot \
      --webroot-path /var/www/html \
      --domain "$public_hostname" \
      --non-interactive \
      --agree-tos
  fi

  cat >"$nginx_file" <<NGINX_HTTPS
server {
    listen 80;
    listen [::]:80;
    server_name $public_hostname;

    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    server_name $public_hostname;

    ssl_certificate /etc/letsencrypt/live/$public_hostname/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$public_hostname/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;

    location / {
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_pass http://127.0.0.1:$relay_port;
    }
}
NGINX_HTTPS
  sudo install -o root -g root -m 0644 "$nginx_file" "/etc/nginx/conf.d/$service_name.conf"
  rm -f "$nginx_file"
  sudo nginx -t
  sudo systemctl reload nginx
  curl --fail --silent --show-error \
    --retry 10 \
    --retry-all-errors \
    --retry-delay 1 \
    "https://$public_hostname/health" \
    --output /dev/null
  echo "Public relay healthy at https://$public_hostname"
else
  echo "Relay is healthy on 127.0.0.1:$relay_port." >&2
  echo "$public_hostname does not resolve to Atlas; nginx and TLS were not configured." >&2
fi

sudo systemctl --no-pager --full status "$service_name.service" | sed -n '1,12p'
REMOTE_DEPLOY

echo "Deployed $RELEASE_ID to $DEPLOY_HOST:$RELEASE_DIR"
