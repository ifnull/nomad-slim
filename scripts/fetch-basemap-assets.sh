#!/usr/bin/env bash
# Fetches the Protomaps glyph/sprite bundle + base style from project-nomad-maps
# so the viewer can render labeled, fully-styled maps offline.
#
# Produces:
#   data/basemaps-assets/                         — fonts (PBF glyphs) + sprites (JSON/PNG)
#   data/basemaps-assets/nomad-base-styles.json   — the MapLibre style JSON
#
# Everything is bundled under one mounted directory so the web container's
# bind mount never has to resolve an individual file that might not exist yet.
# No container restart is needed after running this — nginx serves the files
# live from the mount.

set -euo pipefail

TARBALL_URL="https://github.com/Crosstalk-Solutions/project-nomad-maps/raw/refs/heads/master/base-assets.tar.gz"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DATA_DIR="$REPO_ROOT/data"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

for dep in curl tar; do
  command -v "$dep" >/dev/null 2>&1 || { echo "error: '$dep' is required" >&2; exit 1; }
done

echo "Downloading base-assets.tar.gz..."
curl -fL --progress-bar -o "$TMPDIR/base-assets.tar.gz" "$TARBALL_URL"

echo "Extracting..."
tar -xzf "$TMPDIR/base-assets.tar.gz" -C "$TMPDIR"

# Tarball root is `tozip/` — move the contents we want into place.
src="$TMPDIR/tozip"
[ -d "$src/basemaps-assets" ] || { echo "error: unexpected tarball layout" >&2; exit 1; }
[ -f "$src/nomad-base-styles.json" ] || { echo "error: style file missing from tarball" >&2; exit 1; }

# If a previous install left nomad-base-styles.json as an empty directory
# (docker creates these when a bind-mount source is missing), remove it.
if [ -d "$DATA_DIR/nomad-base-styles.json" ]; then
  rm -rf "$DATA_DIR/nomad-base-styles.json"
fi
# Legacy location — clean up stale top-level file from older installs.
[ -f "$DATA_DIR/nomad-base-styles.json" ] && rm -f "$DATA_DIR/nomad-base-styles.json"

rm -rf "$DATA_DIR/basemaps-assets"
mv "$src/basemaps-assets" "$DATA_DIR/basemaps-assets"
mv "$src/nomad-base-styles.json" "$DATA_DIR/basemaps-assets/nomad-base-styles.json"

echo
echo "Installed:"
echo "  $DATA_DIR/basemaps-assets/                       ($(du -sh "$DATA_DIR/basemaps-assets" | cut -f1))"
echo "  $DATA_DIR/basemaps-assets/nomad-base-styles.json"
echo
echo "Nginx serves these live — reload the maps page in your browser to see labels."
