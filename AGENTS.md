# AGENTS.md

Guidance for AI agents working in this repo. `CLAUDE.md` mirrors this for Claude Code — keep them in sync.

## What this is

Docker Compose orchestration for a self-hosted smart home: Home Assistant + Mosquitto, plus optional Zigbee2MQTT (`z2m`), matter.js Server (`matter`), and Home Assistant Matter Hub (`matter-hub`). No application code — only `compose.yaml`, `.env`, and shell scripts under `scripts/`. Runtime state lives in gitignored dirs (`homeassistant/`, `mosquitto/`, `zigbee2mqtt/`, `matter-server/`, `matter-hub/`) created by the scripts.

## No tests, no lint, no build, no Python project

Pure shell. Don't hunt for `npm test` / `pytest` / `ruff` — there's nothing to run. Scripts use `set -euo pipefail`; keep them shellcheck-clean. Inline `python3` in `setup.sh` is only for JSON parsing (system python or `docker exec`), not a project dependency — the global venv rules do not apply.

## Commands (run from anywhere — scripts self-cd to repo root)

```sh
bash scripts/setup.sh    # CLEAN install only; refuses if runtime dirs exist
bash scripts/update.sh   # existing stack: pull pinned images, restart, clean old
bash scripts/stop.sh      # docker compose down (all profiles)
bash scripts/install-themes.sh              # then: docker compose restart homeassistant
bash scripts/install-custom-integrations.sh # then: docker compose restart homeassistant
bash scripts/install-cards.sh               # stop HA first, run, then start HA
```

## Env: two files, both sourced every run

- `template.env` — tracked defaults-only template; copy to `.env` (gitignored) and edit. User-tunable (`TZ`, `ZIGBEE_CHANNEL`, `ZIGBEE_ADAPTER`, `COMPOSE_PROFILES`) + secret slots filled by `setup.sh`.
- `scripts/packages.env` — pinned image/add-on tags. **No `:latest` anywhere.** Bump a version here, then re-run the relevant script.

Both loaded via `set -a; source ./.env; source ./scripts/packages.env; set +a`.

## Critical rules

- **`.env` is gitignored** — it contains `MOSQUITTO_PASSWORD`, `Z2MPATH`, `HA_ADMIN_PASSWORD`, `HAMH_*` tokens after `setup.sh`. Commit only `template.env`.
- **`setup.sh` is clean-install only.** It aborts if any runtime dir exists. Reset = `bash scripts/stop.sh && rm -rf homeassistant mosquitto zigbee2mqtt matter-server matter-hub && rm -f .env && cp template.env .env && bash scripts/setup.sh`.
- **Volumes are operator-owned.** `update.sh` does NOT regenerate configs in volumes (`mosquitto/config/mosquitto.conf`, `zigbee2mqtt/data/configuration.yaml`, HA `.storage/*`). They're rendered from `scripts/addons_conf/` via `envsubst` only on first `setup.sh`. Template edits don't propagate to running installs — say so explicitly to the user.
- **`upsert_env_var`** (in `setup.sh` and `update.sh`) is the only sanctioned `.env` mutator — it preserves the rest of the file. Don't append blindly.
- **Scripts must stay idempotent** and keep the `SCRIPT_DIR` / `cd "$REPO_ROOT"` preamble so they run from any CWD.

## Profiles

`z2m`, `z2m2`, `matter`, `matter-hub` (comma-separated in `COMPOSE_PROFILES`). `z2m` is **auto-reconciled** by `setup.sh`/`update.sh` — don't hand-edit it. `z2m2`, `matter` and `matter-hub` are user-controlled.

- `matter` = matter.js Server — brings external Matter devices **into** HA.
- `matter-hub` = home-assistant-matter-hub — bridges HA entities **out** as Matter devices (Apple/Google/Alexa). Independent; run either, both, or neither.
- `z2m2` = second Zigbee2MQTT instance (e.g. two floors). See below.

## Zigbee transport: usb vs tcp

`Z2M_TRANSPORT` in `.env` selects how `zigbee2mqtt` reaches the coordinator. **Don't hand-edit the `z2m` profile** for either transport.

