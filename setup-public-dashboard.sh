#!/usr/bin/env bash
# Publishes the Grafana public dashboard at https://noc.touseefahmed.com without touching other sites.
# Run as your normal user; uses sudo for nginx, certbot and docker.
set -eu
cd "$(dirname "$0")"
DOMAIN=noc.touseefahmed.com
SERVER_IP=89.167.80.146

ip=$(getent hosts "$DOMAIN" | awk '{print $1}' | head -1)
if [ "$ip" != "$SERVER_IP" ]; then
  echo "DNS for $DOMAIN is '${ip:-not visible yet}', expected $SERVER_IP. Add or wait for the A record, then run again."
  exit 1
fi
echo "DNS ok: $DOMAIN -> $ip"

# 1. Grafana learns its public address (local access through the tunnel keeps working)
if ! grep -q GF_SERVER_ROOT_URL monitoring/docker-compose.yml; then
  sed -i "s|      - GF_SERVER_HTTP_PORT=3300|&\n      - GF_SERVER_ROOT_URL=https://$DOMAIN/|" monitoring/docker-compose.yml
fi
sudo docker compose -f monitoring/docker-compose.yml up -d grafana > /dev/null 2>&1
echo "Grafana root URL set"

# 2. New nginx site, validated before reload
sudo cp monitoring/nginx-noc.conf /etc/nginx/sites-available/$DOMAIN
sudo ln -sf /etc/nginx/sites-available/$DOMAIN /etc/nginx/sites-enabled/$DOMAIN
if ! sudo nginx -t 2>/tmp/nginx-test.txt; then
  echo "nginx config test FAILED, removing the new site. Your existing sites are untouched."
  cat /tmp/nginx-test.txt
  sudo rm -f /etc/nginx/sites-enabled/$DOMAIN
  exit 1
fi
sudo systemctl reload nginx
echo "nginx: new site enabled and reloaded"

# 3. Certificate for this subdomain only, HTTP redirected to HTTPS
sudo certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos --redirect 2>&1 | grep -E "Successfully|Congratulations|deployed|error|Error" || true
sudo nginx -t > /dev/null 2>&1 && echo "nginx config still valid after certbot"
