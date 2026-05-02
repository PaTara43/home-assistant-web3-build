#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

# Load pinned versions
set -a
# shellcheck disable=SC1091
source ./scripts/packages.env
set +a

INTEGRATIONS_DIR="homeassistant/custom_components"
mkdir -p "$INTEGRATIONS_DIR"

# install_subfolder REPO TAG SUBPATH TARGET_DIR
install_subfolder() {
  local repo="$1" tag="$2" subpath="$3" target="$4"
  local url="https://codeload.github.com/${repo}/tar.gz/refs/tags/${tag}"

  echo "==> ${repo}@${tag} :: ${subpath} -> ${target}"

  rm -rf "$target"
  mkdir -p "$target"

  local depth
  depth=$(awk -F'/' '{print NF}' <<<"$subpath")
  local strip=$((1 + depth))

  curl -fsSL "$url" \
    | tar -xz -C "$target" --strip-components="$strip" --wildcards "*/${subpath}/*"
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

install_subfolder \
  "rospogrigio/localtuya" \
  "$LOCALTUYA_VERSION" \
  "custom_components/localtuya" \
  "$INTEGRATIONS_DIR/localtuya"

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
