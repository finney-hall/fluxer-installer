#!/usr/bin/env bash
# Fluxer Self-Hosting Installer
# One-shot, non-interactive installer for a fresh Ubuntu 24.04 VPS.
# Usage: bash install.sh --domain chat.example.com --email admin@example.com

set -euo pipefail

# ───────────────────────────── arguments ─────────────────────────────
DOMAIN=""
EMAIL=""
FLUXER_BRANCH="main"
SERVER_IP=""
SKIP_UPGRADE=false
CLEAN=false
SKIP_FIREWALL=false

print_help() {
  cat <<'EOF'
Fluxer Self-Hosting Installer

Usage: bash install.sh [options]

Required:
  --domain DOMAIN         Public FQDN with A-record pointing to this server.
  --email EMAIL           Contact email for VAPID (web-push) registration.

Optional:
  --branch BRANCH         fluxerapp/fluxer branch for deploy templates (default: main).
  --server-ip IP          Override auto-detected public IP for LiveKit node_ip.
  --skip-upgrade          Skip the apt full upgrade pass.
  --skip-firewall         Skip ufw rules (useful if the provider firewall handles it).
  --clean                 Tear down existing /opt/fluxer before installing.
  -h, --help              Show this help.

Example:
  bash install.sh --domain chat.example.com --email admin@example.com
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --domain)        DOMAIN="$2"; shift 2 ;;
    --email)         EMAIL="$2"; shift 2 ;;
    --branch)        FLUXER_BRANCH="$2"; shift 2 ;;
    --server-ip)     SERVER_IP="$2"; shift 2 ;;
    --skip-upgrade)  SKIP_UPGRADE=true; shift ;;
    --skip-firewall) SKIP_FIREWALL=true; shift ;;
    --clean)         CLEAN=true; shift ;;
    -h|--help)       print_help; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; print_help; exit 64 ;;
  esac
done

