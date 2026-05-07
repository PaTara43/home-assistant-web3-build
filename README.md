# home-assistant-web3-build

Docker Compose stack for a self-hosted smart home, opinionated and pinned:

- **Home Assistant Core** — host networking, privileged for Bluetooth/USB
- **Eclipse Mosquitto** — MQTT broker with auto-generated hashed password
- **Zigbee2MQTT** *(optional)* — auto-enabled when a Zigbee coordinator is attached
- **matter.js Server** *(optional)* — Matter controller exposing a WebSocket for HA
- **Home Assistant Matter Hub** *(optional)* — bridges HA entities **out** as Matter devices (Apple Home / Google Home / Alexa)
- **Music Assistant Server** *(optional)* — multi-room media server

All image versions are pinned in `scripts/packages.env`. Custom themes, integrations, and Lovelace cards are installed by separate scripts under `scripts/`, also pinned to specific releases.

## Prerequisites

### Docker

Install Docker Engine and Docker Compose plugin (not Docker Desktop):

- https://docs.docker.com/engine/install/ubuntu/

Add your user to the `docker` group so commands work without `sudo`:

```sh
sudo usermod -aG docker $USER
# then log out and log back in
```

### System packages

```sh
sudo apt-get install -y git curl unzip openssl gettext-base
```

| Package         | Used by                                            |
|-----------------|----------------------------------------------------|
| `git`           | clone / update repo                                |
| `curl`          | downloading themes, integrations, cards            |
| `unzip`        | unpacking the `advanced-camera-card` release zip   |
| `openssl`       | generating the Mosquitto password                  |
| `gettext-base`  | `envsubst` — config templating in `setup.sh`       |

### Hardware

Plug your Zigbee coordinator into a USB port **before running `setup.sh`**. The script detects it through `/dev/serial/by-id/`.

If no coordinator is plugged in, `setup.sh` will ask whether to continue without Zigbee2MQTT.

## Configuration

```sh
git clone https://github.com/PaTara43/home-assistant-web3-build
cd home-assistant-web3-build
```

Edit `.env`. The repo ships it with sensible defaults:

- `TZ` — IANA time zone (e.g. `Europe/Moscow`).
- `ZIGBEE_CHANNEL` — Zigbee channel, 11–26. Channels 11/15/20/25 are typically least congested.
- `ZIGBEE_ADAPTER` — adapter type for Zigbee2MQTT (`ember` for Sonoff ZBDongle-E, `zstack` for ZBDongle-P, see `.env` comments for the full list).
- `COMPOSE_PROFILES` — comma-separated optional profiles. Available:
  - `matter`     — Matter Server (matter.js, brings Matter devices **into** HA)
  - `matter-hub` — Home Assistant Matter Hub (exports HA entities **out** as Matter devices)
  - `music`      — Music Assistant Server
  - `z2m`        — Zigbee2MQTT (auto-added when a coordinator is detected)

  Examples: `COMPOSE_PROFILES=matter,music`, or leave empty for HA + Mosquitto only.

`setup.sh` always headlessly onboards Home Assistant: it creates a single `admin` user with a 16-byte hex password (the same password is reused as matter-hub HTTP basic-auth password and as the zigbee2mqtt frontend token — one master password for all UI surfaces), finishes the rest of the wizard via the API, mints a 10-year long-lived HA token, and prints everything at the end of setup. Mosquitto's password is independent (it's a service-to-service credential).

Pinned image versions and add-on versions live in `scripts/packages.env`. Touch only if you know what you're doing.

> ⚠️ **After `setup.sh` runs, `.env` will contain a generated `MOSQUITTO_PASSWORD` and the resolved `Z2MPATH`. Do NOT commit these changes back.** The password is also stored in `mosquitto/raw.txt`, which is gitignored.

## Scripts

All scripts live under `scripts/` and assume they are run from the repo root (`bash scripts/<name>.sh`). They `cd` to the repo root themselves, so they also work when invoked by absolute path.

### `setup.sh` — initial install

**Run once on a clean Ubuntu host.** The script refuses to run if any of the runtime data directories (`homeassistant/`, `mosquitto/`, `zigbee2mqtt/`, `matter-server/`, `matter-hub/`, `music-assistant/`) already exist.

What it does:

