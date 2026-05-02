#!/bin/bash
set -euo pipefail

# Resolve repo root from the location of this script, then cd there. This makes
# the script work whether you run `bash scripts/setup.sh` from the repo root,
# or call it by absolute path from anywhere else.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

echo "Repo root: $REPO_ROOT"
echo "This script will create runtime directories and start docker containers."

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
upsert_env_var() {
  # upsert_env_var KEY VALUE FILE -- replaces or appends "KEY=VALUE" line
  local key="$1" value="$2" file="$3"
  if [ -f "$file" ] && grep -q "^${key}=" "$file"; then
    sed -i.bak "s|^${key}=.*|${key}=${value}|" "$file" && rm -f "${file}.bak"
  else
    [ -s "$file" ] && [ "$(tail -c1 "$file")" != "" ] && echo "" >> "$file"
    echo "${key}=${value}" >> "$file"
  fi
}

# ---------------------------------------------------------------------------
# Sanity checks
# ---------------------------------------------------------------------------
if ! command -v docker &> /dev/null; then
  echo "ERROR: docker not found. Install Docker first."
  exit 1
fi
echo "Docker found."

if ! id -nG "$USER" | grep -qw "docker"; then
  echo "ERROR: $USER is not in the 'docker' group. Run: sudo usermod -aG docker \$USER"
  exit 1
fi
echo "$USER is in the docker group."

if [ ! -f .env ]; then
  echo "ERROR: .env file not found in repo root. It should be tracked by the repo."
  exit 1
fi

# ---------------------------------------------------------------------------
# Load env (defaults from .env + pinned versions from packages.env)
# Done BEFORE coordinator detection so the placeholder Z2MPATH= in .env
# doesn't overwrite the value we're about to detect.
# ---------------------------------------------------------------------------
set -a
# shellcheck disable=SC1091
source ./.env
# shellcheck disable=SC1091
source ./scripts/packages.env
set +a

# ---------------------------------------------------------------------------
# Detect Zigbee coordinator
# ---------------------------------------------------------------------------
Z2MENABLE=true

