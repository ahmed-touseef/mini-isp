#!/usr/bin/env bash
# Phase 6a: NetBox (source of truth) via netbox-docker, reachable only on 127.0.0.1:8800.
# Generated secrets go to secrets/ (never committed) and are never printed.
# Run as your normal user; uses sudo for docker.
set -eu
REPO="$(cd "$(dirname "$0")" && pwd)"
NB="$HOME/netbox-docker"

avail=$(free -m | awk '/^Mem:/ {print $7}')
echo "Available RAM: ${avail} MB"
[ "$avail" -ge 2000 ] || { echo "Need at least 2000 MB free for NetBox. Stopping."; exit 1; }

[ -d "$NB" ] || git clone -q -b release --depth 1 https://github.com/netbox-community/netbox-docker.git "$NB"
cd "$NB"

cat > docker-compose.override.yml <<'YML'
services:
  netbox:
    ports:
      - "127.0.0.1:8800:8080"
YML

# Secrets: generated once, owner only
mkdir -p "$REPO/secrets"; chmod 700 "$REPO/secrets"
if [ ! -f "$REPO/secrets/netbox-db.txt" ]; then
  ( umask 077
    openssl rand -hex 16 > "$REPO/secrets/netbox-db.txt"
    openssl rand -hex 32 > "$REPO/secrets/netbox-secret-key.txt"
    openssl rand -hex 12 > "$REPO/secrets/netbox-admin.txt" )
fi
sed -i "s|^SECRET_KEY=.*|SECRET_KEY=$(cat "$REPO/secrets/netbox-secret-key.txt")|" env/netbox.env
sed -i "s|^DB_PASSWORD=.*|DB_PASSWORD=$(cat "$REPO/secrets/netbox-db.txt")|" env/netbox.env
sed -i "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=$(cat "$REPO/secrets/netbox-db.txt")|" env/postgres.env
chmod 600 env/*.env

echo "Pulling images..."
sudo docker compose pull -q
sudo docker compose up -d || echo "  (slow first start reported, waiting for health anyway)"

echo "Waiting for NetBox to become healthy (first start builds the database, a few minutes)..."
for i in $(seq 1 120); do
  cid=$(sudo docker compose ps -q netbox)
  st=$(sudo docker inspect -f '{{.State.Health.Status}}' "$cid" 2>/dev/null || echo starting)
  [ "$st" = healthy ] && { echo "  NetBox healthy after $((i*5))s"; break; }
  sleep 5
done

sudo docker compose up -d >/dev/null 2>&1 || true
# Admin user (password from secrets/, never shown)
sudo docker compose exec -T -e DJANGO_SUPERUSER_PASSWORD="$(cat "$REPO/secrets/netbox-admin.txt")" netbox \
  /opt/netbox/netbox/manage.py createsuperuser --noinput --username admin --email admin@mini-isp.lab >/dev/null 2>&1 \
  && echo "Admin user created" || echo "Admin user already exists"

echo "HTTP check on 127.0.0.1:8800: $(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8800/login/)"
sudo docker compose ps --format "table {{.Service}}\t{{.Status}}"