1. Sanity-checks `docker`, group membership, `envsubst`, and the presence of `.env`.
2. Detects a Zigbee coordinator under `/dev/serial/by-id/`. If multiple are attached, asks which one to use.
3. Generates a 16-byte hex password for Mosquitto, stores it in `mosquitto/raw.txt` (chmod 600).
4. Renders `mosquitto/config/mosquitto.conf` from the static template and `zigbee2mqtt/data/configuration.yaml` from a template under `scripts/addons_conf/`.
5. Pre-seeds Home Assistant's MQTT integration via `homeassistant/.storage/core.config_entries`, so MQTT is configured at first start without going through the UI.
6. Persists `MOSQUITTO_PASSWORD` and `Z2MPATH` back into `.env` for `update.sh` and the compose file to reuse.
7. Computes `COMPOSE_PROFILES` (adds/removes `z2m` based on stick presence), creates data directories for active optional profiles only.
8. Runs `docker compose up -d`.
9. Waits for HA's API, then runs **all four** onboarding steps headlessly: creates the `admin` user with the master password (saved to `homeassistant/raw.txt`, chmod 600), exchanges the auth code for an access token, mints a 10-year long-lived token via the WebSocket API, and POSTs `core_config` / `analytics` / `integration` to finish the wizard. The token is persisted in `.env` as `HAMH_HOME_ASSISTANT_ACCESS_TOKEN`. Location/units/currency are left at HA defaults — change them later in Settings → System → General.
10. **If `matter-hub` is in `COMPOSE_PROFILES`:** runs a second `docker compose up -d` to start matter-hub with the now-available token. matter-hub's web UI is protected with HTTP basic auth (`admin` / master password); credentials are also written to `matter-hub/raw.txt`.

```sh
bash scripts/setup.sh
```

### `update.sh` — pull new versions, restart

Run after editing `scripts/packages.env` or whenever you want to pull the latest pinned images.

What it does:

1. Snapshots image tags of currently running containers (used later for cleanup).
2. Reconciles Zigbee coordinator state and asks only when needed:
   - Same stick still attached → silent.
   - Previously disabled, now a stick is plugged → asks whether to enable z2m.
   - Stick gone → asks whether to continue without z2m.
   - Stick replaced with a different one → asks whether to switch to the new one.
3. `docker compose pull` for the active profiles.
4. `docker compose down && up -d`.
5. Removes old image layers whose tags differ from the new pins.

```sh
bash scripts/update.sh
```

> Note: `update.sh` does **not** regenerate config files in volumes (`mosquitto.conf`, `configuration.yaml`, etc.). Volumes are owned by the operator after first install — edit them in place or via service UIs.

### `stop.sh` — stop the stack

```sh
bash scripts/stop.sh
```

Brings down all containers regardless of which profiles are currently active.

### `install-themes.sh`

Downloads frontend themes pinned in `scripts/packages.env` into `homeassistant/themes/`. Idempotent — re-run to apply version bumps.

Currently installed:

