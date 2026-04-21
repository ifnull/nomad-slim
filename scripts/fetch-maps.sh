#!/usr/bin/env bash
# Interactive PMTiles downloader for N.O.M.A.D. Slim.
#
# Pulls project-nomad's maps manifest, lets you pick a region, then pick
# one/several/all states within it, and downloads the matching .pmtiles files
# into ./data/maps/. The maps viewer rediscovers files on page reload — no
# container restart required.

set -euo pipefail

MAPS_URL="https://raw.githubusercontent.com/Crosstalk-Solutions/project-nomad/refs/heads/main/collections/maps.json"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MAPS_DIR="$REPO_ROOT/data/maps"
CACHE="$REPO_ROOT/data/.kiwix-maps.json"

for dep in jq curl; do
  command -v "$dep" >/dev/null 2>&1 || { echo "error: '$dep' is required" >&2; exit 1; }
done

mkdir -p "$MAPS_DIR"

refresh=0
[ "${1:-}" = "--refresh" ] && refresh=1

if [ ! -f "$CACHE" ] || [ "$refresh" = "1" ]; then
  echo "Fetching maps manifest..."
  curl -fsSL "$MAPS_URL" -o "$CACHE"
fi

prompt_number() {
  local ans
  while :; do
    read -rp "$1" ans
    [[ "$ans" =~ ^[0-9]+$ ]] && [ "$ans" -ge 1 ] && [ "$ans" -le "$2" ] && { echo "$ans"; return; }
    echo "  enter a number between 1 and $2" >&2
  done
}

# --- region menu -----------------------------------------------------------
mapfile -t region_slugs < <(jq -r '.collections[].slug' "$CACHE")
mapfile -t region_names < <(jq -r '.collections[].name' "$CACHE")

echo
echo "Map regions:"
for i in "${!region_names[@]}"; do
  size=$(jq -r --arg s "${region_slugs[$i]}" \
    '[.collections[] | select(.slug==$s) | .resources[].size_mb] | add // 0' "$CACHE")
  count=$(jq -r --arg s "${region_slugs[$i]}" \
    '[.collections[] | select(.slug==$s) | .resources[]] | length' "$CACHE")
  printf "  %2d) %-22s %2d states  %5d MB\n" "$((i+1))" "${region_names[$i]}" "$count" "$size"
done

rchoice=$(prompt_number "Pick a region [1-${#region_names[@]}]: " "${#region_names[@]}")
region_slug="${region_slugs[$((rchoice-1))]}"
region_name="${region_names[$((rchoice-1))]}"

# --- state picker ----------------------------------------------------------
mapfile -t state_urls  < <(jq -r --arg s "$region_slug" \
  '.collections[] | select(.slug==$s) | .resources[].url' "$CACHE")
mapfile -t state_titles < <(jq -r --arg s "$region_slug" \
  '.collections[] | select(.slug==$s) | .resources[].title' "$CACHE")
mapfile -t state_sizes  < <(jq -r --arg s "$region_slug" \
  '.collections[] | select(.slug==$s) | .resources[].size_mb' "$CACHE")

echo
echo "States in $region_name:"
for i in "${!state_titles[@]}"; do
  printf "  %2d) %-18s %5d MB\n" "$((i+1))" "${state_titles[$i]}" "${state_sizes[$i]}"
done
echo "  (enter 'all', a single number, or a comma-separated list like '1,3,5')"

read -rp "Pick state(s): " picks
picks="${picks// /}"

urls=()
titles=()
sizes=()

if [ "$picks" = "all" ] || [ -z "$picks" ]; then
  urls=("${state_urls[@]}")
  titles=("${state_titles[@]}")
  sizes=("${state_sizes[@]}")
else
  IFS=',' read -ra tokens <<<"$picks"
  for t in "${tokens[@]}"; do
    if ! [[ "$t" =~ ^[0-9]+$ ]] || [ "$t" -lt 1 ] || [ "$t" -gt "${#state_titles[@]}" ]; then
      echo "error: '$t' is not a valid state index" >&2
      exit 1
    fi
    urls+=("${state_urls[$((t-1))]}")
    titles+=("${state_titles[$((t-1))]}")
    sizes+=("${state_sizes[$((t-1))]}")
  done
fi

# --- summary + confirm -----------------------------------------------------
total=0
for s in "${sizes[@]}"; do total=$((total + s)); done

echo
echo "Files to download into $MAPS_DIR:"
for i in "${!urls[@]}"; do
  printf "  %-30s %5d MB\n" "${titles[$i]}" "${sizes[$i]}"
done
printf "  %-30s %5d MB total\n" "---" "$total"

echo
read -rp "Proceed with download? [y/N] " ans
[[ "$ans" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

# --- download --------------------------------------------------------------
for i in "${!urls[@]}"; do
  url="${urls[$i]}"
  fname="$(basename "$url")"
  out="$MAPS_DIR/$fname"
  echo
  echo "[$((i+1))/${#urls[@]}] $fname"
  curl -fL --progress-bar -C - -o "$out" "$url" || {
    echo "  download failed, continuing" >&2
    continue
  }
done

echo
echo "Done. The maps viewer picks up new PMTiles on page reload — no restart needed."