- **`usb` (default)** — coordinator auto-detected from `/dev/serial/by-id/`; mapped into the container as `/dev/ttyACM0` (`Z2M_DEVICE_MAP=${Z2MPATH}:/dev/ttyACM0`). `setup.sh` and `update.sh` reconcile the profile when the stick is added/removed/swapped (truth table in `update.sh`).
- **`tcp`** — PoE coordinators (e.g. SMLight SLZB-06). Set `Z2M_TCP_HOST`, `Z2M_TCP_PORT` (default 6638), `Z2M_BAUDRATE` (115200 for SLZB-06), and `ZIGBEE_ADAPTER` to the chip family (SLZB-06 → `zstack`). `Z2M_DEVICE_MAP=/dev/null:/dev/null` (no device to map; host networking reaches it). USB detection and stick reconciliation in `update.sh` are **skipped**; profile `z2m` stays enabled. Config template: `scripts/addons_conf/zigbee2mqtt/configuration.yaml.tcp.tpl`.

## Second Zigbee instance (z2m2)

Optional, for two coordinators (e.g. two floors). Enable by adding `z2m2` to `COMPOSE_PROFILES`; configure the `Z2M2_*` block in `.env`. `z2m2` is **never auto-enabled**.

- Instances must differ in `ZIGBEE_CHANNEL`/`Z2M2_CHANNEL`, `Z2M_FRONTEND_PORT`/`Z2M2_FRONTEND_PORT`, and `Z2M_BASE_TOPIC`/`Z2M2_BASE_TOPIC`. `setup.sh`/`update.sh` validate and refuse to start on collisions.
- **`usb+usb` is rejected** — use `usb+tcp` or `tcp+tcp`.
- Both instances share `Z2M_AUTH_TOKEN` (frontend auth) and the Mosquitto broker; HA picks up both via MQTT discovery (distinct base topics).
- Config is rendered from the **same** `configuration.yaml.{usb,tcp}.tpl` templates as instance 1 — `setup.sh` uses `env VAR=val envsubst` to override shared variable names with `Z2M2_*` values for the second render, without touching the script's own environment.
- Data volume: `zigbee2mqtt2/data/` (separate from instance 1).

## Secrets model

`setup.sh` generates ONE master password (16-byte hex) reused as `HA_ADMIN_PASSWORD` (HA admin login), `HAMH_HTTP_AUTH_PASSWORD` (matter-hub UI, username `admin` hardcoded in compose), and `Z2M_AUTH_TOKEN` (z2m frontend). **Mosquitto's password is separate** (service-to-service). Plaintexts land in `*/raw.txt` (chmod 600, gitignored).

## setup.sh runs headless HA onboarding + two-stage startup

1. Stage 1: `docker compose up` **without** `matter-hub` (it needs an HA token first).
2. Wait for HA API, `POST /api/onboarding/users` (admin user), swap auth_code → access_token, then a WebSocket `auth/long_lived_access_token` (3650-day token) via `docker compose exec homeassistant python3`. Finish `core_config`/`analytics`/`integration`.
3. Persist token to `.env` as `HAMH_HOME_ASSISTANT_ACCESS_TOKEN`.
4. Stage 2: if `matter-hub` in profiles, `docker compose up -d` again with full profiles.

## Networking

`homeassistant`, `zigbee2mqtt`, `matter-server`, `matter-hub` → `network_mode: host` (discovery/Bluetooth/Matter/mDNS). HA is `privileged: true` for USB/BLE. Only `mosquitto` publishes a port (1883).

## Quirks worth knowing

- **Mosquitto 2.1 alpine** ships no auth plugin, so `mosquitto.conf` uses the deprecated `password_file` on purpose. Don't "modernize" it to the plugin form.
- **`install-cards.sh`** also writes `homeassistant/.storage/lovelace_resources` (backs up existing to `.bak`). HA only reads it at startup → restart HA after.
- **`update.sh`** reconciles zigbee stick state with a truth table (previous vs current `/dev/serial/by-id/`) and prompts on changes — **usb transport only**; for `tcp` it's skipped. It also guards `matter-hub` if the HA token is missing.
- HA YAML uses modern syntax (`triggers:`/`actions:`/`action:`, modern `template:`). Current HA series: `HA_VERSION` in `scripts/packages.env`.