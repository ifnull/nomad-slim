#!/usr/bin/env bash
# Generate a self-signed root CA and a server certificate for the nomad-slim
# web container. Certs land in data/certs/ and are bound into the web container
# at /etc/nginx/certs.
#
# The CA cert (data/certs/ca.crt) is what you install on phones/tablets once
# to make the HTTPS endpoint trusted (needed so geolocation works on mobile).
#
# Run this once on first install, or again whenever your Pi's LAN IP or
# hostname changes — the server cert's SAN list is rebuilt from the current
# network state each time.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CERTS_DIR="$REPO_ROOT/data/certs"

command -v openssl >/dev/null 2>&1 || { echo "error: openssl is required" >&2; exit 1; }

# If a previous bring-up left data/certs as a root-owned directory from
# docker's bind-mount auto-create, try to take ownership. Ignore failures —
# user can re-run with sudo if needed.
if [ -d "$CERTS_DIR" ] && [ ! -w "$CERTS_DIR" ]; then
  sudo chown -R "$(id -u):$(id -g)" "$CERTS_DIR" 2>/dev/null || true
fi

mkdir -p "$CERTS_DIR"
chmod 755 "$CERTS_DIR"

# --- gather SANs -----------------------------------------------------------
HOSTNAME_SHORT="$(hostname 2>/dev/null || echo nomad-slim)"
HOSTNAME_MDNS="${HOSTNAME_SHORT}.local"

SAN_ENTRIES=(
  "DNS:localhost"
  "DNS:$HOSTNAME_SHORT"
  "DNS:$HOSTNAME_MDNS"
  "IP:127.0.0.1"
)
while read -r ip; do
  [ -n "$ip" ] && SAN_ENTRIES+=("IP:$ip")
done < <(hostname -I 2>/dev/null | tr ' ' '\n' | grep -v '^$' || true)

SAN_STRING="$(IFS=,; echo "${SAN_ENTRIES[*]}")"

# --- root CA (persisted; reused across regenerations) ----------------------
if [ ! -f "$CERTS_DIR/ca.crt" ] || [ ! -f "$CERTS_DIR/ca.key" ]; then
  echo "Generating new root CA (valid 10 years)..."
  openssl genrsa -out "$CERTS_DIR/ca.key" 4096 2>/dev/null
  openssl req -x509 -new -nodes -key "$CERTS_DIR/ca.key" -sha256 -days 3650 \
    -subj "/CN=N.O.M.A.D. Slim Root CA" \
    -out "$CERTS_DIR/ca.crt"
  chmod 600 "$CERTS_DIR/ca.key"
else
  echo "Reusing existing root CA at $CERTS_DIR/ca.crt"
fi

# --- server cert (regenerated each run so SANs track the current LAN IP) ---
echo "Generating server certificate (valid 398 days; SAN: $SAN_STRING)..."
openssl genrsa -out "$CERTS_DIR/server.key" 2048 2>/dev/null
openssl req -new -key "$CERTS_DIR/server.key" \
  -subj "/CN=$HOSTNAME_SHORT" \
  -out "$CERTS_DIR/server.csr"

cat > "$CERTS_DIR/server.ext" <<EOF
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage=digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=$SAN_STRING
EOF

openssl x509 -req -in "$CERTS_DIR/server.csr" \
  -CA "$CERTS_DIR/ca.crt" -CAkey "$CERTS_DIR/ca.key" -CAcreateserial \
  -out "$CERTS_DIR/server.crt" -days 398 -sha256 \
  -extfile "$CERTS_DIR/server.ext"

chmod 600 "$CERTS_DIR/server.key"
rm -f "$CERTS_DIR/server.csr" "$CERTS_DIR/server.ext" "$CERTS_DIR/ca.srl"

echo
echo "Done."
echo "  Root CA:      $CERTS_DIR/ca.crt"
echo "  Server cert:  $CERTS_DIR/server.crt"
echo "  SANs:"
for s in "${SAN_ENTRIES[@]}"; do echo "    - $s"; done
echo
echo "To trust HTTPS on a phone (needed for GPS on the maps page):"
echo "  1. Copy $CERTS_DIR/ca.crt to the phone (AirDrop / email / download)."
echo "  2. iOS: Settings → VPN & Device Management → Install profile,"
echo "          then Settings → General → About → Certificate Trust Settings → enable."
echo "  3. Android: Settings → Security → Install a certificate → CA certificate."
echo
echo "Then restart the web container so nginx picks up the new cert:"
echo "  docker compose restart web"
