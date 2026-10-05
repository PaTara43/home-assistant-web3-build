#!/bin/bash
set -euo pipefail

# Usage: install-custom-integrations.sh [--no-restart]
#   Downloads pinned integrations into homeassistant/custom_components/. If the
#   homeassistant container is running, restarts it so the new code loads and
#   creates the UIX config entry through the HA API (skipped if it exists).
#   --no-restart: download only; restart HA yourself and re-run to add UIX.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

RESTART=1
case "${1:-}" in
  "") ;;
  --no-restart) RESTART=0 ;;
  *) echo "Usage: $0 [--no-restart]" >&2; exit 1 ;;
esac

# Load pinned versions, plus .env for the HA long-lived token (if present)
set -a
# shellcheck disable=SC1091
source ./scripts/packages.env
if [ -f .env ]; then
  # shellcheck disable=SC1091
  source ./.env
fi
set +a

INTEGRATIONS_DIR="homeassistant/custom_components"
mkdir -p "$INTEGRATIONS_DIR"

STAGING_DIR="$(mktemp -d)"
trap 'rm -rf "$STAGING_DIR"' EXIT

# remove_dir DIR
#   HA runs as root in its container, so files it writes into an integration it
#   has loaded (__pycache__) are root-owned on the host and a plain rm fails.
#   Those are removed through a throwaway container from the HA image.
remove_dir() {
  local dir="$1" image
  rm -rf "$dir" 2>/dev/null && return 0
  if ! image="$(docker inspect --format '{{.Config.Image}}' homeassistant 2>/dev/null)"; then
    echo "ERROR: cannot remove ${dir} (root-owned files) and there is no homeassistant" >&2
    echo "       container to do it with. Remove it by hand: sudo rm -rf ${dir}" >&2
    return 1
  fi
  echo "    ${dir} has root-owned files (HA's __pycache__), removing via ${image} ..."
  docker run --rm --entrypoint rm -v "${REPO_ROOT}/${dir%/*}:/parent" "$image" -rf "/parent/${dir##*/}"
  [ ! -e "$dir" ]
}

# install_subfolder REPO TAG SUBPATH TARGET_DIR
#   Downloads into a staging dir first, so a failed download leaves the
#   installed copy alone, then swaps it in.
install_subfolder() {
  local repo="$1" tag="$2" subpath="$3" target="$4"
  local url="https://codeload.github.com/${repo}/tar.gz/refs/tags/${tag}"
  local new="${STAGING_DIR}/${target##*/}"

  echo "==> ${repo}@${tag} :: ${subpath} -> ${target}"

  mkdir -p "$new"

  local depth
  depth=$(awk -F'/' '{print NF}' <<<"$subpath")
  local strip=$((1 + depth))

  curl -fsSL "$url" \
    | tar -xz -C "$new" --strip-components="$strip" --wildcards "*/${subpath}/*"

  remove_dir "$target"
  mv "$new" "$target"
}

install_subfolder \
  "KartoffelToby/better_thermostat" \
  "$BETTER_THERMOSTAT_VERSION" \
  "custom_components/better_thermostat" \
  "$INTEGRATIONS_DIR/better_thermostat"

install_subfolder \
  "thomasloven/hass-browser_mod" \
  "$BROWSER_MOD_VERSION" \
  "custom_components/browser_mod" \
  "$INTEGRATIONS_DIR/browser_mod"

# UI eXtension — drop-in replacement for card-mod (card_mod: / card-mod-* keys
# keep working). Ships its own frontend module, so it is not in install-cards.sh.
install_subfolder \
  "Lint-Free-Technology/uix" \
  "$UIX_VERSION" \
  "custom_components/uix" \
  "$INTEGRATIONS_DIR/uix"

install_subfolder \
  "dext0r/yandex_smart_home" \
  "$YANDEX_SMART_HOME_VERSION" \
  "custom_components/yandex_smart_home" \
  "$INTEGRATIONS_DIR/yandex_smart_home"

install_subfolder \
  "AlexxIT/YandexStation" \
  "$YANDEX_STATION_VERSION" \
  "custom_components/yandex_station" \
  "$INTEGRATIONS_DIR/yandex_station"

