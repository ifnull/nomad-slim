#!/usr/bin/env bash
# One-shot bootstrap for N.O.M.A.D. Slim on Raspberry Pi OS (or any Debian-
# family system). Idempotent — safe to re-run.
#
#   curl -fsSL https://raw.githubusercontent.com/ifnull/nomad-slim/main/scripts/install.sh | sudo bash
# or from an existing clone:
#   sudo ./scripts/install.sh

set -euo pipefail

REPO_URL="https://github.com/ifnull/nomad-slim.git"
DEFAULT_INSTALL_DIR="/opt/nomad-slim"
SERVICE_NAME="nomad-slim"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

log()  { printf '\n==> %s\n' "$*"; }
warn() { printf '    [warn] %s\n' "$*" >&2; }
die()  { printf '    [error] %s\n' "$*" >&2; exit 1; }

confirm() {
  # $1=prompt, default N. returns 0 on yes.
  # Reads from the controlling terminal so prompts work even when this
  # script was invoked via `curl | sudo bash` (where stdin is the pipe).
  local ans=""
  if { : </dev/tty; } 2>/dev/null; then
    read -rp "$1 [y/N]: " ans </dev/tty
  else
    read -rp "$1 [y/N]: " ans || true
  fi
  [[ "$ans" =~ ^[Yy]$ ]]
}

# --- preflight -------------------------------------------------------------
[ "$(id -u)" -eq 0 ] || {
  echo "This script needs root; re-executing with sudo..."
  exec sudo -E bash "$0" "$@"
}

command -v apt-get >/dev/null 2>&1 || \
  die "Only Debian-family systems (Pi OS, Ubuntu, Debian) are supported right now."

# The user who invoked sudo — so we can add them to the docker group and
# set ownership of the clone directory to a non-root owner.
INVOKER="${SUDO_USER:-root}"
INVOKER_HOME="$(getent passwd "$INVOKER" | cut -d: -f6)"

# --- apt dependencies ------------------------------------------------------
log "Installing base packages (curl, jq, git, ca-certificates)..."
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl jq git ca-certificates >/dev/null

# --- docker ----------------------------------------------------------------
if ! command -v docker >/dev/null 2>&1; then
  log "Docker is not installed."
  if confirm "Install Docker now using the official get.docker.com script?"; then
    curl -fsSL https://get.docker.com | sh
  else
    die "Docker is required. Install it manually and re-run this script."
  fi
else
  log "Docker already installed ($(docker --version))."
fi

docker compose version >/dev/null 2>&1 || \
  die "Docker Compose v2 plugin missing. Install 'docker-compose-plugin' and re-run."

# Let the invoking user run docker without sudo (requires re-login to take effect).
if [ "$INVOKER" != "root" ] && ! id -nG "$INVOKER" | tr ' ' '\n' | grep -qx docker; then
  log "Adding $INVOKER to the docker group (log out/in to activate)."
  usermod -aG docker "$INVOKER"
fi

# --- repo location ---------------------------------------------------------
# If this script lives inside a valid clone, use that. Otherwise clone to
# $DEFAULT_INSTALL_DIR.
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]:-}" 2>/dev/null || true)"
REPO_ROOT=""
if [ -n "$SCRIPT_PATH" ] && [ -f "$SCRIPT_PATH" ]; then
  candidate="$(cd "$(dirname "$SCRIPT_PATH")/.." && pwd)"
  if [ -f "$candidate/docker-compose.yml" ] && grep -q '^name: nomad-slim' "$candidate/docker-compose.yml" 2>/dev/null; then
    REPO_ROOT="$candidate"
  fi
fi

if [ -z "$REPO_ROOT" ]; then
  if [ -d "$DEFAULT_INSTALL_DIR/.git" ]; then
    log "Using existing clone at $DEFAULT_INSTALL_DIR (pulling latest)..."
    git -C "$DEFAULT_INSTALL_DIR" pull --ff-only || warn "git pull failed; continuing with on-disk state."
  else
    log "Cloning $REPO_URL -> $DEFAULT_INSTALL_DIR ..."
    git clone --depth 1 "$REPO_URL" "$DEFAULT_INSTALL_DIR"
    chown -R "$INVOKER:$INVOKER" "$DEFAULT_INSTALL_DIR" 2>/dev/null || true
  fi
  REPO_ROOT="$DEFAULT_INSTALL_DIR"
