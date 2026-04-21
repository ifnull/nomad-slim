# N.O.M.A.D. Slim

A Pi-class subset of [Project N.O.M.A.D.](../README.md): **Kiwix library, Kolibri
education, and offline maps only**. No Ollama, no MySQL/Redis, no admin UI.

## What you get

| Service | URL | Purpose |
|---------|-----|---------|
| Landing page | http://localhost:8080 | Links to everything below |
| Information Library (Kiwix) | http://localhost:8090 | Serves `.zim` files from `data/zim/` |
| Education Platform (Kolibri) | http://localhost:8300 | Khan Academy etc., data in `data/kolibri/` |
| Offline Maps | http://localhost:8080/maps.html | MapLibre + PMTiles viewer over `data/maps/` |

## Requirements

- Docker + Docker Compose
- Internet connection for the first `docker compose up --build` (to pull images and vendor the MapLibre JS). After that, fully offline.

## Usage

### One-shot install (Raspberry Pi OS, Debian, Ubuntu)

On a fresh Pi, run:

```bash
curl -fsSL https://raw.githubusercontent.com/ifnull/nomad-slim/refs/heads/main/scripts/install.sh | sudo bash
```

Or if you've already cloned the repo:

```bash
sudo ./scripts/install.sh
```

Either path installs `curl`/`jq`/`git`, prompts to install Docker if missing,
clones to `/opt/nomad-slim` (skipped if you ran it from an existing clone),
creates a `nomad-slim.service` systemd unit so everything starts on boot,
offers to download content, and prints the service URLs at the end.
Idempotent — safe to re-run.

### Manual

```bash
cd nomad-slim
docker compose up -d --build
```

Then open <http://localhost:8080>.

### Adding content

- **ZIM files** (Wikipedia, medical, survival, etc.) — drop them in `data/zim/`
  then `docker compose restart kiwix`. Get ZIMs from
  [library.kiwix.org](https://library.kiwix.org), or run the included picker
  which uses project-nomad's curated category/tier manifest:

  ```bash
  ./scripts/fetch-zims.sh            # interactive: pick category + tier
  ./scripts/fetch-zims.sh --refresh  # re-pull the manifest
  ```

- **Maps** — drop Protomaps `.pmtiles` files in `data/maps/`. No restart needed;
  the viewer rediscovers them on reload. Get regional US extracts from
  project-nomad with the included picker:

  ```bash
  ./scripts/fetch-maps.sh            # pick region + state(s)
  ./scripts/fetch-maps.sh --refresh  # re-pull the manifest
  ```

  Or grab arbitrary regions from <https://maps.protomaps.com>.

- **Labeled basemap (optional)** — by default the viewer renders a
  label-free style so it makes zero external requests. To get roads/place
  labels with a full Protomaps style, fetch the glyph/sprite bundle once:

  ```bash
  ./scripts/fetch-basemap-assets.sh  # ~21 MB, one-time
  docker compose restart web
  ```

  The viewer auto-switches to the labeled style once the assets are present.

- **Kolibri** — use Kolibri's built-in setup wizard at port 8300.

### Stopping

```bash
docker compose down
```

## Trade-offs vs. the full Command Center

Removed:
- AI Assistant (Ollama + Qdrant) — the main reason this exists
- Admin UI, MySQL, Redis, Dozzle, updater, disk-collector
- Setup Wizard, ZIM remote browser, Maps region picker UI
- CyberChef, FlatNotes, Benchmark

Kept:
- Kiwix ZIM serving
- Kolibri
- Offline maps (Protomaps PMTiles)

The maps viewer ships with a minimal label-free style out of the box and
auto-upgrades to the full Protomaps style (labels, sprites, 70+ layers) once
you run `./scripts/fetch-basemap-assets.sh`. Multiple themes and the admin
region-picker UI are still full-N.O.M.A.D.-only.

## Resource footprint

Idle, no content loaded: ~100–150 MB RAM total across all three containers.
Fits comfortably on a Pi 4 / Pi 5 / Pi Zero 2 W.
