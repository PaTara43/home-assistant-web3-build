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
Z2M2_CUR="$(get_running_image zigbee2mqtt2)"
HA_CUR="$(get_running_image homeassistant)"
MQTT_CUR="$(get_running_image mosquitto)"
MATTER_CUR="$(get_running_image matter-server)"
MATTERHUB_CUR="$(get_running_image matter-hub)"

echo "Currently running images:"
echo "  zigbee2mqtt     : ${Z2M_CUR:-<not running>}"
echo "  zigbee2mqtt2    : ${Z2M2_CUR:-<not running>}"
echo "  homeassistant   : ${HA_CUR:-<not running>}"
echo "  mosquitto       : ${MQTT_CUR:-<not running>}"
echo "  matter-server   : ${MATTER_CUR:-<not running>}"
echo "  matter-hub      : ${MATTERHUB_CUR:-<not running>}"

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
# For Z2M_TRANSPORT=tcp (PoE coordinators like SMLight SLZB-06) there is nothing
# to reconcile — the coordinator is reached over the network and its address
# lives in .env, so we just keep Z2MPATH and enable z2m unconditionally.
#
# For usb (default), the truth table below compares PREVIOUS (Z2MPATH from .env)
# with CURRENT (what's actually plugged into /dev/serial/by-id/):
#
#   PREVIOUS ".", CURRENT none        → quiet, stay disabled
#   PREVIOUS valid, CURRENT same      → quiet, stay enabled
#   PREVIOUS ".", CURRENT detected    → ask: enable z2m for this stick?
#   PREVIOUS valid, CURRENT gone      → ask: continue without z2m?
#   PREVIOUS valid, CURRENT changed   → ask: switch to new stick?
# ---------------------------------------------------------------------------
if [ "${Z2M_TRANSPORT:-usb}" = "tcp" ]; then
  echo "Zigbee transport: tcp (PoE coordinator). Skipping USB reconciliation."
  : "${Z2M_TCP_PORT:=6638}"
  Z2M_SERIAL_PORT="tcp://${Z2M_TCP_HOST}:${Z2M_TCP_PORT}"
  Z2M_DEVICE_MAP="/dev/null:/dev/null"
  # Z2MPATH already holds tcp://... from .env; keep it as the z2m-enabled marker.
  : "${Z2MPATH:=$Z2M_SERIAL_PORT}"
  export Z2MPATH Z2M_SERIAL_PORT Z2M_DEVICE_MAP
  echo "Z2MPATH=$Z2MPATH"
  echo "Z2M_DEVICE_MAP=$Z2M_DEVICE_MAP"
else
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

  if [ "$Z2MPATH" != "." ]; then
    Z2M_SERIAL_PORT="/dev/ttyACM0"
    Z2M_DEVICE_MAP="${Z2MPATH}:/dev/ttyACM0"
  else
    Z2M_SERIAL_PORT=""
    Z2M_DEVICE_MAP="/dev/null:/dev/null"
  fi
  export Z2MPATH Z2M_SERIAL_PORT Z2M_DEVICE_MAP
  echo "Z2MPATH=$Z2MPATH"
  echo "Z2M_DEVICE_MAP=$Z2M_DEVICE_MAP"
fi

# ---------------------------------------------------------------------------
# Reconcile second Zigbee instance (z2m2) — only if the profile is enabled.
# Same logic as instance 1, but driven by Z2M2_* variables. tcp skips USB
# reconciliation. usb+usb across both instances is rejected.
# ---------------------------------------------------------------------------
Z2M2_PATH="${Z2M2_PATH:-}"
Z2M2_SERIAL_PORT="${Z2M2_SERIAL_PORT:-}"
Z2M2_DEVICE_MAP="${Z2M2_DEVICE_MAP:-/dev/null:/dev/null}"

