# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A Docker Compose stack for a self-hosted smart home: Home Assistant + Mosquitto, plus optional Zigbee2MQTT, matter.js Server, and Music Assistant. The repo ships only the orchestration: `compose.yaml`, `.env`, and shell scripts under `scripts/`. All runtime state (HA config, MQTT data, Z2M data, etc.) lives in directories that are **created by the scripts and gitignored** — they don't exist in a fresh checkout.

## Common commands

All scripts are run from the repo root and `cd` themselves there, so absolute paths also work.

```sh
bash scripts/setup.sh    # one-time: clean install, generates secrets, starts stack
bash scripts/update.sh   # pull pinned images, restart, clean old layers
bash scripts/stop.sh     # docker compose down (all profiles)

bash scripts/install-themes.sh                # then: docker compose restart homeassistant
bash scripts/install-custom-integrations.sh   # then: docker compose restart homeassistant
bash scripts/install-cards.sh                 # stop HA first, run, then start HA
```

There are no tests, no linter config, no build step. Shell scripts use `set -euo pipefail` and should stay shellcheck-clean.

## Architecture and conventions

**Two-file env split.** `.env` (gitignored values like `MOSQUITTO_PASSWORD`, `Z2MPATH`, plus user-tunable things like `TZ`, `ZIGBEE_CHANNEL`, `COMPOSE_PROFILES`) and `scripts/packages.env` (pinned image tags and add-on versions). Both are sourced by every script via `set -a; source ...; set +a`. `compose.yaml` references variables from both files; nothing in compose is `:latest`.

**Optional services are profiles, not separate compose files.** `z2m`, `matter`, `matter-hub`, `music`. The `z2m` profile is **auto-managed by setup.sh and update.sh** based on whether a Zigbee coordinator is detected under `/dev/serial/by-id/` — they edit `COMPOSE_PROFILES` in `.env` accordingly. Don't hand-edit the `z2m` entry; let the scripts reconcile it. Other profiles are user-controlled.

**`matter` vs `matter-hub` are different directions.** `matter` is matter.js Server — Matter controller, brings external Matter devices **into** HA. `matter-hub` is home-assistant-matter-hub — bridges HA entities **out** as Matter devices for Apple/Google/Alexa. They're independent; you can run either, both, or neither.

**Headless HA onboarding always runs in setup.sh.** 
`setup.sh` walks the entire HA onboarding API: `POST /api/onboarding/users` (creates the hardcoded `admin` user with the master password — same hex string used as matter-hub HTTP basic-auth password and as the z2m frontend `auth_token`), `/auth/token` to swap the auth_code for a short-lived access_token, then a WebSocket call (`auth/long_lived_access_token`) for a 10-year token, and finally `core_config` / `analytics` / `integration` to flip the rest of the wizard to "done". The long-lived token goes into `.env` as `HAMH_HOME_ASSISTANT_ACCESS_TOKEN`; the master password into `homeassistant/raw.txt` and stdout. The WebSocket call is run via `docker compose exec homeassistant python3` to avoid adding a host-side websockets dependency. If `matter-hub` *is* in profiles, a second `docker compose up -d` (Stage 2) starts the bridge after the token is on disk; otherwise Stage 2 is skipped.

**Single master password.** `setup.sh` generates ONE 16-byte hex value and reuses it as `HA_ADMIN_PASSWORD` (HA admin login), `HAMH_HTTP_AUTH_PASSWORD` (matter-hub web UI basic auth, username `admin` is hardcoded in compose.yaml), and `Z2M_AUTH_TOKEN` (zigbee2mqtt frontend `auth_token`). The Mosquitto password is intentionally separate — that one is a service-to-service credential, not a UI password.

**`setup.sh` is for clean installs only.** It refuses to run if any of `homeassistant/`, `mosquitto/`, `zigbee2mqtt/`, `matter-server/`, `music-assistant/` already exist. For an existing stack, use `update.sh`. Reset = `stop.sh` + `rm -rf` those dirs + `git checkout -- .env` + `setup.sh`.

**Volumes are operator-owned after first install.** `update.sh` does **not** regenerate config files in volumes (`mosquitto/config/mosquitto.conf`, `zigbee2mqtt/data/configuration.yaml`, HA's `.storage/*`). These are templated only on the initial `setup.sh` from `scripts/addons_conf/{mosquitto,zigbee2mqtt,ha_integrations}/` via `envsubst`. If you change a template, it won't propagate to a running install — say so explicitly.

**MQTT is pre-seeded.** `setup.sh` writes `homeassistant/.storage/core.config_entries` from a template before HA's first start, so the MQTT integration is configured automatically. `mosquitto-docker-entrypoint.sh` (bind-mounted into the container) hashes `MOSQUITTO_PASSWORD` into a passwd file on first start. The plaintext is also kept in `mosquitto/raw.txt` (chmod 600, gitignored).

**Mosquitto 2.1 quirk.** The alpine image doesn't ship the auth plugin, so the config uses the deprecated `password_file` option on purpose. Don't "modernize" it.

**Custom-content scripts (`install-themes.sh`, `install-custom-integrations.sh`, `install-cards.sh`).** Idempotent: they download pinned releases from GitHub into `homeassistant/themes/`, `homeassistant/custom_components/`, `homeassistant/www/community/` respectively. `install-cards.sh` additionally writes `homeassistant/.storage/lovelace_resources` so cards register without manual UI steps. To bump a version, edit `scripts/packages.env` and re-run the relevant script.

**`upsert_env_var`** (defined in both `setup.sh` and `update.sh`) is the only sanctioned way to mutate `.env` from a script — it preserves the rest of the file. Use it; don't append blindly.

**Networking.** `homeassistant`, `zigbee2mqtt`, `matter-server`, `music-assistant` all run with `network_mode: host` (required for discovery / Bluetooth / Matter / mDNS). Only `mosquitto` publishes a port. HA runs `privileged: true` for USB/Bluetooth access.

## Editing rules specific to this repo

- Never commit `.env` after `setup.sh` (it then contains the generated MQTT password and resolved `Z2MPATH`). The shipped `.env` is the defaults-only template.
- Never pin to `:latest` in `compose.yaml` or in any installer script — versions go in `scripts/packages.env`.
- Scripts must remain idempotent and runnable from any CWD. Keep the `SCRIPT_DIR` / `cd "$REPO_ROOT"` preamble.
- HA YAML uses the modern syntax (`triggers:` / `actions:` / `action:` inside actions, modern `template:` format). Current HA series pinned: see `HA_VERSION` in `scripts/packages.env`.
