#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAME="${APP_NAME:-puzzle-upstream}"
INSTALL_DIR="${INSTALL_DIR:-/opt/puzzle/upstream}"
COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"
ENV_FILE="$INSTALL_DIR/.env"
LOCK_FILE="/var/lock/${APP_NAME}.lock"
LOG_PREFIX="[${APP_NAME}]"

log() { printf '%s %s\n' "$LOG_PREFIX" "$*"; }
warn() { printf '%s WARN: %s\n' "$LOG_PREFIX" "$*" >&2; }
die() { printf '%s ERROR: %s\n' "$LOG_PREFIX" "$*" >&2; exit 1; }

on_error() {
  local line="$1"
  warn "deployment failed at line $line"
  if command -v docker >/dev/null 2>&1 && [[ -f "$COMPOSE_FILE" ]]; then
    compose_cmd ps >&2 || true
    compose_cmd logs --tail=80 api >&2 || true
  fi
}
trap 'on_error $LINENO' ERR

require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    if command -v sudo >/dev/null 2>&1; then
      exec sudo -E bash "$0" "$@"
    fi
    die "must run as root or with passwordless sudo"
  fi
}

require_ubuntu_2204() {
  [[ -r /etc/os-release ]] || die "/etc/os-release not found"
  # shellcheck disable=SC1091
  . /etc/os-release
  [[ "${ID:-}" == "ubuntu" && "${VERSION_ID:-}" == "22.04" ]] || die "only Ubuntu 22.04 LTS is supported, got ${PRETTY_NAME:-unknown}"
}

need_env() {
  local name="$1"
  [[ -n "${!name:-}" ]] || die "missing required env: $name"
}

random_hex() {
  openssl rand -hex "$1"
}

caddy_enabled() {
  [[ "${UPSTREAM_ENABLE_CADDY:-false}" == "true" ]]
}

upstream_host_port() {
  local bind="${UPSTREAM_BIND:-}"
  if [[ -n "$bind" ]]; then
    printf '%s' "${bind##*:}"
  else
    printf '%s' "${UPSTREAM_PUBLIC_PORT:-11080}"
  fi
}

default_upstream_bind() {
  local port
  port="$(upstream_host_port)"
  if caddy_enabled; then
    printf '127.0.0.1:%s' "$port"
  else
    printf '0.0.0.0:%s' "$port"
  fi
}

compose_cmd() {
  docker compose \
    --project-name "${COMPOSE_PROJECT_NAME:-puzzle-upstream}" \
    --env-file "$ENV_FILE" -f "$COMPOSE_FILE" "$@"
}