# ───────────────────────────── pre-flight ─────────────────────────────
log()  { printf '\033[1;36m[%(%H:%M:%S)T]\033[0m %s\n' -1 "$*"; }
warn() { printf '\033[1;33m[%(%H:%M:%S)T] WARN:\033[0m %s\n' -1 "$*"; }
die()  { printf '\033[1;31m[%(%H:%M:%S)T] FATAL:\033[0m %s\n' -1 "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ]               || die "must run as root"
[ -n "$DOMAIN" ]                   || die "--domain is required"
[ -n "$EMAIL"  ]                   || die "--email is required"
[[ "$DOMAIN" =~ ^[a-zA-Z0-9.-]+$ ]] || die "invalid domain: $DOMAIN"
[[ "$EMAIL"  =~ ^[^@[:space:]]+@[^@[:space:]]+$ ]] || die "invalid email: $EMAIL"
. /etc/os-release
[ "$ID" = "ubuntu" ]               || warn "tested on Ubuntu only; you have $PRETTY_NAME"

if [ -z "$SERVER_IP" ]; then
  SERVER_IP=$(ip -4 -o addr show scope global 2>/dev/null \
              | awk '{print $4}' | cut -d/ -f1 | head -1)
  [ -n "$SERVER_IP" ] || die "could not auto-detect public IP; use --server-ip"
fi

log "domain     : $DOMAIN"
log "email      : $EMAIL"
log "server IP  : $SERVER_IP"
log "branch     : $FLUXER_BRANCH"

# ───────────────────── force non-interactive apt + needrestart ─────────────────────
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export UCF_FORCE_CONFOLD=1
APT_FLAGS=(-y -o 'Dpkg::Options::=--force-confdef' -o 'Dpkg::Options::=--force-confold')

# Quiet down needrestart if it is installed (prevents interactive prompts).
if [ -f /etc/needrestart/needrestart.conf ]; then
  sed -i "s/^#\?\\\$nrconf{restart}.*/\$nrconf{restart} = 'a';/" \
    /etc/needrestart/needrestart.conf || true
fi

# ───────────────────── 1. base system ─────────────────────
log "apt update"
apt-get update -qq

if [ "$SKIP_UPGRADE" = false ]; then
  log "apt upgrade (non-interactive)"
  apt-get "${APT_FLAGS[@]}" -qq upgrade
fi

log "installing base packages"
apt-get "${APT_FLAGS[@]}" -qq install \
  ca-certificates curl gnupg ufw fail2ban unattended-upgrades jq

systemctl enable --now fail2ban >/dev/null

# ───────────────────── 2. firewall ─────────────────────
if [ "$SKIP_FIREWALL" = false ]; then
  log "configuring ufw"
  ufw default deny incoming  >/dev/null
  ufw default allow outgoing >/dev/null
  for rule in 22/tcp 80/tcp 443/tcp 7881/tcp 7882/udp; do
    ufw allow "$rule" >/dev/null
  done
  ufw --force enable >/dev/null
  ufw status verbose
fi

# ───────────────────── 3. docker ─────────────────────
if ! command -v docker >/dev/null 2>&1; then
  log "installing docker engine"
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc

  echo "deb [arch=$(dpkg --print-architecture) \
signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/ubuntu $VERSION_CODENAME stable" \
    > /etc/apt/sources.list.d/docker.list

  apt-get update -qq
  apt-get "${APT_FLAGS[@]}" -qq install \
    docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin
else
  log "docker already installed: $(docker --version)"
fi

# ───────────────────── 4. tear down old install if --clean ─────────────────────
if [ "$CLEAN" = true ] && [ -d /opt/fluxer ]; then
  log "--clean: tearing down /opt/fluxer"
  ( cd /opt/fluxer && docker compose down -v 2>/dev/null ) || true
  rm -rf /opt/fluxer
fi

# ───────────────────── 5. fetch Fluxer stack ─────────────────────
mkdir -p /opt/fluxer
cd /opt/fluxer

base="https://raw.githubusercontent.com/fluxerapp/fluxer/${FLUXER_BRANCH}/deploy/self-hosting"
log "downloading Fluxer deploy templates from $base"
for f in docker-compose.yml Caddyfile livekit.yaml; do
  if [ ! -f "$f" ]; then
    curl -fsSLO "${base}/${f}"
  fi
done
[ -f .env ] || curl -fsSL "${base}/.env.example" -o .env
chmod 600 .env

# ───────────────────── 6. .env public fields ─────────────────────
log "writing public .env fields"
sed -i \
  -e "s|^FLUXER_DOMAIN=.*|FLUXER_DOMAIN=$DOMAIN|" \
  -e "s|^FLUXER_PUBLIC_SCHEME=.*|FLUXER_PUBLIC_SCHEME=https|" \
  -e "s|^FLUXER_PUBLIC_PORT=.*|FLUXER_PUBLIC_PORT=443|" \
  -e "s|^FLUXER_CADDY_SITE_ADDRESS=.*|FLUXER_CADDY_SITE_ADDRESS=$DOMAIN|" \
  -e "s|^FLUXER_VAPID_EMAIL=.*|FLUXER_VAPID_EMAIL=$EMAIL|" \
  -e "s|^FLUXER_EMAIL_ENABLED=.*|FLUXER_EMAIL_ENABLED=false|" \
  -e "s|^FLUXER_EMAIL_PROVIDER=.*|FLUXER_EMAIL_PROVIDER=none|" \
  .env

# ───────────────────── 7. hex secrets (idempotent) ─────────────────────
log "generating hex-32 secrets where placeholders remain"
hex_keys=(
  POSTGRES_PASSWORD
  MEILI_MASTER_KEY
  FLUXER_S3_SECRET_KEY
  FLUXER_SUDO_MODE_SECRET
  FLUXER_CONNECTION_INITIATION_SECRET
  FLUXER_GATEWAY_RPC_AUTH_TOKEN
  FLUXER_MEDIA_PROXY_SECRET_KEY
  FLUXER_ADMIN_SECRET_KEY_BASE
  FLUXER_ADMIN_OAUTH_CLIENT_SECRET
  LIVEKIT_API_SECRET
)
for key in "${hex_keys[@]}"; do
  if grep -qE "^${key}=(CHANGE_ME|\$)" .env; then
    sed -i "s|^${key}=.*|${key}=$(openssl rand -hex 32)|" .env
  fi
done

if grep -qE "^FLUXER_MEDIA_PROXY_UPLOAD_RELAY_SECRET_BASE64=(CHANGE_ME|\$)" .env; then
  sed -i "s|^FLUXER_MEDIA_PROXY_UPLOAD_RELAY_SECRET_BASE64=.*|FLUXER_MEDIA_PROXY_UPLOAD_RELAY_SECRET_BASE64=$(openssl rand -base64 32)|" .env
fi

# ───────────────────── 8. VAPID keys (idempotent) ─────────────────────
if grep -qE "^FLUXER_VAPID_PUBLIC_KEY=(CHANGE_ME|\$)" .env; then
  log "generating VAPID key pair via node:24-alpine"
  vapid_json=$(docker run --rm node:24-alpine \
    npx --yes web-push generate-vapid-keys --json 2>/dev/null)
  pub=$(printf '%s'  "$vapid_json" | grep -o '"publicKey":"[^"]*"'  | cut -d'"' -f4)
  priv=$(printf '%s' "$vapid_json" | grep -o '"privateKey":"[^"]*"' | cut -d'"' -f4)
  [ -n "$pub" ] && [ -n "$priv" ] || die "VAPID generation failed"
  sed -i "s|^FLUXER_VAPID_PUBLIC_KEY=.*|FLUXER_VAPID_PUBLIC_KEY=$pub|"   .env
  sed -i "s|^FLUXER_VAPID_PRIVATE_KEY=.*|FLUXER_VAPID_PRIVATE_KEY=$priv|" .env
fi

# Final placeholder check.
if grep -q CHANGE_ME .env; then
  warn "the following placeholders are still in .env:"
  grep -n CHANGE_ME .env >&2
fi

# ───────────────────── 9. livekit.yaml ─────────────────────
log "rendering livekit.yaml with use_external_ip:false + node_ip:$SERVER_IP"
cat > livekit.yaml <<EOF
port: 7880
rtc:
  tcp_port: 7881
  udp_port: 7882
  use_external_ip: false
  node_ip: $SERVER_IP
keys:
  fluxer-api-key: \$LIVEKIT_API_SECRET
EOF

# ───────────────────── 10. UDP buffers for LiveKit ─────────────────────
log "raising net.core.{r,w}mem_max for LiveKit UDP throughput"
cat > /etc/sysctl.d/99-livekit.conf <<'EOF'
net.core.rmem_max=5000000
net.core.wmem_max=5000000
EOF
sysctl --system >/dev/null

# ───────────────────── 11. voice region + override ─────────────────────
if ! grep -q "^FLUXER_LIVEKIT_URL=" .env; then
  log "appending FLUXER_LIVEKIT_URL and DEFAULT_REGION to .env"
  {
    echo ""
    echo "FLUXER_LIVEKIT_URL=wss://$DOMAIN/livekit"
    echo "FLUXER_LIVEKIT_DEFAULT_REGION={\"id\":\"local\",\"name\":\"Local\",\"emoji\":\"RU\",\"latitude\":55.7558,\"longitude\":37.6173}"
  } >> .env
fi

log "writing docker-compose.override.yml (api + worker get voice env)"
cat > docker-compose.override.yml <<'EOF'
version: '3'
services:
  api:
    environment:
      FLUXER_LIVEKIT_URL: ${FLUXER_LIVEKIT_URL:?set FLUXER_LIVEKIT_URL in .env}
      FLUXER_LIVEKIT_DEFAULT_REGION: ${FLUXER_LIVEKIT_DEFAULT_REGION:?set FLUXER_LIVEKIT_DEFAULT_REGION in .env}
  worker:
    environment:
      FLUXER_LIVEKIT_URL: ${FLUXER_LIVEKIT_URL:?set FLUXER_LIVEKIT_URL in .env}
      FLUXER_LIVEKIT_DEFAULT_REGION: ${FLUXER_LIVEKIT_DEFAULT_REGION:?set FLUXER_LIVEKIT_DEFAULT_REGION in .env}
EOF

# ───────────────────── 12. pull + up ─────────────────────
log "docker compose config (validates substitution)"
docker compose config -q

log "docker compose pull (17 images, ~7 GiB)"
docker compose pull --quiet

log "docker compose up -d"
docker compose up -d

log "waiting 30s for containers to settle"
sleep 30

# ───────────────────── 13. SeaweedFS buckets ─────────────────────
log "creating SeaweedFS buckets (idempotent)"
for b in fluxer fluxer-uploads fluxer-downloads fluxer-reports fluxer-harvests; do
  printf 's3.bucket.create -name %s\n' "$b" \
    | docker compose exec -T seaweedfs weed shell -master=seaweedfs:9333 \
        >/dev/null 2>&1 || true
done

# ───────────────────── 14. report ─────────────────────
echo
log "container status:"
docker compose ps

echo
log "caddy TLS status:"
docker compose logs caddy 2>&1 | grep -iE 'certificate|tls' | tail -5 \
  || echo "  (no certificate logs yet — Let's Encrypt may take ~1 min)"

echo
log "health checks against https://$DOMAIN :"
sleep 5
for path in /_health /api/_health /gateway/_health /media/_health /admin/_health; do
  code=$(curl -fsS -o /dev/null -w '%{http_code}' "https://$DOMAIN$path" 2>/dev/null || echo "FAIL")
  printf "  %-20s %s\n" "$path" "$code"
done

echo
log "DONE — open https://$DOMAIN and register; the first account becomes admin."