echo ""
echo "Done. Installed custom integrations:"
find "$INTEGRATIONS_DIR" -mindepth 1 -maxdepth 1 -type d | sort

# ---------------------------------------------------------------------------
# Restart HA and make sure the UIX config entry exists.
# UIX does nothing until its config entry is added (single instance, no
# options needed). The token is the admin long-lived token minted by setup.sh.
# ---------------------------------------------------------------------------
HA_URL="http://localhost:8123"
HA_TOKEN="${HAMH_HOME_ASSISTANT_ACCESS_TOKEN:-}"
UIX_MANUAL="Settings -> Devices & services -> Add integration -> UI eXtension"

# ha_api METHOD PATH [JSON_BODY] -> response body on stdout; non-2xx -> non-zero
ha_api() {
  local method="$1" path="$2" body="${3:-}"
  local args=(-fsS --max-time 30 -X "$method" -H "Authorization: Bearer ${HA_TOKEN}")
  if [ -n "$body" ]; then
    args+=(-H "Content-Type: application/json" -d "$body")
  fi
  curl "${args[@]}" "${HA_URL}${path}"
}

wait_ha_running() {
  local i state
  for i in $(seq 1 30); do
    state="$(ha_api GET /api/config 2>/dev/null \
      | python3 -c 'import json,sys; print(json.load(sys.stdin).get("state",""))' 2>/dev/null || true)"
    if [ "$state" = "RUNNING" ]; then
      return 0
    fi
    echo "  [${i}/30] waiting for Home Assistant (state: ${state:-not responding}) ..."
    sleep 10
  done
  return 1
}

echo ""
if [ "$RESTART" -eq 0 ]; then
  echo "Skipping restart (--no-restart). Restart Home Assistant, then re-run without"
  echo "--no-restart to add the UIX config entry (or: ${UIX_MANUAL})."
  exit 0
fi

if ! docker compose ps --status running --services 2>/dev/null | grep -qx homeassistant; then
  echo "homeassistant container is not running. Start it and re-run this script"
  echo "to add the UIX config entry (or: ${UIX_MANUAL})."
  exit 0
fi

echo "Restarting Home Assistant to load the new integrations ..."
docker compose restart homeassistant

if [ -z "$HA_TOKEN" ]; then
  echo "No HAMH_HOME_ASSISTANT_ACCESS_TOKEN in .env — add UIX by hand: ${UIX_MANUAL}."
  exit 0
fi

if ! wait_ha_running; then
  echo "ERROR: Home Assistant did not reach RUNNING within 300s; UIX entry not created." >&2
  exit 1
fi

UIX_ENTRIES="$(ha_api GET "/api/config/config_entries/entry?domain=uix" \
  | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')"
if [ "$UIX_ENTRIES" -gt 0 ]; then
  echo "UIX config entry already exists."
  exit 0
fi

echo "Adding UIX config entry ..."
if ! FLOW_RESP="$(ha_api POST /api/config/config_entries/flow '{"handler": "uix"}')"; then
  echo "ERROR: config flow for uix failed (is custom_components/uix loaded?). Add it by hand: ${UIX_MANUAL}." >&2
  exit 1
fi
FLOW_RESULT="$(printf '%s' "$FLOW_RESP" \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("type",""), d.get("reason") or "")')"
case "$FLOW_RESULT" in
  create_entry*)
    echo "UIX config entry created. Hard-reload open browsers (Ctrl+Shift+R)."
    ;;
  "abort old_frontend_script_resource"*|"abort old_frontend_script_extra_module"*)
    echo "ERROR: card-mod is still loaded (${FLOW_RESULT#abort }), UIX refuses to install next to it." >&2
    echo "       Drop card-mod from Dashboard resources (install-cards.sh rewrites them) and from" >&2
    echo "       frontend: extra_module_url, restart HA and re-run this script." >&2
    exit 1
    ;;
  *)
    echo "ERROR: unexpected config flow result for uix: ${FLOW_RESULT}" >&2
    exit 1
    ;;
esac