normalize_public_url() {
  local value="${UPSTREAM_PUBLIC_URL:-}"
  if [[ -z "$value" ]]; then
    die "missing required env: UPSTREAM_PUBLIC_URL"
  fi
  if [[ "$value" != http://* && "$value" != https://* ]]; then
    local host="${value%%/*}"
    host="${host%%:*}"
    if is_ip_address "$host" || [[ "$host" == "localhost" ]]; then
      value="http://$value"
    else
      value="https://$value"
    fi
  fi
  if ! caddy_enabled && [[ "$value" == http://* ]]; then
    local hostport="${value#http://}"
    hostport="${hostport%%/*}"
    local host="${hostport%%:*}"
    if is_ip_address "$host" && [[ "$hostport" != *:* ]]; then
      value="http://$host:${UPSTREAM_PUBLIC_PORT:-11080}"
    fi
  fi
  printf '%s' "${value%/}"
}

host_from_url() {
  local url="$1"
  url="${url#http://}"
  url="${url#https://}"
  url="${url%%/*}"
  url="${url%%:*}"
  printf '%s' "$url"
}

is_ip_address() {
  [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

write_kv() {
  local key="$1"
  local value="$2"
  value="${value//$'\r'/}"
  value="${value//$'\n'/}"
  printf '%s=%s\n' "$key" "$value" >> "$ENV_FILE"
}

# preserve_secret returns the previously-stored value for `key` from
# the env file, so re-running this installer doesn't roll DB
# passwords / bootstrap secrets / instance ids — re-rolling would
# brick auth (admins can't log in with the old password) and break
# Postgres (data dir keeps the old password). Returns empty string
# when not previously set.
preserve_secret() {
  local key="$1"
  local file="${PREV_ENV_FILE:-$ENV_FILE}"
  [[ -f "$file" ]] || { printf ''; return; }
  local raw
  raw="$(grep -E "^${key}=" "$file" | tail -n1 || true)"
  [[ -n "$raw" ]] || { printf ''; return; }
  raw="${raw#${key}=}"
  local unwrapped
  unwrapped="$(eval "printf '%s' $raw" 2>/dev/null || true)"
  printf '%s' "$unwrapped"
}

# wait_apt_lock blocks until no other process holds the dpkg/apt locks.
# Fresh cloud images almost always boot running `unattended-upgrades` /
# `apt-daily`, which grabs these locks for a minute or two. Without this
# wait, our first apt-get races them and dies with "Could not get lock
# /var/lib/dpkg/lock-frontend". We poll for up to ~5 min, then proceed
# (apt itself will then emit the canonical error if it's still locked).
wait_apt_lock() {
  local waited=0 max=300
  local locks=(/var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock /var/cache/apt/archives/lock)
  while :; do
    local held=""
    if command -v fuser >/dev/null 2>&1; then
      local f
      for f in "${locks[@]}"; do
        [[ -e "$f" ]] || continue
        if fuser "$f" >/dev/null 2>&1; then held="$f"; break; fi
      done
    else
      pgrep -x 'apt|apt-get|dpkg|unattended-upgr' >/dev/null 2>&1 && held="apt/dpkg process"
    fi
    [[ -z "$held" ]] && return 0
    if (( waited >= max )); then
      warn "apt/dpkg still busy after ${max}s ($held); proceeding anyway"
      return 0
    fi
    if (( waited == 0 )); then
      log "waiting for apt/dpkg lock to be released ($held)..."
    fi
    sleep 5
    waited=$((waited + 5))
  done
}

# apt_update_retry runs `apt-get update` with the lock-wait and a few
# retries, so transient mirror hiccups or a just-releasing lock don't
# abort the whole deploy.
apt_update_retry() {
  local attempt=1
  while :; do
    wait_apt_lock
    if apt-get update; then
      return 0
    fi
    if (( attempt >= 3 )); then
      die "apt-get update failed after $attempt attempts (check the server's network / DNS / apt mirrors)"
    fi
    warn "apt-get update failed (attempt $attempt); retrying in 5s"
    sleep 5
    attempt=$((attempt + 1))
  done
}

# apt_install wraps apt-get install with the same lock-wait + retry.
apt_install() {
  local attempt=1
  while :; do
    wait_apt_lock
    if apt-get install -y --no-install-recommends "$@"; then
      return 0
    fi
    if (( attempt >= 3 )); then
      die "apt-get install failed after $attempt attempts: $*"
    fi
    warn "apt-get install failed (attempt $attempt); retrying in 5s"
    sleep 5
    attempt=$((attempt + 1))
  done
}

install_base_packages() {
  log "installing base packages"
  export DEBIAN_FRONTEND=noninteractive
  apt_update_retry
  apt_install ca-certificates curl gnupg lsb-release openssl ufw rsync debian-keyring debian-archive-keyring apt-transport-https
}

install_docker() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    log "docker and compose plugin already installed"
    systemctl enable --now docker >/dev/null 2>&1 || true
    return
  fi
  log "installing Docker CE and compose plugin"
  install -m 0755 -d /etc/apt/keyrings
  if [[ ! -s /etc/apt/keyrings/docker.asc ]]; then
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
  fi
  local codename arch
  codename="$(. /etc/os-release && printf '%s' "$VERSION_CODENAME")"
  arch="$(dpkg --print-architecture)"
  local desired_line="deb [arch=$arch signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $codename stable"
  if [[ ! -f /etc/apt/sources.list.d/docker.list ]] || ! grep -qF "$desired_line" /etc/apt/sources.list.d/docker.list; then
    printf '%s\n' "$desired_line" > /etc/apt/sources.list.d/docker.list
    apt_update_retry
  fi
  apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
}

ensure_swap() {
  local size_gb="${UPSTREAM_SWAP_SIZE_GB:-2}"
  [[ "$size_gb" =~ ^[0-9]+$ ]] || die "UPSTREAM_SWAP_SIZE_GB must be an integer GiB value"
  if (( size_gb == 0 )); then
    log "swap setup disabled"
    return
  fi
  local current_kb desired_kb
  current_kb="$(awk '/^SwapTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
  desired_kb=$((size_gb * 1024 * 1024))
  if (( current_kb >= desired_kb )); then
    log "swap already available: $(( current_kb / 1024 )) MiB"
    return
  fi
  local swapfile="${UPSTREAM_SWAP_FILE:-/swapfile}"
  if awk -v path="$swapfile" 'NR > 1 && $1 == path { found = 1 } END { exit found ? 0 : 1 }' /proc/swaps 2>/dev/null; then
    log "swap already active at $swapfile"
    ensure_swap_persistence "$swapfile"
    return
  fi
  log "creating ${size_gb}GiB swap at $swapfile"
  if [[ ! -f "$swapfile" ]]; then
    if ! fallocate -l "${size_gb}G" "$swapfile" 2>/dev/null; then
      dd if=/dev/zero of="$swapfile" bs=1M count=$((size_gb * 1024)) status=progress
    fi
  fi
  chmod 600 "$swapfile"
  mkswap "$swapfile" >/dev/null
  swapon "$swapfile" || true
  ensure_swap_persistence "$swapfile"
}

ensure_swap_persistence() {
  local swapfile="$1"
  if ! grep -qF "$swapfile none swap" /etc/fstab; then
    printf '%s none swap sw 0 0\n' "$swapfile" >> /etc/fstab
  fi
  sysctl vm.swappiness=10 >/dev/null || true
  if [[ ! -f /etc/sysctl.d/99-puzzle-upstream.conf ]] || ! grep -q '^vm.swappiness=' /etc/sysctl.d/99-puzzle-upstream.conf; then
    printf 'vm.swappiness=10\n' > /etc/sysctl.d/99-puzzle-upstream.conf
  fi
}

prepare_dirs() {
  mkdir -p "$INSTALL_DIR" "$INSTALL_DIR/artifacts" "$INSTALL_DIR/backups" "$INSTALL_DIR/downloads"
  chmod 0750 "$INSTALL_DIR"
  if [[ -f "$ENV_FILE" ]]; then
    cp "$ENV_FILE" "$INSTALL_DIR/backups/.env.$(date +%Y%m%d%H%M%S)"
  fi
  if [[ -f "$COMPOSE_FILE" ]]; then
    cp "$COMPOSE_FILE" "$INSTALL_DIR/backups/docker-compose.yml.$(date +%Y%m%d%H%M%S)"
  fi
}

load_or_pull_image() {
  # Preferred path for laptop-driven deploys: the wrapper uploads a
  # `docker save` tar over SSH and points us at it. Loading a local
  # file is idempotent (docker load just re-imports the same layers)
  # and needs no registry credentials or outbound network.
  if [[ -n "${UPSTREAM_IMAGE_TAR_PATH:-}" ]]; then
    [[ -f "$UPSTREAM_IMAGE_TAR_PATH" ]] || die "UPSTREAM_IMAGE_TAR_PATH not found: $UPSTREAM_IMAGE_TAR_PATH"
    if [[ -n "${UPSTREAM_IMAGE_TAR_SHA256:-}" ]]; then
      printf '%s  %s\n' "$UPSTREAM_IMAGE_TAR_SHA256" "$UPSTREAM_IMAGE_TAR_PATH" | sha256sum -c -
    fi
    log "loading docker image from $UPSTREAM_IMAGE_TAR_PATH"
    docker load -i "$UPSTREAM_IMAGE_TAR_PATH"
    verify_image_arch "$UPSTREAM_IMAGE"
    return
  fi
  if [[ -n "${UPSTREAM_IMAGE_TAR_URL:-}" ]]; then
    local tarball="$INSTALL_DIR/artifacts/upstream-${UPSTREAM_VERSION:-latest}.tar"
    log "downloading upstream image tar"
    curl --fail --location --show-error --retry 4 --retry-delay 3 --connect-timeout 20 "$UPSTREAM_IMAGE_TAR_URL" -o "$tarball.tmp"
    if [[ -n "${UPSTREAM_IMAGE_TAR_SHA256:-}" ]]; then
      printf '%s  %s\n' "$UPSTREAM_IMAGE_TAR_SHA256" "$tarball.tmp" | sha256sum -c -
    fi
    mv "$tarball.tmp" "$tarball"
    log "loading docker image from $tarball"
    docker load -i "$tarball"
    verify_image_arch "$UPSTREAM_IMAGE"
  else
    log "pulling docker image $UPSTREAM_IMAGE"
    docker pull "$UPSTREAM_IMAGE"
  fi
}

# verify_image_arch hard-stops when the loaded image's architecture
# doesn't match the host (e.g. an Apple-Silicon arm64 image loaded on
# an amd64 server), turning a silent health-check timeout into a clear
# message. docker pull selects the right arch itself, so this only
# guards the docker-load paths.
verify_image_arch() {
  local image="$1"
  local img_arch host_arch
  img_arch="$(docker image inspect "$image" --format '{{.Architecture}}' 2>/dev/null | head -n1)"
  host_arch="$(dpkg --print-architecture 2>/dev/null || true)"
  case "$host_arch" in
    x86_64) host_arch="amd64" ;;
    aarch64) host_arch="arm64" ;;
  esac
  [[ -n "$img_arch" && -n "$host_arch" ]] || return 0
  if [[ "$img_arch" != "$host_arch" ]]; then
    die "image $image is linux/$img_arch but this server is linux/$host_arch — it would crash with 'exec format error'. Rebuild for linux/$host_arch (the deploy wrapper does this automatically when it can reach your Docker buildx)."
  fi
  log "image architecture OK: linux/$img_arch"
}

write_env_file() {
  local public_url="$1"
  # Snapshot the previous env file so we can carry secrets forward.
  local prev_env=""
  if [[ -f "$ENV_FILE" ]]; then
    prev_env="$(mktemp)"
    cp "$ENV_FILE" "$prev_env"
  fi
  PREV_ENV_FILE="$prev_env"
  : > "$ENV_FILE"
  chmod 0600 "$ENV_FILE"

  # Resolve secrets: env override → previous file → fresh random.
  local db_password admin_password comm_secret replay_secret
  db_password="${UPSTREAM_DB_PASSWORD:-$(preserve_secret UPSTREAM_DB_PASSWORD)}"
  [[ -n "$db_password" ]] || db_password="$(random_hex 24)"
  admin_password="${UPSTREAM_BOOTSTRAP_ADMIN_PASSWORD:-$(preserve_secret UPSTREAM_BOOTSTRAP_ADMIN_PASSWORD)}"
  [[ -n "$admin_password" ]] || admin_password="$(random_hex 18)"
  # Platform-wide secrets. These MUST be identical on every
  # client-server node and in the desktop app build, otherwise the
  # AES-256-GCM envelope + replay-guard HMAC between client and
  # upstream cannot be verified. We generate them once here on first
  # boot, preserve them across re-runs, and print them at the end so
  # the operator pastes the same values into the client deploy + app
  # build exactly once.
  comm_secret="${UPSTREAM_COMMUNICATION_SECRET:-$(preserve_secret UPSTREAM_COMMUNICATION_SECRET)}"
  [[ -n "$comm_secret" ]] || comm_secret="$(random_hex 32)"
  replay_secret="${UPSTREAM_REPLAY_SECRET:-$(preserve_secret UPSTREAM_REPLAY_SECRET)}"
  [[ -n "$replay_secret" ]] || replay_secret="$(random_hex 32)"
  PLATFORM_COMM_SECRET="$comm_secret"
  PLATFORM_REPLAY_SECRET="$replay_secret"

  write_kv UPSTREAM_IMAGE "$UPSTREAM_IMAGE"
  # production mode turns Validate() into a hard gate: dev-default
  # secrets / admin password are refused at boot. We just generated
  # real secrets above, so this is safe and is what locks the box down.
  write_kv UPSTREAM_APP_ENV "${UPSTREAM_APP_ENV:-production}"
  write_kv UPSTREAM_PUBLIC_PORT "$(upstream_host_port)"
  write_kv UPSTREAM_BIND "${UPSTREAM_BIND:-$(default_upstream_bind)}"
  write_kv UPSTREAM_PUBLIC_URL "$public_url"
  write_kv UPSTREAM_ALLOWED_ORIGINS "${UPSTREAM_ALLOWED_ORIGINS:-$public_url,http://tauri.localhost,https://tauri.localhost,tauri://localhost}"
  write_kv UPSTREAM_BOOTSTRAP_ADMIN_EMAIL "${UPSTREAM_BOOTSTRAP_ADMIN_EMAIL:-admin@cloud-company.local}"
  write_kv UPSTREAM_BOOTSTRAP_ADMIN_PASSWORD "$admin_password"
  write_kv UPSTREAM_BOOTSTRAP_UPDATE "${UPSTREAM_BOOTSTRAP_UPDATE:-false}"
  write_kv UPSTREAM_CLIENT_SERVER_IMAGE "${UPSTREAM_CLIENT_SERVER_IMAGE:-cloudpro/client-server:latest}"
  write_kv UPSTREAM_CLIENT_SERVER_API_PORT "${UPSTREAM_CLIENT_SERVER_API_PORT:-11190}"
  write_kv UPSTREAM_CLIENT_SERVER_ACME_EMAIL "${LETSENCRYPT_EMAIL:-$(preserve_secret UPSTREAM_CLIENT_SERVER_ACME_EMAIL)}"
  write_kv UPSTREAM_CLIENT_SERVER_WEB_PORT "${UPSTREAM_CLIENT_SERVER_WEB_PORT:-18090}"
  write_kv UPSTREAM_REALTIME_PORT "${UPSTREAM_REALTIME_PORT:-19188}"
  write_kv UPSTREAM_COMMUNICATION_SECRET "$comm_secret"
  write_kv UPSTREAM_REPLAY_SECRET "$replay_secret"
  write_kv UPSTREAM_DB_USER "${UPSTREAM_DB_USER:-postgres}"
  write_kv UPSTREAM_DB_PASSWORD "$db_password"
  write_kv UPSTREAM_DB_NAME "${UPSTREAM_DB_NAME:-cloud-company-upstream}"
  write_kv UPSTREAM_DB_MAINTENANCE_NAME "${UPSTREAM_DB_MAINTENANCE_NAME:-postgres}"
  write_kv UPSTREAM_DB_MAX_OPEN_CONNS "${UPSTREAM_DB_MAX_OPEN_CONNS:-20}"
  write_kv UPSTREAM_DB_MAX_IDLE_CONNS "${UPSTREAM_DB_MAX_IDLE_CONNS:-5}"
  write_kv UPSTREAM_DB_CONN_MAX_LIFETIME "${UPSTREAM_DB_CONN_MAX_LIFETIME:-30m}"
  write_kv UPSTREAM_LOG_LEVEL "${UPSTREAM_LOG_LEVEL:-info}"

  if [[ -n "$prev_env" ]]; then
    rm -f "$prev_env"
  fi
}

write_compose_file() {
  cat > "$COMPOSE_FILE" <<'YAML'
services:
  postgres:
    image: postgres:16-alpine
    restart: unless-stopped
    command:
      - postgres
      - -c
      - max_connections=50
      - -c
      - shared_buffers=512MB
      - -c
      - effective_cache_size=2GB
      - -c
      - work_mem=8MB
      - -c
      - maintenance_work_mem=128MB
    shm_size: 256mb
    mem_limit: 1536m
    environment:
      POSTGRES_USER: ${UPSTREAM_DB_USER:-postgres}
      POSTGRES_PASSWORD: ${UPSTREAM_DB_PASSWORD:?set db password}
      POSTGRES_DB: ${UPSTREAM_DB_MAINTENANCE_NAME:-postgres}
    volumes:
      - upstream-postgres:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${UPSTREAM_DB_USER:-postgres}"]
      interval: 10s
      timeout: 5s
      retries: 12

  api:
    image: ${UPSTREAM_IMAGE:?set upstream image}
    restart: unless-stopped
    depends_on:
      postgres:
        condition: service_healthy
    environment:
      UPSTREAM_ADDR: :11080
      UPSTREAM_APP_ENV: ${UPSTREAM_APP_ENV:-production}
      UPSTREAM_PUBLIC_URL: ${UPSTREAM_PUBLIC_URL:?set upstream public url}
      UPSTREAM_ALLOWED_ORIGINS: ${UPSTREAM_ALLOWED_ORIGINS:?set allowed origins}
      UPSTREAM_COMMUNICATION_SECRET: ${UPSTREAM_COMMUNICATION_SECRET:?set communication secret}
      UPSTREAM_REPLAY_SECRET: ${UPSTREAM_REPLAY_SECRET:?set replay secret}
      UPSTREAM_DB_HOST: postgres
      UPSTREAM_DB_PORT: 5432
      UPSTREAM_DB_USER: ${UPSTREAM_DB_USER:-postgres}
      UPSTREAM_DB_PASSWORD: ${UPSTREAM_DB_PASSWORD:?set db password}
      UPSTREAM_DB_NAME: ${UPSTREAM_DB_NAME:-cloud-company-upstream}
      UPSTREAM_DB_MAINTENANCE_NAME: ${UPSTREAM_DB_MAINTENANCE_NAME:-postgres}
      UPSTREAM_DB_SSLMODE: disable
      UPSTREAM_DB_MAX_OPEN_CONNS: ${UPSTREAM_DB_MAX_OPEN_CONNS:-20}
      UPSTREAM_DB_MAX_IDLE_CONNS: ${UPSTREAM_DB_MAX_IDLE_CONNS:-5}
      UPSTREAM_DB_CONN_MAX_LIFETIME: ${UPSTREAM_DB_CONN_MAX_LIFETIME:-30m}
      UPSTREAM_CLIENT_SERVER_IMAGE: ${UPSTREAM_CLIENT_SERVER_IMAGE:-cloudpro/client-server:latest}
      UPSTREAM_CLIENT_SERVER_API_PORT: ${UPSTREAM_CLIENT_SERVER_API_PORT:-11190}
      UPSTREAM_CLIENT_SERVER_ACME_EMAIL: ${UPSTREAM_CLIENT_SERVER_ACME_EMAIL:-}
      UPSTREAM_CLIENT_SERVER_WEB_PORT: ${UPSTREAM_CLIENT_SERVER_WEB_PORT:-18090}
      UPSTREAM_REALTIME_PORT: ${UPSTREAM_REALTIME_PORT:-19188}
      UPSTREAM_CLIENT_SERVER_ARTIFACT: downloads/client-server/latest.tar
      UPSTREAM_BOOTSTRAP_ADMIN_EMAIL: ${UPSTREAM_BOOTSTRAP_ADMIN_EMAIL:-admin@cloud-company.local}
      UPSTREAM_BOOTSTRAP_ADMIN_PASSWORD: ${UPSTREAM_BOOTSTRAP_ADMIN_PASSWORD:?set bootstrap password}
      UPSTREAM_BOOTSTRAP_UPDATE: ${UPSTREAM_BOOTSTRAP_UPDATE:-false}
      UPSTREAM_LOG_LEVEL: ${UPSTREAM_LOG_LEVEL:-info}
    volumes:
      - upstream-downloads:/app/static/downloads
    mem_limit: 768m
    ports:
      - "${UPSTREAM_BIND:-127.0.0.1:11080}:11080"

volumes:
  upstream-postgres:
  upstream-downloads:
YAML
}

configure_caddy() {
  # Caddy is the platform's only reverse-proxy / TLS terminator.
  # For https hostnames it auto-issues + renews Let's Encrypt certificates.
  # For http://IP or http://localhost it binds plain HTTP on :80.
  local public_url="$1"
  local domain="$2"
  log "installing caddy"
  if [[ ! -f /etc/apt/sources.list.d/caddy-stable.list ]]; then
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
      | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
      | tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null
    apt_update_retry
  fi
  apt_install caddy

  mkdir -p /etc/caddy
  local server_names="$domain"
  if [[ "$public_url" == http://* ]]; then
    if [[ -z "$domain" || "$domain" == "localhost" || "$(is_ip_address "$domain" && printf yes)" == "yes" ]]; then
      server_names=":80"
    else
      server_names="http://$domain"
    fi
  elif [[ -z "$server_names" || "$server_names" == "localhost" ]]; then
    server_names=":80"
  fi
  # Same managed-marker pattern as the client-server installer:
  # only own the Caddyfile if we wrote it, so operator hand-edits
  # survive subsequent re-runs of this script.
  local managed_marker="# managed-by: puzzle-installer"
  if [[ -f /etc/caddy/Caddyfile ]] && ! grep -qF "$managed_marker" /etc/caddy/Caddyfile; then
    warn "/etc/caddy/Caddyfile exists and is not script-managed; leaving it alone"
  else
    local tmp
    tmp="$(mktemp /etc/caddy/Caddyfile.new.XXXXXX)"
    cat > "$tmp" <<CADDY
$managed_marker
{
    admin localhost:2019
    email ${LETSENCRYPT_EMAIL:-${UPSTREAM_BOOTSTRAP_ADMIN_EMAIL:-admin@example.com}}
}

${server_names} {
    encode gzip zstd
    reverse_proxy 127.0.0.1:$(upstream_host_port) {
        header_up Host {http.request.host}
        header_up X-Forwarded-Proto {http.request.scheme}
        header_up X-Real-IP {http.request.remote.host}
    }
}
CADDY
    chmod 0644 "$tmp"
    mv -f "$tmp" /etc/caddy/Caddyfile
  fi
  systemctl enable --now caddy
  systemctl reload caddy || systemctl restart caddy
}

configure_firewall() {
  if [[ "${ENABLE_UFW:-true}" != "true" ]]; then
    return
  fi
  ufw allow OpenSSH >/dev/null || true
  ufw allow "${SSH_PORT:-22}/tcp" >/dev/null || true
  if caddy_enabled; then
    ufw allow 80/tcp >/dev/null || true
    ufw allow 443/tcp >/dev/null || true
    ufw allow 443/udp >/dev/null || true
  else
    ufw allow "$(upstream_host_port)/tcp" >/dev/null || true
  fi
  ufw --force enable >/dev/null || true
}

# preflight_environment surfaces the two host conditions that otherwise
# fail deep inside the deploy with cryptic errors:
#   1. ports 80/443 already owned by a non-Caddy service (nginx, apache,
#      another stack). Caddy would then fail to bind and TLS never works.
#   2. not enough free disk in /var/lib/docker to load the image +
#      pull postgres. We only warn here (operators sometimes mount
#      docker storage elsewhere) but a hard floor catches the common
#      "tiny VPS already full" case.
preflight_environment() {
  local conflict=0 p
  local ports=("$(upstream_host_port)")
  caddy_enabled && ports=(80 443)
  for p in "${ports[@]}"; do
    if command -v ss >/dev/null 2>&1; then
      # Match a listener on the bare port. Caddy/docker-proxy from a
      # previous run of THIS stack is fine; flag anything else.
      local who
      who="$(ss -ltnpH "( sport = :$p )" 2>/dev/null | grep -v -e 'caddy' -e 'docker-proxy' || true)"
      if [[ -n "$who" ]]; then
        warn "port $p is already in use by a non-Caddy process:"
        printf '%s\n' "$who" | sed 's/^/    /' >&2
        conflict=1
      fi
    fi
  done
  if (( conflict == 1 )); then
    if [[ "${IGNORE_PORT_CONFLICT:-false}" == "true" ]]; then
      warn "IGNORE_PORT_CONFLICT=true set; continuing despite port conflict"
    else
      die "required public port is occupied. Stop the other service or re-run with IGNORE_PORT_CONFLICT=true."
    fi
  fi

  local avail_kb
  avail_kb="$(df -Pk /var/lib 2>/dev/null | awk 'NR==2{print $4}')"
  if [[ -n "$avail_kb" && "$avail_kb" -lt 2097152 ]]; then
    warn "less than 2 GiB free on /var/lib ($(( avail_kb / 1024 )) MiB) — image load + postgres may fail. Free space or resize the disk."
  fi
}

start_stack() {
  log "starting docker compose stack"
  compose_cmd up -d --remove-orphans
}

wait_health() {
  local health_url="${HEALTHCHECK_URL:-http://127.0.0.1:$(upstream_host_port)/healthz}"
  log "waiting for health check: $health_url"
  for _ in $(seq 1 60); do
    if curl -fsS --max-time 4 "$health_url" >/dev/null; then
      log "health check passed"
      return
    fi
    sleep 3
  done
  compose_cmd ps >&2 || true
  compose_cmd logs --tail=120 api >&2 || true
  die "health check timed out"
}

main() {
  require_root "$@"
  exec 9>"$LOCK_FILE"
  flock -n 9 || die "another deployment is running"
  require_ubuntu_2204
  need_env UPSTREAM_IMAGE
  local public_url domain
  public_url="$(normalize_public_url)"
  domain="$(host_from_url "$public_url")"
  install_base_packages
  ensure_swap
  install_docker
  preflight_environment
  prepare_dirs
  load_or_pull_image
  write_env_file "$public_url"
  write_compose_file
  if caddy_enabled; then
    configure_caddy "$public_url" "$domain"
  else
    log "skipping caddy; upstream API will be exposed directly via docker port ${UPSTREAM_BIND:-$(default_upstream_bind)}"
  fi
  configure_firewall
  start_stack
  wait_health
  log "deployment finished"
  log "public url: $public_url"
  log "admin dashboard: ${public_url%/}/admin/"
  log "install dir: $INSTALL_DIR"
  log "downloads volume name: upstream-downloads (mounted at /app/static/downloads)"
  log "to publish release artifacts: docker run --rm -v upstream-downloads:/dst -v \"\$PWD\":/src alpine cp -r /src/. /dst/"
  print_platform_secrets "$public_url"
}

# fetch_trust_public_key reads the active Ed25519 signing public key
# from the freshly-started upstream. Client servers now pin this key
# out of band and refuse production TOFU, so printing it here is part
# of the deployment contract.
fetch_trust_public_key() {
  local trust_json key
  trust_json="$(curl -fsS --max-time 10 "http://127.0.0.1:$(upstream_host_port)/api/v1/trust/keys")" || die "failed to fetch upstream trust public key"
  key="$(printf '%s' "$trust_json" | sed -n 's/.*"publicKey"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
  [[ -n "$key" ]] || die "failed to parse upstream trust public key"
  printf '%s' "$key"
}

# print_platform_secrets emits the one block the operator must copy.
# These secrets cannot be auto-delivered to clients because they are
# what secures the client↔upstream channel in the first place
# (delivering them over that channel would be circular). Print them
# once; paste into every client deploy config + the app build.
print_platform_secrets() {
  local public_url="$1"
  local pinned_public_key
  pinned_public_key="$(fetch_trust_public_key)"
  printf '\n'
  printf '%s ============================================================\n' "$LOG_PREFIX"
  printf '%s  PLATFORM SECRETS — copy these into client + app ONE time\n' "$LOG_PREFIX"
  printf '%s ============================================================\n' "$LOG_PREFIX"
  printf '%s  Client deploy config (deploy-client-server.conf):\n' "$LOG_PREFIX"
  printf '    UPSTREAM_URL="%s"\n' "$public_url"
  printf '    COMMUNICATION_SECRET="%s"\n' "${PLATFORM_COMM_SECRET}"
  printf '    REPLAY_SECRET="%s"\n' "${PLATFORM_REPLAY_SECRET}"
  printf '    UPSTREAM_PINNED_PUBLIC_KEY="%s"\n' "${pinned_public_key}"
  printf '%s  Desktop app build (.env.tauri / .env.web), same value:\n' "$LOG_PREFIX"
  printf '    VITE_COMMUNICATION_SECRET=%s\n' "${PLATFORM_COMM_SECRET}"
  printf '%s  Also printed to: %s\n' "$LOG_PREFIX" "$INSTALL_DIR/platform-secrets.txt"
  printf '%s ============================================================\n\n' "$LOG_PREFIX"
  # Persist a 0600 copy so the operator can retrieve it later without
  # re-running. Idempotent: overwritten with the same (preserved) values.
  {
    printf '# Platform secrets for the cloud-company stack.\n'
    printf '# Generated by the upstream installer. Same values must appear on\n'
    printf '# every client-server node and in the desktop app build.\n'
    printf 'UPSTREAM_URL=%s\n' "$public_url"
    printf 'COMMUNICATION_SECRET=%s\n' "${PLATFORM_COMM_SECRET}"
    printf 'REPLAY_SECRET=%s\n' "${PLATFORM_REPLAY_SECRET}"
    printf 'UPSTREAM_PINNED_PUBLIC_KEY=%s\n' "${pinned_public_key}"
  } > "$INSTALL_DIR/platform-secrets.txt"
  chmod 0600 "$INSTALL_DIR/platform-secrets.txt"
}

main "$@"
