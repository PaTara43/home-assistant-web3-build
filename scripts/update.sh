#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

# ---------------------------------------------------------------------------
# Helpers (same as setup.sh)
# ---------------------------------------------------------------------------
upsert_env_var() {
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

get_running_image() {
  local name="$1"
  docker inspect --format '{{.Config.Image}}' "$name" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Snapshot currently running images so we can clean up old ones at the end
# ---------------------------------------------------------------------------
Z2M_CUR="$(get_running_image zigbee2mqtt)"
HA_CUR="$(get_running_image homeassistant)"
MQTT_CUR="$(get_running_image mosquitto)"
MATTER_CUR="$(get_running_image matter-server)"
MATTERHUB_CUR="$(get_running_image matter-hub)"
MA_CUR="$(get_running_image music-assistant)"

echo "Currently running images:"
echo "  zigbee2mqtt     : ${Z2M_CUR:-<not running>}"
echo "  homeassistant   : ${HA_CUR:-<not running>}"
echo "  mosquitto       : ${MQTT_CUR:-<not running>}"
echo "  matter-server   : ${MATTER_CUR:-<not running>}"
echo "  matter-hub      : ${MATTERHUB_CUR:-<not running>}"
echo "  music-assistant : ${MA_CUR:-<not running>}"

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
# Reconcile Zigbee coordinator state.
#
# Truth table (PREVIOUS = Z2MPATH from .env, CURRENT = what's actually plugged):
#
#   PREVIOUS ".", CURRENT none        → quiet, stay disabled
#   PREVIOUS valid, CURRENT same      → quiet, stay enabled
#   PREVIOUS ".", CURRENT detected    → ask: enable z2m for this stick?
#   PREVIOUS valid, CURRENT gone      → ask: continue without z2m?
#   PREVIOUS valid, CURRENT changed   → ask: switch to new stick?
# ---------------------------------------------------------------------------
PREV_Z2MPATH="${Z2MPATH:-.}"

# What's currently attached?
DETECTED_LIST=()
if [ -d /dev/serial/by-id/ ]; then
  while IFS= read -r -d '' f; do
    DETECTED_LIST+=("$f")
  done < <(find /dev/serial/by-id/ -mindepth 1 -maxdepth 1 -print0 2>/dev/null)
fi

select_stick() {
  # Sets Z2MPATH from DETECTED_LIST. If multiple, asks user.
  if [ "${#DETECTED_LIST[@]}" -eq 1 ]; then
    Z2MPATH="${DETECTED_LIST[0]}"
  else
    echo "More than 1 connected serial device. Please choose your Zigbee coordinator:"
    select f in "${DETECTED_LIST[@]}"; do
      [ -n "$f" ] && break
      echo ">>> Invalid selection"
    done
    Z2MPATH="$f"
  fi
}

ask_yn() {
  # ask_yn "prompt" → returns 0 for yes, 1 for no
  local prompt="$1" yn
  while true; do
    read -r -p "$prompt (Y/n) " yn
    case "$yn" in
      [yY]|"") return 0 ;;
      [nN])    return 1 ;;
      *)       echo ">>> Invalid response" ;;
    esac
  done
}

if [ "$PREV_Z2MPATH" = "." ]; then
  if [ "${#DETECTED_LIST[@]}" -eq 0 ]; then
    echo "No Zigbee coordinator. z2m stays disabled."
    Z2MPATH="."
  else
    echo "A Zigbee coordinator is now attached but z2m was previously disabled."
    if ask_yn "Enable z2m and use the attached stick?"; then
      select_stick
    else
      echo "OK, keeping z2m disabled."
      Z2MPATH="."
    fi
  fi
