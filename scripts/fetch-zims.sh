#!/usr/bin/env bash
# Interactive ZIM downloader for N.O.M.A.D. Slim.
#
# Pulls project-nomad's curated manifests (categories + Wikipedia editions),
# lets you pick a collection, then downloads the matching .zim files into
# ./data/zim/. Picking a category tier auto-includes lower tiers it inherits.

set -euo pipefail

CATEGORIES_URL="https://raw.githubusercontent.com/Crosstalk-Solutions/project-nomad/refs/heads/main/collections/kiwix-categories.json"
WIKIPEDIA_URL="https://raw.githubusercontent.com/Crosstalk-Solutions/project-nomad/refs/heads/main/collections/wikipedia.json"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ZIM_DIR="$REPO_ROOT/data/zim"
CAT_CACHE_UPSTREAM="$REPO_ROOT/data/.kiwix-categories-upstream.json"
CAT_CACHE="$REPO_ROOT/data/.kiwix-categories.json"
EXTRA_CATEGORIES="$REPO_ROOT/collections/kiwix-categories-extra.json"
WIKI_CACHE="$REPO_ROOT/data/.kiwix-wikipedia.json"

for dep in jq curl; do
  command -v "$dep" >/dev/null 2>&1 || { echo "error: '$dep' is required" >&2; exit 1; }
done

mkdir -p "$ZIM_DIR"

refresh=0
[ "${1:-}" = "--refresh" ] && refresh=1

fetch() {
  # $1=url $2=cache
  if [ ! -f "$2" ] || [ "$refresh" = "1" ]; then
    echo "Fetching $(basename "$2")..."
    curl -fsSL "$1" -o "$2"
  fi
}
fetch "$CATEGORIES_URL" "$CAT_CACHE_UPSTREAM"
fetch "$WIKIPEDIA_URL" "$WIKI_CACHE"

# Merge upstream categories with our local extras (Trades, Agriculture, Communications).
if [ -f "$EXTRA_CATEGORIES" ]; then
  jq -s '.[0] as $up | .[1] as $ex | $up | .categories += $ex.categories' \
    "$CAT_CACHE_UPSTREAM" "$EXTRA_CATEGORIES" > "$CAT_CACHE"
else
  cp "$CAT_CACHE_UPSTREAM" "$CAT_CACHE"
fi

TTY_IN=/dev/stdin
if { : </dev/tty; } 2>/dev/null; then TTY_IN=/dev/tty; fi

prompt_number() {
  # $1=prompt $2=max (1..N valid)
  local ans
  while :; do
    read -rp "$1" ans <"$TTY_IN" || { echo "error: no interactive input available" >&2; exit 1; }
    [[ "$ans" =~ ^[0-9]+$ ]] && [ "$ans" -ge 1 ] && [ "$ans" -le "$2" ] && { echo "$ans"; return; }
    echo "  enter a number between 1 and $2" >&2
  done
}

# --- top-level menu: categories + Wikipedia -------------------------------
mapfile -t cat_slugs < <(jq -r '.categories[].slug' "$CAT_CACHE")
mapfile -t cat_names < <(jq -r '.categories[].name' "$CAT_CACHE")

echo
echo "Collections:"
idx=1
for i in "${!cat_names[@]}"; do
  size=$(jq -r --arg s "${cat_slugs[$i]}" \
    '[.categories[] | select(.slug==$s) | .tiers[].resources[].size_mb] | add // 0' "$CAT_CACHE")
  printf "  %2d) %-28s (%d MB all tiers)\n" "$idx" "${cat_names[$i]}" "$size"
  idx=$((idx+1))
done
wiki_idx=$idx
printf "  %2d) %-28s (editions from 313 MB to 118 GB)\n" "$wiki_idx" "Wikipedia"

choice=$(prompt_number "Pick a collection [1-$wiki_idx]: " "$wiki_idx")

urls=()
titles=()
sizes=()
label=""