if echo ",${COMPOSE_PROFILES:-}," | grep -q ",z2m2,"; then
  if [ "${Z2M_TRANSPORT:-usb}" = "usb" ] && [ "${Z2M2_TRANSPORT:-usb}" = "usb" ]; then
    echo "ERROR: usb+usb for two instances is not supported. Use usb+tcp or tcp+tcp." >&2
    exit 1
  fi

  if [ "${Z2M2_TRANSPORT:-usb}" = "tcp" ]; then
    echo "Zigbee transport (instance 2): tcp (PoE coordinator). Skipping USB reconciliation."
    : "${Z2M2_TCP_PORT:=6638}"
    Z2M2_SERIAL_PORT="tcp://${Z2M2_TCP_HOST}:${Z2M2_TCP_PORT}"
    Z2M2_DEVICE_MAP="/dev/null:/dev/null"
    : "${Z2M2_PATH:=$Z2M2_SERIAL_PORT}"
    export Z2M2_PATH Z2M2_SERIAL_PORT Z2M2_DEVICE_MAP
    echo "Z2M2_PATH=$Z2M2_PATH"
    echo "Z2M2_DEVICE_MAP=$Z2M2_DEVICE_MAP"
  else
    # usb instance 2 — reuse helpers defined above (ask_yn, select_stick).
    # NOTE: select_stick operates on DETECTED_LIST which was built for instance 1.
    # That's fine: instance 1 is on tcp here (usb+usb was rejected), so the list
    # is still valid and contains whatever USB sticks are attached.
    PREV_Z2M2_PATH="${Z2M2_PATH:-.}"
    if [ "$PREV_Z2M2_PATH" = "." ] || [ -z "$PREV_Z2M2_PATH" ]; then
      if [ "${#DETECTED_LIST[@]}" -eq 0 ]; then
        echo "No USB Zigbee coordinator available for instance 2. z2m2 cannot start." >&2
        exit 1
      else
        echo "A USB coordinator is attached for instance 2."
        if ask_yn "Use it for z2m2?"; then
          select_stick
          Z2M2_PATH="$Z2MPATH"
        else
          echo "Exiting — z2m2 requires a coordinator." >&2
          exit 1
        fi
      fi
    else
      if [ -e "$PREV_Z2M2_PATH" ]; then
        echo "Zigbee coordinator for instance 2 unchanged: $PREV_Z2M2_PATH"
        Z2M2_PATH="$PREV_Z2M2_PATH"
      elif [ "${#DETECTED_LIST[@]}" -eq 0 ]; then
        echo "Previous coordinator for instance 2 ($PREV_Z2M2_PATH) is gone, and no other stick is attached." >&2
        if ask_yn "Continue without z2m2?"; then
          # Disable z2m2 for this run by removing it from PROFILES below.
          Z2M2_PATH="."
        else
          echo "Exiting — plug the stick back in or update Z2M2_PATH manually." >&2
          exit 1
        fi
      else
        echo "Previous coordinator for instance 2 ($PREV_Z2M2_PATH) is gone, but another stick is attached."
        if ask_yn "Switch to the newly attached stick for instance 2?"; then
          select_stick
          Z2M2_PATH="$Z2MPATH"
        else
          echo "Exiting — keep current path or remove stick and re-run." >&2
          exit 1
        fi
      fi
    fi

    if [ "$Z2M2_PATH" != "." ] && [ -n "$Z2M2_PATH" ]; then
      Z2M2_SERIAL_PORT="/dev/ttyACM0"
      Z2M2_DEVICE_MAP="${Z2M2_PATH}:/dev/ttyACM0"
    else
      Z2M2_SERIAL_PORT=""
      Z2M2_DEVICE_MAP="/dev/null:/dev/null"
    fi
    export Z2M2_PATH Z2M2_SERIAL_PORT Z2M2_DEVICE_MAP
    echo "Z2M2_PATH=$Z2M2_PATH"
    echo "Z2M2_DEVICE_MAP=$Z2M2_DEVICE_MAP"
  fi
fi

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

