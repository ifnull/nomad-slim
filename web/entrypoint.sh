#!/bin/sh
# If no server cert is mounted in, generate a throwaway self-signed one so
# nginx can start. Users who want proper SANs for LAN/mDNS should run
# scripts/generate-cert.sh on the host instead.
set -e

CERT_DIR=/etc/nginx/certs
if [ ! -f "$CERT_DIR/server.crt" ] || [ ! -f "$CERT_DIR/server.key" ]; then
  echo "[entrypoint] No cert mounted at $CERT_DIR — generating a fallback self-signed cert."
  mkdir -p "$CERT_DIR"
  openssl req -x509 -newkey rsa:2048 -nodes -days 398 \
    -subj "/CN=nomad-slim" \
    -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" \
    -addext "extendedKeyUsage=serverAuth" \
    -keyout "$CERT_DIR/server.key" \
    -out "$CERT_DIR/server.crt" 2>/dev/null
  chmod 600 "$CERT_DIR/server.key"
fi

exec nginx -g 'daemon off;'