if [ -d /dev/serial/by-id/ ] && [ -n "$(ls -A /dev/serial/by-id/ 2>/dev/null)" ]; then
  echo "Zigbee coordinator candidates found in /dev/serial/by-id/"
  NUMB=$(ls -1q /dev/serial/by-id/ | wc -l)
  if (( NUMB > 1 )); then
    echo "More than 1 connected serial device. Please choose your Zigbee coordinator:"
    select f in /dev/serial/by-id/*; do
      [ -n "$f" ] && break
      echo ">>> Invalid selection"
    done
    echo "Selected: $f"
    Z2MPATH="$f"
  else
    Z2MPATH="/dev/serial/by-id/$(ls /dev/serial/by-id/)"
  fi
else
  echo "No Zigbee coordinator found in /dev/serial/by-id/."
  while true; do
    read -r -p "Continue without Zigbee2MQTT? (Y/n) " yn
    case "$yn" in
      [yY]|"") echo "OK, continuing without Z2M."; Z2MENABLE=false; break ;;
      [nN]) echo "Exiting..."; exit 1 ;;
      *) echo "Invalid response" ;;
    esac
  done
  Z2MPATH="."
fi

export Z2MPATH
echo "Z2MPATH=$Z2MPATH"

# ---------------------------------------------------------------------------
# Mosquitto + z2m: directories, config, password
# ---------------------------------------------------------------------------
if [ -d ./mosquitto ]; then
  echo "mosquitto directory already exists, reusing existing password."
  MOSQUITTO_PASSWORD="$(cat ./mosquitto/raw.txt)"
else
  echo "Creating mosquitto and zigbee2mqtt directories..."
  mkdir -p mosquitto/config mosquitto/data mosquitto/log zigbee2mqtt/data

  MOSQUITTO_PASSWORD="$(openssl rand -hex 16)"
  echo -n "$MOSQUITTO_PASSWORD" > ./mosquitto/raw.txt
  chmod 600 ./mosquitto/raw.txt

  cp ./scripts/mosquitto.conf ./mosquitto/config/mosquitto.conf

  cat > ./zigbee2mqtt/data/configuration.yaml <<EOF
# Home Assistant integration (MQTT discovery)
homeassistant:
  enabled: true
  legacy_action_sensor: true

# Allow new devices to join (toggle from frontend later)
permit_join: false

mqtt:
  base_topic: zigbee2mqtt
  server: 'mqtt://localhost'
  user: connectivity
  password: $MOSQUITTO_PASSWORD

advanced:
  channel: $ZIGBEE_CHANNEL
  last_seen: 'ISO_8601'

frontend:
  port: 8099

serial:
  port: /dev/ttyACM0
  adapter: $ZIGBEE_ADAPTER

availability:
  enabled: true

device_options:
  homeassistant:
    last_seen:
      enabled_by_default: true
EOF
fi
export MOSQUITTO_PASSWORD

# ---------------------------------------------------------------------------
# Home Assistant: pre-seed MQTT integration on first run
# ---------------------------------------------------------------------------
if [ ! -d ./homeassistant/.storage ]; then
  echo "Pre-seeding Home Assistant MQTT integration..."
  mkdir -p ./homeassistant/.storage

  cat > ./homeassistant/.storage/core.config_entries <<EOF
{
  "version": 1,
  "minor_version": 1,
  "key": "core.config_entries",
  "data": {
    "entries": [
      {
        "entry_id": "92c28c246bb8163e5cc9e6dc5b5d8606",
        "version": 1,
        "domain": "mqtt",
        "title": "localhost",
        "data": {
          "broker": "localhost",
          "port": 1883,
          "username": "connectivity",
          "password": "$MOSQUITTO_PASSWORD",
          "discovery": true,
          "discovery_prefix": "homeassistant"
        },
        "options": {},
        "pref_disable_new_entities": false,
        "pref_disable_polling": false,
        "source": "user",
        "unique_id": null,
        "disabled_by": null
      }
    ]
  }
}
EOF
else
  echo "homeassistant/.storage already exists, skipping pre-seed."
fi

# ---------------------------------------------------------------------------
# Optional services: prepare data dirs (cheap; harmless if profile is off)
# ---------------------------------------------------------------------------
mkdir -p matter-server/data
mkdir -p music-assistant/data

# ---------------------------------------------------------------------------
# Persist runtime values into .env so update.sh / stop.sh can reuse them
# ---------------------------------------------------------------------------
upsert_env_var "MOSQUITTO_PASSWORD" "$MOSQUITTO_PASSWORD" ".env"
upsert_env_var "Z2MPATH" "$Z2MPATH" ".env"

# ---------------------------------------------------------------------------
# Build profiles list and start
# ---------------------------------------------------------------------------
PROFILES="${COMPOSE_PROFILES:-}"
if [ "$Z2MENABLE" = "true" ]; then
  # Add z2m if missing
  if [ -z "$PROFILES" ]; then
    PROFILES="z2m"
  elif ! echo ",$PROFILES," | grep -q ",z2m,"; then
    PROFILES="${PROFILES},z2m"
  fi
else
  # Remove z2m if present (no coordinator detected / user opted out)
  PROFILES="$(echo ",$PROFILES," | sed 's/,z2m,/,/g; s/^,//; s/,$//')"
fi
export COMPOSE_PROFILES="$PROFILES"

echo "----"
echo "Starting docker compose with profiles: '${COMPOSE_PROFILES:-<none>}'"
echo "----"

docker compose up -d

echo ""
echo "Done. Service URLs (when respective profiles are enabled):"
echo "  Home Assistant : http://localhost:8123"
echo "  Zigbee2MQTT    : http://localhost:8099  (profile: z2m)"
echo "  Music Assistant: http://localhost:8095  (profile: music)"
echo "  Matter Server  : ws://localhost:5580/ws (profile: matter)"
echo ""
echo "NOTE: .env now contains MOSQUITTO_PASSWORD and Z2MPATH. Do NOT commit it."