- **iOS themes** — [basnijholt/lovelace-ios-themes](https://github.com/basnijholt/lovelace-ios-themes), pinned to `IOS_THEMES_VERSION`
- **visionOS theme** — [Nezz/homeassistant-visionos-theme](https://github.com/Nezz/homeassistant-visionos-theme), pinned to `VISIONOS_THEME_VERSION`
- **Pinout theme** — [PinoutLTD/HA.Themes](https://github.com/PinoutLTD/HA.Themes), pinned to `PINOUT_THEME_VERSION`

Restart Home Assistant after installing, then pick a theme under Profile.

```sh
bash scripts/install-themes.sh
docker compose restart homeassistant
```

### `install-custom-integrations.sh`

Downloads custom integrations into `homeassistant/custom_components/`. Idempotent.

Currently installed:

- **Better Thermostat** — [KartoffelToby/better_thermostat](https://github.com/KartoffelToby/better_thermostat), pinned to `BETTER_THERMOSTAT_VERSION`
- **Browser Mod** — [thomasloven/hass-browser_mod](https://github.com/thomasloven/hass-browser_mod), pinned to `BROWSER_MOD_VERSION`
- **LocalTuya** — [rospogrigio/localtuya](https://github.com/rospogrigio/localtuya), pinned to `LOCALTUYA_VERSION`
- **Yandex Smart Home** — [dext0r/yandex_smart_home](https://github.com/dext0r/yandex_smart_home), pinned to `YANDEX_SMART_HOME_VERSION`
- **Yandex Station** — [AlexxIT/YandexStation](https://github.com/AlexxIT/YandexStation), pinned to `YANDEX_STATION_VERSION`

Restart Home Assistant for new integrations to load:

```sh
bash scripts/install-custom-integrations.sh
docker compose restart homeassistant
```

### `install-cards.sh`

Downloads Lovelace cards into `homeassistant/www/community/<card-name>/`, **and** writes `homeassistant/.storage/lovelace_resources` so HA registers them automatically — no need to add each one through the UI.

Currently installed:

- `advanced-camera-card` — release zip, all bundled assets
- `better-thermostat-ui-card`
- `bubble-card` (+ `bubble-pop-up-fix.js`)
- `clock-weather-card`
- `custom-card-features`
- `ha-floorplan`
- `kiosk-mode`
- `lovelace-card-mod`
- `mini-graph-card`
- `mini-media-player`
- `mushroom`
- `navbar-card`
- `vertical-stack-in-card`

```sh
docker compose stop homeassistant
bash scripts/install-cards.sh
docker compose start homeassistant
```

> The browser caches Lovelace resources aggressively. After updating cards, hard-reload the page (Ctrl+Shift+R) or clear site data. The script does not append `?v=` cache-busting query strings on purpose; this stack is designed to be installed fresh, not patched in place.

## Service URLs

When the stack is up:

| Service          | URL                          | Profile      |
|------------------|------------------------------|--------------|
| Home Assistant   | http://localhost:8123        | always on    |
| Zigbee2MQTT      | http://localhost:8099        | `z2m`        |
| Music Assistant  | http://localhost:8095        | `music`      |
| Matter Server WS | ws://localhost:5580/ws       | `matter`     |
| Matter Hub       | http://localhost:8482        | `matter-hub` |

The MQTT broker listens on `localhost:1883`. User `connectivity`, password generated by `setup.sh` and stored in `mosquitto/raw.txt`. Both Zigbee2MQTT and Home Assistant's MQTT integration are wired to it automatically.

## Notes per service

### Mosquitto

We use the upstream `eclipse-mosquitto` image directly. The `mosquitto-docker-entrypoint.sh` script (under `scripts/addons_conf/mosquitto/`) is bind-mounted in and creates a hashed password file on first start using `mosquitto_passwd`.

Mosquitto 2.1 deprecated the `password_file` option in favor of a plugin, but the alpine image as of 2.1 doesn't ship the plugin binary. Our `scripts/addons_conf/mosquitto/mosquitto.conf` therefore uses the legacy `password_file` option (which still works in 2.1 with a deprecation warning).

### Matter Server (matter.js)

Runs in `host` networking mode. Exposes the WebSocket on port `5580`. After enabling the `matter` profile and starting the stack, add the **Matter** integration in HA pointed at `ws://localhost:5580/ws`.

The server downloads PAA root certificates and vendor info from the [DCL](https://on.dcl.csa-iot.org) on first start. If your network can't reach DCL reliably, you'll see timeouts in the logs — this does **not** prevent device commissioning. matter.js fetches certificates lazily and retries on its own schedule, so most devices still pair successfully even with DCL partially unreachable.

For Thread devices you need a separate Thread Border Router (Apple HomePod, Google Nest Hub, dedicated TBR hardware). Bluetooth commissioning is supported via the Home Assistant container's privileged host networking.

### Home Assistant Matter Hub

This is the **opposite direction** from `matter-server`: matter-hub takes entities you have in Home Assistant and re-publishes them as Matter devices, so Apple Home / Google Home / Alexa can control them. Image: `ghcr.io/riddix/home-assistant-matter-hub`, pinned to `MATTER_HUB_VERSION` in `scripts/packages.env`.

**Setup-time provisioning.** Headless HA onboarding always runs in `setup.sh`, regardless of whether `matter-hub` is enabled — this means the long-lived HA token is **always** minted on a clean install and lives in `.env`. So adding `matter-hub` to `COMPOSE_PROFILES` later and running `update.sh` Just Works: the token is already there. The matter-hub web UI is protected by HTTP basic auth (`admin` / master password from `homeassistant/raw.txt`).

**Don't delete the `admin` HA user later** — the matter-hub access token is bound to it. Use it as your daily login, or create a personal account next to it.

**Pairing the bridge.** After matter-hub is up, open `http://localhost:8482` and follow the bridge configuration UI to expose entities; then commission the bridge from your ecosystem of choice (Home app, etc.).

**Network.** Matter requires IPv6 + UDP + mDNS to work end-to-end. If you're on a VLAN'd network or have Docker without IPv6, expect commissioning failures — see the [project's troubleshooting docs](https://riddix.github.io/home-assistant-matter-hub/guides/connectivity-issues).

### Music Assistant

Requires `host` networking for mDNS-based player discovery, plus `SYS_ADMIN` and `DAC_READ_SEARCH` capabilities to mount SMB shares. Uses TCP `8095` (web UI), `8097` (audio streaming), and `3483` (slimproto).

To expose your local music library, edit `compose.yaml` and uncomment the `/media` volume under the `music-assistant` service.

## Reset (start over)

```sh
bash scripts/stop.sh
rm -rf homeassistant/ mosquitto/ zigbee2mqtt/ matter-server/ matter-hub/ music-assistant/
git checkout -- .env   # restore default .env
bash scripts/setup.sh
```

## License

Apache-2.0