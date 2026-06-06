# home-assistant-web3-build

Docker Compose stack for a self-hosted smart home, opinionated and pinned:

- **Home Assistant Core** — host networking, privileged for Bluetooth/USB
- **Eclipse Mosquitto** — MQTT broker with auto-generated hashed password
- **Zigbee2MQTT** *(optional)* — auto-enabled when a Zigbee coordinator is attached
- **matter.js Server** *(optional)* — Matter controller, brings devices **into** HA
- **Home Assistant Matter Hub** *(optional)* — exports HA entities **out** as Matter devices (Apple/Google/Alexa)

All image versions are pinned in `scripts/packages.env`. Custom themes, integrations, and Lovelace cards are installed by separate scripts under `scripts/`, also pinned to specific releases.

## Prerequisites

- **Docker Engine** with the Compose plugin (not Docker Desktop): https://docs.docker.com/engine/install/ubuntu/. Add yourself to the `docker` group: `sudo usermod -aG docker $USER` (re-login after).
- **System packages**: `sudo apt-get install -y git curl unzip openssl gettext-base` — needed for cloning, downloading add-ons, unzipping the camera card, generating the Mosquitto password, and `envsubst` config templating.
- **Hardware**: plug your Zigbee coordinator in **before** running `setup.sh`. The script detects it through `/dev/serial/by-id/` and asks if you want to continue without it when nothing is found.

## Configuration

```sh
git clone https://github.com/PaTara43/home-assistant-web3-build
cd home-assistant-web3-build
```

Edit `.env`. Defaults are sane for most setups:

- `TZ` — IANA time zone (e.g. `Europe/Moscow`).
- `ZIGBEE_CHANNEL` — 11–26. Channels 11/15/20/25 are typically least congested.
- `ZIGBEE_ADAPTER` — adapter type (`ember` for Sonoff ZBDongle-E, `zstack` for ZBDongle-P, see `.env` comments for the rest).
- `COMPOSE_PROFILES` — comma-separated optional profiles: `matter`, `matter-hub`, `z2m` (auto-added if a coordinator is detected). Leave empty for HA + Mosquitto only.

Pinned image and add-on versions live in `scripts/packages.env`. Touch only if you know what you're doing.

> ⚠️ **`setup.sh` will populate `.env` with generated secrets** (Mosquitto password, HA admin password, matter-hub HTTP password, HA long-lived token, resolved Z2MPATH). The shipped `.env` is the defaults-only template. **Do not commit `.env` after running setup.**

## Scripts

All scripts live under `scripts/` and `cd` to the repo root themselves, so absolute paths also work.

### `setup.sh` — initial install