fi
log "Repo root: $REPO_ROOT"

# --- self-signed cert for HTTPS --------------------------------------------
# Generate a CA + server cert so nginx can serve HTTPS, which is required
# for geolocation on phones accessing the maps page over LAN.
log "Generating self-signed TLS certificates..."
mkdir -p "$REPO_ROOT/data/certs"
chown "$INVOKER:$INVOKER" "$REPO_ROOT/data/certs" 2>/dev/null || true
run_as_invoker_sync() {
  if [ "$INVOKER" = "root" ]; then
    bash "$1" </dev/null
  else
    sudo -u "$INVOKER" -H bash "$1" </dev/null
  fi
}
run_as_invoker_sync "$REPO_ROOT/scripts/generate-cert.sh"

# --- systemd unit ----------------------------------------------------------
log "Installing systemd unit $SERVICE_FILE ..."
cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=N.O.M.A.D. Slim (Kiwix + Kolibri + Offline Maps)
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=$REPO_ROOT
ExecStart=/usr/bin/docker compose up -d --build
ExecStop=/usr/bin/docker compose down
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "$SERVICE_NAME" >/dev/null
log "Starting $SERVICE_NAME (first run builds the web image; may take a minute)..."
systemctl restart "$SERVICE_NAME"

# --- content prompts -------------------------------------------------------
run_as_invoker() {
  # Run a script as the invoking user so downloads land with the right owner.
  # Redirect the child's stdin to /dev/null: when this installer was itself
  # invoked via `curl | sudo bash`, the child would otherwise inherit (and
  # potentially consume) the remaining script text still sitting in the pipe.
  # The child scripts read interactive prompts from /dev/tty, so cutting off
  # stdin is safe.
  if [ "$INVOKER" = "root" ]; then
    (cd "$REPO_ROOT" && bash "$1" </dev/null)
  else
    sudo -u "$INVOKER" -H bash -c "cd '$REPO_ROOT' && bash '$1'" </dev/null
  fi
}

echo
log "Optional content downloads — you can skip any and run these later."
if confirm "Download the labeled basemap assets now (~21 MB)?"; then
  run_as_invoker "$REPO_ROOT/scripts/fetch-basemap-assets.sh"
  systemctl restart "$SERVICE_NAME"
fi
if confirm "Pick and download PMTiles map regions now?"; then
  run_as_invoker "$REPO_ROOT/scripts/fetch-maps.sh"
fi
if confirm "Pick and download Kiwix ZIM files now?"; then
  run_as_invoker "$REPO_ROOT/scripts/fetch-zims.sh"
fi

# --- summary ---------------------------------------------------------------
host_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
[ -n "$host_ip" ] || host_ip="localhost"

cat <<EOF

==============================================================
  N.O.M.A.D. Slim is running. Open any of these from your LAN:

    Landing page        http://$host_ip
    Offline Maps        http://$host_ip/maps.html
    Information Library http://$host_ip:8090
    Education Platform  http://$host_ip:8300

  For GPS on phones, use HTTPS (after installing data/certs/ca.crt on the device):
    HTTPS landing       https://$host_ip:8443
    HTTPS maps          https://$host_ip:8443/maps.html
    Download the CA     https://$host_ip:8443/ca.crt

  Service management:
    systemctl status  $SERVICE_NAME
    systemctl restart $SERVICE_NAME
    systemctl stop    $SERVICE_NAME

  Repo: $REPO_ROOT
EOF

if [ "$INVOKER" != "root" ] && ! id -nG "$INVOKER" | tr ' ' '\n' | grep -qx docker; then
  echo "  NOTE: log out and back in so $INVOKER can run 'docker' without sudo."
fi
echo "=============================================================="
