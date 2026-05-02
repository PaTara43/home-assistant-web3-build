#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

get_running_image() {
  local name="$1"
  docker inspect --format '{{.Config.Image}}' "$name" 2>/dev/null || true
}

Z2M_CUR="$(get_running_image zigbee2mqtt)"
HA_CUR="$(get_running_image homeassistant)"
MQTT_CUR="$(get_running_image mosquitto)"
MATTER_CUR="$(get_running_image matter-server)"
MA_CUR="$(get_running_image music-assistant)"

echo "Currently running images:"
echo "  zigbee2mqtt     : ${Z2M_CUR:-<not running>}"
echo "  homeassistant   : ${HA_CUR:-<not running>}"
echo "  mosquitto       : ${MQTT_CUR:-<not running>}"
echo "  matter-server   : ${MATTER_CUR:-<not running>}"
echo "  music-assistant : ${MA_CUR:-<not running>}"

set -a
# shellcheck disable=SC1091
source ./.env
# shellcheck disable=SC1091
source ./scripts/packages.env
set +a

# Profiles: keep what user set, plus z2m if Z2MPATH is real
PROFILES="${COMPOSE_PROFILES:-}"
Z2MPATH="${Z2MPATH:-.}"
if [ "$Z2MPATH" != "." ] && [ -e "$Z2MPATH" ]; then
  if [ -z "$PROFILES" ]; then
    PROFILES="z2m"
  elif ! echo ",$PROFILES," | grep -q ",z2m,"; then
    PROFILES="${PROFILES},z2m"
  fi
else
  PROFILES="$(echo ",$PROFILES," | sed 's/,z2m,/,/g; s/^,//; s/,$//')"
fi
export COMPOSE_PROFILES="$PROFILES"

echo "Pulling new images for profiles: '${COMPOSE_PROFILES:-<none>}'..."
docker compose pull

echo "Restarting stack..."
docker compose down
docker compose up -d

cleanup_old() {
  local label="$1" running="$2" new_tag="$3"
  if [ -z "$running" ] || [ "$running" = "$new_tag" ]; then
    echo "$label: nothing to clean up."
    return
  fi
  echo "$label: removing old image $running"
  docker image rm "$running" || true
}

cleanup_old "Mosquitto"       "$MQTT_CUR"   "eclipse-mosquitto:${MOSQUITTO_VERSION}"
cleanup_old "Zigbee2MQTT"     "$Z2M_CUR"    "koenkk/zigbee2mqtt:${Z2M_VERSION}"
cleanup_old "Home Assistant"  "$HA_CUR"     "ghcr.io/home-assistant/home-assistant:${HA_VERSION}"
cleanup_old "Matter Server"   "$MATTER_CUR" "ghcr.io/matter-js/matterjs-server:${MATTER_VERSION}"
cleanup_old "Music Assistant" "$MA_CUR"     "ghcr.io/music-assistant/server:${MA_VERSION}"

echo "Done."