# z2m2 is never auto-added — only auto-removed if its coordinator is gone.
if echo ",${PROFILES}," | grep -q ",z2m2,"; then
  if [ -z "$Z2M2_PATH" ] || [ "$Z2M2_PATH" = "." ]; then
    echo "z2m2 coordinator unavailable — removing z2m2 from profiles for this run." >&2
    PROFILES="$(echo ",$PROFILES," | sed 's/,z2m2,/,/g; s/^,//; s/,$//')"
  fi
fi
export COMPOSE_PROFILES="$PROFILES"

# ---------------------------------------------------------------------------
# Validate no collisions between instance 1 and instance 2 (both enabled).
# ---------------------------------------------------------------------------
if echo ",${PROFILES}," | grep -q ",z2m," && echo ",${PROFILES}," | grep -q ",z2m2,"; then
  if [ "${ZIGBEE_CHANNEL:-11}" = "${Z2M2_CHANNEL:-15}" ]; then
    echo "ERROR: ZIGBEE_CHANNEL and Z2M2_CHANNEL must differ." >&2
    exit 1
  fi
  if [ "${Z2M_FRONTEND_PORT:-8099}" = "${Z2M2_FRONTEND_PORT:-8100}" ]; then
    echo "ERROR: Z2M_FRONTEND_PORT and Z2M2_FRONTEND_PORT must differ." >&2
    exit 1
  fi
  if [ "${Z2M_BASE_TOPIC:-zigbee2mqtt}" = "${Z2M2_BASE_TOPIC:-zigbee2mqtt2}" ]; then
    echo "ERROR: Z2M_BASE_TOPIC and Z2M2_BASE_TOPIC must differ." >&2
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
# matter-hub sanity: token is provisioned headlessly by setup.sh and lives
# in .env regardless of profile state. If something nuked it, refuse to start
# matter-hub for this run (compose would happily launch it with an empty
# token, which then 401s against HA endlessly).
# ---------------------------------------------------------------------------
if profiles_has "matter-hub" && [ -z "${HAMH_HOME_ASSISTANT_ACCESS_TOKEN:-}" ]; then
  echo "WARNING: 'matter-hub' is in COMPOSE_PROFILES but HAMH_HOME_ASSISTANT_ACCESS_TOKEN is empty in .env." >&2
  echo "         Restore it from a backup, or do a full reset (stop.sh + rm -rf data dirs + rm -f .env + cp template.env .env + setup.sh)." >&2
  echo "         Skipping matter-hub for this run." >&2
  PROFILES="$(echo ",$PROFILES," | sed 's/,matter-hub,/,/g; s/^,//; s/,$//')"
  export COMPOSE_PROFILES="$PROFILES"
fi

# ---------------------------------------------------------------------------
# Persist updated Z2MPATH back into .env (plus device map for compose.yaml)
# ---------------------------------------------------------------------------
upsert_env_var "Z2MPATH" "$Z2MPATH" ".env"
upsert_env_var "Z2M_DEVICE_MAP" "$Z2M_DEVICE_MAP" ".env"
upsert_env_var "Z2M_SERIAL_PORT" "$Z2M_SERIAL_PORT" ".env"

if echo ",${COMPOSE_PROFILES:-}," | grep -q ",z2m2,"; then
  upsert_env_var "Z2M2_PATH" "$Z2M2_PATH" ".env"
  upsert_env_var "Z2M2_DEVICE_MAP" "$Z2M2_DEVICE_MAP" ".env"
  upsert_env_var "Z2M2_SERIAL_PORT" "$Z2M2_SERIAL_PORT" ".env"
fi

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
cleanup_old "Zigbee2MQTT (2)" "$Z2M2_CUR"      "koenkk/zigbee2mqtt:${Z2M_VERSION}"
cleanup_old "Home Assistant"  "$HA_CUR"        "ghcr.io/home-assistant/home-assistant:${HA_VERSION}"
cleanup_old "Matter Server"   "$MATTER_CUR"    "ghcr.io/matter-js/matterjs-server:${MATTER_VERSION}"
cleanup_old "Matter Hub"      "$MATTERHUB_CUR" "ghcr.io/riddix/home-assistant-matter-hub:${MATTER_HUB_VERSION}"

echo "Done."