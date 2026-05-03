#!/bin/bash
set -euo pipefail

# Resolve repo root from the location of this script, then cd there.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

echo "Repo root: $REPO_ROOT"
echo "This script will create runtime directories and start docker containers."
echo "It is intended for a CLEAN install. Use update.sh for subsequent runs."

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

profiles_has() {
  echo ",${PROFILES}," | grep -q ",$1,"
}

# ---------------------------------------------------------------------------
# Sanity checks
# ---------------------------------------------------------------------------
if ! command -v docker &> /dev/null; then
  echo "ERROR: docker not found. Install Docker first." >&2
  exit 1
fi
echo "Docker found."

if ! id -nG "$USER" | grep -qw "docker"; then
  echo "ERROR: $USER is not in the 'docker' group. Run: sudo usermod -aG docker \$USER" >&2
  exit 1
fi
echo "$USER is in the docker group."

if ! command -v envsubst &> /dev/null; then
  echo "ERROR: envsubst not found. Install: sudo apt-get install -y gettext-base" >&2
  exit 1
fi
echo "envsubst found."

if [ ! -f .env ]; then
  echo "ERROR: .env file not found in repo root. It should be tracked by the repo." >&2
  exit 1
fi

# Refuse to run on a non-clean install.
for d in homeassistant mosquitto zigbee2mqtt matter-server music-assistant; do
  if [ -e "./$d" ]; then
    echo "ERROR: ./$d already exists. setup.sh expects a clean install." >&2
    echo "       To reset, run: bash scripts/stop.sh && rm -rf homeassistant mosquitto zigbee2mqtt matter-server music-assistant && git checkout -- .env" >&2
    echo "       To update an existing stack instead, run: bash scripts/update.sh" >&2
    exit 1
  fi
done
echo "Workspace is clean, proceeding."

# ---------------------------------------------------------------------------
# Load env
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
      [yY]|"") echo "OK, continuing without Z2M."; Z2MPATH="."; break ;;
      [nN]) echo "Exiting..."; exit 1 ;;
      *) echo "Invalid response" ;;
    esac
  done
fi

export Z2MPATH
echo "Z2MPATH=$Z2MPATH"

# ---------------------------------------------------------------------------
# Mosquitto + z2m: directories, config, password
# ---------------------------------------------------------------------------
echo "Creating mosquitto and zigbee2mqtt directories..."
mkdir -p mosquitto/config mosquitto/data mosquitto/log zigbee2mqtt/data

MOSQUITTO_PASSWORD="$(openssl rand -hex 16)"
echo -n "$MOSQUITTO_PASSWORD" > ./mosquitto/raw.txt
chmod 600 ./mosquitto/raw.txt
export MOSQUITTO_PASSWORD

cp ./scripts/addons_conf/mosquitto/mosquitto.conf ./mosquitto/config/mosquitto.conf

# Render zigbee2mqtt config from template using current env values.
envsubst < ./scripts/addons_conf/zigbee2mqtt/configuration.yaml.tpl \
  > ./zigbee2mqtt/data/configuration.yaml

# ---------------------------------------------------------------------------
# Home Assistant: pre-seed MQTT integration
# ---------------------------------------------------------------------------
echo "Pre-seeding Home Assistant MQTT integration..."
mkdir -p ./homeassistant/.storage
envsubst < ./scripts/addons_conf/ha_integrations/mqtt-config-entry.tpl \
  > ./homeassistant/.storage/core.config_entries

# ---------------------------------------------------------------------------
# Build profiles list
# ---------------------------------------------------------------------------
PROFILES="${COMPOSE_PROFILES:-}"
if [ "$Z2MPATH" != "." ]; then
  if [ -z "$PROFILES" ]; then
    PROFILES="z2m"
  elif ! profiles_has "z2m"; then
    PROFILES="${PROFILES},z2m"
  fi
else
  # Remove z2m if present (no coordinator detected / user opted out)
  PROFILES="$(echo ",$PROFILES," | sed 's/,z2m,/,/g; s/^,//; s/,$//')"
fi
export COMPOSE_PROFILES="$PROFILES"

# ---------------------------------------------------------------------------
# Optional services: prepare data dirs only if their profiles are enabled
# ---------------------------------------------------------------------------
if profiles_has "matter"; then
  mkdir -p matter-server/data
fi
if profiles_has "music"; then
  mkdir -p music-assistant/data
fi

# ---------------------------------------------------------------------------
# Persist runtime values into .env
# ---------------------------------------------------------------------------
upsert_env_var "MOSQUITTO_PASSWORD" "$MOSQUITTO_PASSWORD" ".env"
upsert_env_var "Z2MPATH" "$Z2MPATH" ".env"

# ---------------------------------------------------------------------------
# Start
# ---------------------------------------------------------------------------
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