**Run once on a clean Ubuntu host.** The script refuses to run if any of `homeassistant/`, `mosquitto/`, `zigbee2mqtt/`, `matter-server/`, `matter-hub/` already exist (use `update.sh` for an existing stack, or [reset](#reset-start-over)).

What it does:

1. Sanity-checks Docker, the `docker` group, `envsubst`, `.env`.
2. Detects a Zigbee coordinator (or asks to continue without).
3. Generates two secrets: a Mosquitto password (service-to-service) and a **single master password** reused as the HA admin password, the matter-hub HTTP basic-auth password, and the zigbee2mqtt frontend `auth_token`.
4. Renders Mosquitto and Zigbee2MQTT configs from templates under `scripts/addons_conf/`, pre-seeds HA's MQTT integration via `homeassistant/.storage/core.config_entries`.
5. Brings the stack up (Stage 1, without matter-hub), waits for HA's API.
6. Runs the **full HA onboarding headlessly** through the API: creates the `admin` user, mints a 10-year long-lived token via the WebSocket API, and POSTs `core_config` / `analytics` / `integration` to finish the wizard. The token is persisted in `.env` as `HAMH_HOME_ASSISTANT_ACCESS_TOKEN`. Location/units are HA defaults — change later in Settings → System → General.
7. If `matter-hub` is in `COMPOSE_PROFILES`, runs Stage 2 to start matter-hub now that the token is on disk.
8. Prints all generated credentials in a final block.

```sh
bash scripts/setup.sh
```

### `update.sh` — pull new versions, restart

Run after editing `scripts/packages.env` or to pull the latest pinned images. Snapshots running images, reconciles Zigbee state (asks only when something changed — stick added/removed/swapped), `docker compose pull && down && up -d`, removes stale image layers.

```sh
bash scripts/update.sh
```

> Volumes are operator-owned after the first install. `update.sh` does **not** regenerate config files inside volumes — edit them in place or via service UIs.

### `stop.sh` — stop everything

```sh
bash scripts/stop.sh
```

Brings down all containers regardless of which profiles are currently active (incl. all optional profiles).

### `install-themes.sh` / `install-custom-integrations.sh` / `install-cards.sh`

Idempotent installers that pull pinned releases from GitHub into `homeassistant/themes/`, `homeassistant/custom_components/`, `homeassistant/www/community/` respectively. To bump a version, edit the relevant `*_VERSION` in `scripts/packages.env` and re-run.

```sh
bash scripts/install-themes.sh                # then: docker compose restart homeassistant
bash scripts/install-custom-integrations.sh   # then: docker compose restart homeassistant
docker compose stop homeassistant && bash scripts/install-cards.sh && docker compose start homeassistant
```

`install-cards.sh` also writes `homeassistant/.storage/lovelace_resources` so cards register without manual UI steps. After updating cards, hard-reload the page (Ctrl+Shift+R) — no cache-busting query strings are added by design.

The full list of installed themes / integrations / cards is in `scripts/packages.env` (the `*_VERSION` keys are the source of truth) and at the top of each installer script.

## Service URLs

| Service          | URL                                            | Profile      |
|------------------|------------------------------------------------|--------------|
| Home Assistant   | http://localhost:8123                          | always on    |
| Zigbee2MQTT      | http://localhost:8099/?token=<master-password> | `z2m`        |
| Matter Server WS | ws://localhost:5580/ws                         | `matter`     |
| Matter Hub       | http://localhost:8482                          | `matter-hub` |

MQTT broker on `localhost:1883`, user `connectivity`, password in `mosquitto/raw.txt`. Z2M and HA's MQTT integration are wired to it automatically. matter-hub's web UI is protected with HTTP basic auth (`admin` / master password). Login to HA / matter-hub / z2m all use the same master password — `setup.sh` prints it at the end and stores it in `homeassistant/raw.txt`.

## Notes per service

### Mosquitto

Upstream `eclipse-mosquitto` image; `mosquitto-docker-entrypoint.sh` is bind-mounted in and hashes the password on first start. We use the legacy `password_file` option on purpose — Mosquitto 2.1 deprecated it in favor of a plugin, but the alpine image doesn't ship the plugin binary.

### Matter Server (matter.js)

Host networking, WebSocket on `5580`. After enabling the `matter` profile, add the **Matter** integration in HA pointed at `ws://localhost:5580/ws`. Bluetooth commissioning works via HA's privileged host networking. Thread devices need a separate Thread Border Router. The server fetches PAA certificates from the [DCL](https://on.dcl.csa-iot.org) lazily — DCL timeouts in logs are non-fatal, devices still commission.

### Home Assistant Matter Hub

The **opposite direction** from `matter-server`: bridges HA entities **out** as Matter devices for Apple/Google/Alexa. Image: `ghcr.io/riddix/home-assistant-matter-hub`, pinned in `scripts/packages.env`.

The HA long-lived access token is **always** minted by `setup.sh` (regardless of whether `matter-hub` is in profiles), so adding the profile later and running `update.sh` Just Works. The web UI on `:8482` is HTTP-basic-auth-protected (`admin` / master password). Open it to configure which entities to expose, then commission the bridge from your ecosystem of choice.

**Don't delete the `admin` HA user** — the matter-hub token is bound to it. Use it as your daily login, or create a personal account next to it.

Matter requires IPv6 + UDP + mDNS end-to-end. On VLAN'd networks or hosts without Docker IPv6, expect commissioning failures — see the [project's troubleshooting docs](https://riddix.github.io/home-assistant-matter-hub/guides/connectivity-issues).

## Reset (start over)

```sh
bash scripts/stop.sh
rm -rf homeassistant/ mosquitto/ zigbee2mqtt/ matter-server/ matter-hub/
git checkout -- .env
bash scripts/setup.sh
```

## License

Apache-2.0

## Related tools

### Music Assistant + Bluetooth Bridge

[music-assistant-bt-bridge](https://github.com/PaTara43/music-assistant-bt-bridge) — Software stack to play Music On BT devices connected to Home Assistant with Music Assistant. 