if [ "$choice" -eq "$wiki_idx" ]; then
  # --- Wikipedia picker ----------------------------------------------------
  mapfile -t wiki_ids   < <(jq -r '.options[] | select(.url != null) | .id' "$WIKI_CACHE")
  mapfile -t wiki_names < <(jq -r '.options[] | select(.url != null) | .name' "$WIKI_CACHE")

  echo
  echo "Wikipedia editions:"
  for i in "${!wiki_names[@]}"; do
    id="${wiki_ids[$i]}"
    desc=$(jq -r --arg id "$id" '.options[] | select(.id==$id) | .description' "$WIKI_CACHE")
    sz=$(  jq -r --arg id "$id" '.options[] | select(.id==$id) | .size_mb'     "$WIKI_CACHE")
    printf "  %2d) %-32s %6d MB — %s\n" "$((i+1))" "${wiki_names[$i]}" "$sz" "$desc"
  done
  wchoice=$(prompt_number "Pick an edition [1-${#wiki_names[@]}]: " "${#wiki_names[@]}")
  wid="${wiki_ids[$((wchoice-1))]}"

  while IFS=$'\t' read -r u title size; do
    urls+=("$u"); titles+=("$title"); sizes+=("$size")
  done < <(jq -r --arg id "$wid" \
    '.options[] | select(.id==$id) | [.url,.name,.size_mb] | @tsv' "$WIKI_CACHE")

  label="Wikipedia: ${wiki_names[$((wchoice-1))]}"
else
  # --- category + tier flow ------------------------------------------------
  cat_slug="${cat_slugs[$((choice-1))]}"
  cat_name="${cat_names[$((choice-1))]}"

  mapfile -t tier_slugs < <(jq -r --arg s "$cat_slug" \
    '.categories[] | select(.slug==$s) | .tiers[].slug' "$CAT_CACHE")
  mapfile -t tier_names < <(jq -r --arg s "$cat_slug" \
    '.categories[] | select(.slug==$s) | .tiers[].name' "$CAT_CACHE")

  echo
  echo "Tiers for $cat_name:"
  for i in "${!tier_names[@]}"; do
    desc=$(jq -r --arg s "${tier_slugs[$i]}" \
      '.categories[].tiers[] | select(.slug==$s) | .description' "$CAT_CACHE")
    printf "  %2d) %-14s — %s\n" "$((i+1))" "${tier_names[$i]}" "$desc"
  done

  tchoice=$(prompt_number "Pick a tier [1-${#tier_names[@]}]: " "${#tier_names[@]}")
  tier_slug="${tier_slugs[$((tchoice-1))]}"

  resolved=()
  cursor="$tier_slug"
  while [ -n "$cursor" ]; do
    resolved=("$cursor" "${resolved[@]}")
    cursor=$(jq -r --arg s "$cursor" \
      '.categories[].tiers[] | select(.slug==$s) | .includesTier // ""' "$CAT_CACHE")
  done

  for t in "${resolved[@]}"; do
    while IFS=$'\t' read -r u title size; do
      urls+=("$u"); titles+=("$title"); sizes+=("$size")
    done < <(jq -r --arg s "$t" \
      '.categories[].tiers[] | select(.slug==$s) | .resources[] | [.url,.title,.size_mb] | @tsv' "$CAT_CACHE")
  done

  label="Tier chain: ${resolved[*]}"
fi

# --- summary + confirm -----------------------------------------------------
total=0
for s in "${sizes[@]}"; do total=$((total + s)); done

echo
echo "$label"
echo "Files to download into $ZIM_DIR:"
for i in "${!urls[@]}"; do
  printf "  %-45s %6d MB\n" "${titles[$i]}" "${sizes[$i]}"
done
printf "  %-45s %6d MB total\n" "---" "$total"

echo
read -rp "Proceed with download? [y/N] " ans <"$TTY_IN"
[[ "$ans" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

# --- download --------------------------------------------------------------
for i in "${!urls[@]}"; do
  url="${urls[$i]}"
  fname="$(basename "$url")"
  out="$ZIM_DIR/$fname"
  echo
  echo "[$((i+1))/${#urls[@]}] $fname"
  curl -fL --progress-bar -C - -o "$out" "$url" || {
    echo "  download failed, continuing" >&2
    continue
  }
done

echo
echo "Done. Kiwix picks up new files automatically (--monitorLibrary),"
echo "but if you want to force a reload: docker compose restart kiwix"
