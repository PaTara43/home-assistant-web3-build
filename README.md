# home-assistant-web3-build

Docker Compose stack for a self-hosted smart home:

- **Home Assistant Core** (network host, privileged for Bluetooth/USB access)
- **Eclipse Mosquitto** MQTT broker (with auto-generated hashed password)
- **Zigbee2MQTT** (auto-enabled when a Zigbee coordinator is attached)
- **Python Matter Server** (optional)
- **Music Assistant Server** (optional)

## Requirements

Install Docker and Docker Compose. See:

- https://docs.docker.com/engine/install/ubuntu/
- https://www.digitalocean.com/community/tutorials/how-to-install-and-use-docker-compose-on-ubuntu-22-04

Docker must be runnable without `sudo` — your user has to be in the `docker` group.

Helpers used by the scripts:

```sh
sudo apt-get install -y wget unzip git jq openssl
```

If you plan to use Zigbee2MQTT, **plug in your Zigbee coordinator before running setup.sh**.

## Configuration

```sh
git clone https://github.com/PaTara43/home-assistant-web3-build
cd home-assistant-web3-build/
```

Edit `.env` (already in the repo with sensible defaults):

- `TZ` — your IANA time zone.
- `ZIGBEE_CHANNEL` — Zigbee channel (11–26).
- `COMPOSE_PROFILES` — comma-separated list of optional profiles. Available:
  - `matter` — start Matter Server
  - `music`  — start Music Assistant Server
  - `z2m`    — Zigbee2MQTT (auto-enabled when a coordinator is detected)

  Examples: `COMPOSE_PROFILES=matter,music`, or leave empty for HA + Mosquitto only.

Pinned image versions live in `scripts/packages.env`. Touch only if you know what you're doing.

> ⚠️ **After running `scripts/setup.sh` for the first time, `.env` will contain
> a generated `MOSQUITTO_PASSWORD` and the resolved `Z2MPATH`. Do NOT commit
> these changes back to the repo.** The same password is also stored in
> `mosquitto/raw.txt`, which is gitignored.

## Run

```sh
bash scripts/setup.sh
```

When the stack is up:

| Service          | URL                          | Profile  |
|------------------|------------------------------|----------|
| Home Assistant   | http://localhost:8123        | always on |
| Zigbee2MQTT      | http://localhost:8099        | `z2m`    |
| Music Assistant  | http://localhost:8095        | `music`  |
| Matter Server WS | ws://localhost:5580/ws       | `matter` |

The MQTT broker listens on `localhost:1883`. Username `connectivity`, password is generated
on first run and stored in `mosquitto/raw.txt`. The same password is wired into
Zigbee2MQTT's `configuration.yaml` and Home Assistant's MQTT integration automatically.

## Update

```sh
bash scripts/update.sh
```

Pulls latest git changes, rebuilds image references from `scripts/packages.env`, restarts
the stack with the same profiles you started it with, and removes outdated image layers.

## Stop

```sh
bash scripts/stop.sh
```

## Notes

### Matter Server

Runs in `host` networking mode and needs `apparmor:unconfined` plus access to `/run/dbus`
for Bluetooth-based commissioning. Exposes a WebSocket on port `5580`. After enabling the
`matter` profile and starting the stack, add the **Matter** integration in HA and point
it at `ws://localhost:5580/ws`.

If you also need Thread devices, you'll need a separate Thread Border Router.

### Music Assistant

Requires `host` networking for mDNS-based player discovery, plus `SYS_ADMIN` and
`DAC_READ_SEARCH` capabilities to mount SMB shares. Uses TCP `8095` (web UI), `8097`
(audio streaming), and `3483` (slimproto).

To expose your local music library, edit `compose.yaml` and uncomment the `/media` volume
under the `music-assistant` service.

### Mosquitto

We use the upstream `eclipse-mosquitto` image directly. The `mosquitto-docker-entrypoint.sh`
script is bind-mounted in and creates a hashed password file on first start using
`mosquitto_passwd`. If Mosquitto 2.1 complains about the `mosquitto_password_file.so` plugin
path on your platform, edit `scripts/mosquitto.conf` and fall back to the legacy
`password_file` option (commented at the bottom of that file).

## Custom themes

Themes are installed via a separate script:

```sh
bash scripts/install-themes.sh
```

This is idempotent — re-run it to update to the versions pinned in `scripts/packages.env`.

Currently installed:

- **iOS themes** — [basnijholt/lovelace-ios-themes](https://github.com/basnijholt/lovelace-ios-themes), pinned to `IOS_THEMES_VERSION`
- **visionOS theme** — [Nezz/homeassistant-visionos-theme](https://github.com/Nezz/homeassistant-visionos-theme), pinned to `VISIONOS_THEME_VERSION`
- **Pinout theme** — [PinoutLTD/HA.Themes](https://github.com/PinoutLTD/HA.Themes), pinned to `PINOUT_THEME_VERSION`

Then restart Home Assistant and pick the theme in your profile settings.

## Custom integrations

Custom integrations are installed via a separate script:

```sh
bash scripts/install-custom-integrations.sh
```

This is idempotent — re-run it to update to the versions pinned in `scripts/packages.env`.

Currently installed:

- **Better Thermostat** — [KartoffelToby/better_thermostat](https://github.com/KartoffelToby/better_thermostat), pinned to `BETTER_THERMOSTAT_VERSION`
- **Browser Mod** — [thomasloven/hass-browser_mod](https://github.com/thomasloven/hass-browser_mod), pinned to `BROWSER_MOD_VERSION`
- **LocalTuya** — [rospogrigio/localtuya](https://github.com/rospogrigio/localtuya), pinned to `LOCALTUYA_VERSION`
- **Yandex Smart Home** — [dext0r/yandex_smart_home](https://github.com/dext0r/yandex_smart_home), pinned to `YANDEX_SMART_HOME_VERSION`
- **Yandex Station** — [AlexxIT/YandexStation](https://github.com/AlexxIT/YandexStation), pinned to `YANDEX_STATION_VERSION`

Then restart Home Assistant for the new integrations to load:

```sh
docker compose restart homeassistant
```

## Resetting

To wipe the stack and start over:

```sh
bash scripts/stop.sh
rm -rf homeassistant/ mosquitto/ zigbee2mqtt/ matter-server/ music-assistant/
git checkout -- .env   # restore default .env
bash scripts/setup.sh
```

## License

Apache-2.0