else
  # We had a stick previously
  if [ -e "$PREV_Z2MPATH" ]; then
    echo "Zigbee coordinator unchanged: $PREV_Z2MPATH"
    Z2MPATH="$PREV_Z2MPATH"
  elif [ "${#DETECTED_LIST[@]}" -eq 0 ]; then
    echo "Previous Zigbee coordinator ($PREV_Z2MPATH) is gone, and no other stick is attached."
    if ask_yn "Continue without z2m?"; then
      Z2MPATH="."
    else
      echo "Exiting — plug the stick back in or update Z2MPATH manually." >&2
      exit 1
    fi
  else
    echo "Previous Zigbee coordinator ($PREV_Z2MPATH) is gone, but another stick is attached."
    if ask_yn "Switch to the newly attached stick?"; then
      select_stick
    else
      echo "Exiting — keep current path or remove stick and re-run." >&2
      exit 1
    fi
  fi
fi

export Z2MPATH
echo "Z2MPATH=$Z2MPATH"

# ---------------------------------------------------------------------------
# Re-render z2m config if path changed (Z2MPATH is referenced by compose,
# but the rendered configuration.yaml lives in volumes — we don't touch it).
# ---------------------------------------------------------------------------
# (Intentionally no config regeneration — user manages volumes.)

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
  PROFILES="$(echo ",$PROFILES," | sed 's/,z2m,/,/g; s/^,//; s/,$//')"
fi
export COMPOSE_PROFILES="$PROFILES"

# ---------------------------------------------------------------------------
# matter-hub sanity: if profile is on but no access token, refuse to start it.
# (Token is normally provisioned headlessly by setup.sh. If matter-hub was
# added to COMPOSE_PROFILES manually after setup, the user must generate a
# long-lived token in HA UI and put it in .env.)
# ---------------------------------------------------------------------------
if profiles_has "matter-hub"; then
  if [ -z "${HAMH_HOME_ASSISTANT_ACCESS_TOKEN:-}" ]; then
    echo "WARNING: 'matter-hub' is in COMPOSE_PROFILES but HAMH_HOME_ASSISTANT_ACCESS_TOKEN is empty." >&2
    echo "         Generate a long-lived token in HA (Profile -> Security) and set it in .env," >&2
    echo "         or remove 'matter-hub' from COMPOSE_PROFILES. Skipping matter-hub for this run." >&2
    PROFILES="$(echo ",$PROFILES," | sed 's/,matter-hub,/,/g; s/^,//; s/,$//')"
    export COMPOSE_PROFILES="$PROFILES"
  fi
fi

# ---------------------------------------------------------------------------
# Persist updated Z2MPATH back into .env
# ---------------------------------------------------------------------------
upsert_env_var "Z2MPATH" "$Z2MPATH" ".env"

# ---------------------------------------------------------------------------
# Pull and restart
# ---------------------------------------------------------------------------
echo "Pulling new images for profiles: '${COMPOSE_PROFILES:-<none>}'..."
docker compose pull

echo "Restarting stack..."
docker compose down
docker compose up -d

# ---------------------------------------------------------------------------
# Cleanup outdated images
# ---------------------------------------------------------------------------
cleanup_old() {
  local label="$1" running="$2" new_tag="$3"
  if [ -z "$running" ] || [ "$running" = "$new_tag" ]; then
    echo "$label: nothing to clean up."
    return
  fi
  echo "$label: removing old image $running"
  docker image rm "$running" || true
}

cleanup_old "Mosquitto"       "$MQTT_CUR"      "eclipse-mosquitto:${MOSQUITTO_VERSION}"
cleanup_old "Zigbee2MQTT"     "$Z2M_CUR"       "koenkk/zigbee2mqtt:${Z2M_VERSION}"
cleanup_old "Home Assistant"  "$HA_CUR"        "ghcr.io/home-assistant/home-assistant:${HA_VERSION}"
cleanup_old "Matter Server"   "$MATTER_CUR"    "ghcr.io/matter-js/matterjs-server:${MATTER_VERSION}"
cleanup_old "Matter Hub"      "$MATTERHUB_CUR" "ghcr.io/riddix/home-assistant-matter-hub:${MATTER_HUB_VERSION}"
cleanup_old "Music Assistant" "$MA_CUR"        "ghcr.io/music-assistant/server:${MA_VERSION}"

echo "Done."