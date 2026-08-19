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
- **Hardware**: plug your USB Zigbee coordinator in **before** running `setup.sh`. The script detects it through `/dev/serial/by-id/` and asks if you want to continue without it when nothing is found. For PoE/TCP coordinators (e.g. SMLight SLZB-06), no USB device is needed — set `Z2M_TRANSPORT=tcp` in `.env` instead (see [Configuration](#configuration)).

## Configuration

```sh
git clone https://github.com/PaTara43/home-assistant-web3-build
cd home-assistant-web3-build
cp template.env .env
```

Edit `.env`. Defaults are sane for most setups:

- `TZ` — IANA time zone (e.g. `Europe/Moscow`).
- `ZIGBEE_CHANNEL` — 11–26. Channels 11/15/20/25 are typically least congested.
- `ZIGBEE_ADAPTER` — adapter type (`ember` for Sonoff ZBDongle-E, `zstack` for ZBDongle-P, see `.env` comments for the rest).
- `Z2M_TRANSPORT` — `usb` (default, auto-detected) or `tcp` for PoE coordinators (e.g. SMLight SLZB-06). For `tcp`, also set `Z2M_TCP_HOST` and optionally `Z2M_TCP_PORT` (default 6638) and `Z2M_BAUDRATE` (SLZB-06 → 115200). `ZIGBEE_ADAPTER` must match the chip: SLZB-06 → `zstack`.
- `Z2M_FRONTEND_PORT`, `Z2M_BASE_TOPIC` — frontend port (default 8099) and MQTT base topic (default `zigbee2mqtt`) for instance 1. Change only if running a second instance.
- `COMPOSE_PROFILES` — comma-separated optional profiles: `z2m`, `z2m2`, `matter`, `matter-hub`. `z2m` is auto-added if a coordinator is detected; `z2m2` is opt-in (see [two coordinators](#two-zigbee-coordinators-optional)). Leave empty for HA + Mosquitto only.

Pinned image and add-on versions live in `scripts/packages.env`. Touch only if you know what you're doing.

> ⚠️ **`setup.sh` will populate `.env` (your copy) with generated secrets** (Mosquitto password, HA admin password, matter-hub HTTP password, HA long-lived token, resolved Z2MPATH). `.env` is gitignored; `template.env` is the tracked defaults-only template. **Do not commit `.env` after running setup.**

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

### Zigbee2MQTT

Two coordinator transports are supported, selected by `Z2M_TRANSPORT` in `.env`:

- **`usb` (default)** — the coordinator is auto-detected from `/dev/serial/by-id/` and mapped into the container as `/dev/ttyACM0`. `setup.sh` and `update.sh` reconcile the profile when a stick is added/removed/swapped.
- **`tcp`** — PoE coordinators reached over the network (e.g. SMLight SLZB-06). Set `Z2M_TRANSPORT=tcp`, `Z2M_TCP_HOST=<ip>`, `Z2M_TCP_PORT=6638` (SLZB-06 default), `ZIGBEE_ADAPTER=zstack`, and `Z2M_BAUDRATE=115200`. No USB device is mapped; `zigbee2mqtt` reaches the coordinator via host networking. USB detection and stick reconciliation in `update.sh` are skipped.

`ZIGBEE_ADAPTER` must match the coordinator's chip family, not its transport: SLZB-06 → `zstack`, Sonoff ZBDongle-E → `ember`, etc.

Adapter-specific tweaks (e.g. `disable_led`, `transmit_power` for SLZB-06) are not exposed in `.env` — edit `zigbee2mqtt/data/configuration.yaml` directly. That volume is operator-owned, so `update.sh` won't overwrite it.

#### Two Zigbee coordinators (optional)

For a large home with one coordinator per floor, add a second Zigbee2MQTT instance via the `z2m2` profile. Configure the `Z2M2_*` block in `.env` and add `z2m2` to `COMPOSE_PROFILES`:

```env
COMPOSE_PROFILES=z2m,z2m2
```

Each instance needs **distinct** values for channel, frontend port, and MQTT base topic — `setup.sh` and `update.sh` validate this and refuse to start on collisions:

| Setting              | Instance 1 (z2m)         | Instance 2 (z2m2)           |
|----------------------|--------------------------|-----------------------------|
| Channel              | `ZIGBEE_CHANNEL=11`      | `Z2M2_CHANNEL=15`           |
| Frontend port        | `Z2M_FRONTEND_PORT=8099`  | `Z2M2_FRONTEND_PORT=8100`   |
| Base topic           | `Z2M_BASE_TOPIC=zigbee2mqtt` | `Z2M2_BASE_TOPIC=zigbee2mqtt2` |
| Transport / adapter  | `Z2M_TRANSPORT`, `ZIGBEE_ADAPTER` | `Z2M2_TRANSPORT`, `Z2M2_ADAPTER` |
| TCP (if PoE)         | `Z2M_TCP_HOST`, `Z2M_TCP_PORT`, `Z2M_BAUDRATE` | `Z2M2_TCP_HOST`, `Z2M2_TCP_PORT`, `Z2M2_BAUDRATE` |

Constraints:

- **`usb+usb` is not supported** — use `usb+tcp` or `tcp+tcp` (the scripts reject `usb+usb` with an error).
- `z2m2` is **never auto-enabled** — add it explicitly to `COMPOSE_PROFILES`. `z2m` remains auto-reconciled.
- Both instances share `Z2M_AUTH_TOKEN` for frontend auth and the Mosquitto broker; HA's MQTT integration picks up both via discovery automatically (distinct base topics).
- Data lives in `zigbee2mqtt2/data/` (separate volume from instance 1).

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
rm -f .env
cp template.env .env
bash scripts/setup.sh
```

## License

Apache-2.0

## Related tools

### Music Assistant + Bluetooth Bridge

[music-assistant-bt-bridge](https://github.com/PaTara43/music-assistant-bt-bridge) — Software stack to play Music On BT devices connected to Home Assistant with Music Assistant. 
