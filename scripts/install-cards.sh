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

CARDS_DIR="homeassistant/www/community"
mkdir -p "$CARDS_DIR"

# ---------------------------------------------------------------------------
# Helper: download a single named file from a GitHub release.
# install_release_file REPO TAG FILENAME TARGET_DIR
# ---------------------------------------------------------------------------
install_release_file() {
  local repo="$1" tag="$2" filename="$3" target="$4"
  local url="https://github.com/${repo}/releases/download/${tag}/${filename}"

  echo "==> ${repo}@${tag} :: ${filename} -> ${target}/"

  mkdir -p "$target"
  curl -fsSL -o "${target}/${filename}" "$url"
}

# ---------------------------------------------------------------------------
# Helper: download a zip asset from a release, extract its `dist/` contents
# (or root if no dist) into target dir.
# install_release_zip REPO TAG ZIP_FILENAME TARGET_DIR
# ---------------------------------------------------------------------------
install_release_zip() {
  local repo="$1" tag="$2" zipname="$3" target="$4"
  local url="https://github.com/${repo}/releases/download/${tag}/${zipname}"
  local tmp
  tmp="$(mktemp -d)"

  echo "==> ${repo}@${tag} :: ${zipname} -> ${target}/"

  rm -rf "$target"
  mkdir -p "$target"

  curl -fsSL -o "${tmp}/${zipname}" "$url"
  unzip -q "${tmp}/${zipname}" -d "$tmp"

  # If archive contains a top-level dist/ folder, use its contents.
  # Otherwise fall back to extracting everything except the zip itself.
  if [ -d "${tmp}/dist" ]; then
    cp -r "${tmp}/dist/." "$target/"
  else
    find "$tmp" -mindepth 1 -maxdepth 1 ! -name "$zipname" -exec cp -r {} "$target/" \;
  fi

  rm -rf "$tmp"
}

# ---------------------------------------------------------------------------
# Helper: download a single file from inside the source tarball of a tag.
# install_from_source REPO TAG SUBPATH TARGET_DIR
# Example: install_from_source thomasloven/lovelace-card-mod v4.2.1 card-mod.js cards/lovelace-card-mod
# ---------------------------------------------------------------------------
install_from_source() {
  local repo="$1" tag="$2" subpath="$3" target="$4"
  local url="https://codeload.github.com/${repo}/tar.gz/refs/tags/${tag}"
  local fname
  fname="$(basename "$subpath")"
  local tmp
  tmp="$(mktemp -d)"

  echo "==> ${repo}@${tag} :: source:${subpath} -> ${target}/${fname}"

  mkdir -p "$target"

  # Extract the whole tarball into a tmp dir, then copy out the file we need.
  # This avoids fragile tar wildcard semantics (GNU vs BSD differ a lot).
  curl -fsSL "$url" | tar -xz -C "$tmp"

  # The tarball wraps everything in a single top-level directory like
  # "lovelace-card-mod-4.2.1/". Find the actual file regardless of its name.
  local found
  found="$(find "$tmp" -mindepth 2 -path "*/${subpath}" -type f | head -n 1)"

  if [ -z "$found" ]; then
    echo "  ERROR: did not find ${subpath} inside ${repo}@${tag} tarball" >&2
    rm -rf "$tmp"
    exit 1
  fi

  cp "$found" "${target}/${fname}"
  rm -rf "$tmp"
}

# ---------------------------------------------------------------------------
# Cards
# ---------------------------------------------------------------------------

# Type 1: install from zip archive in releases
install_release_zip \
  "dermotduffy/advanced-camera-card" \
  "$ADVANCED_CAMERA_CARD_VERSION" \
  "advanced-camera-card.zip" \
  "$CARDS_DIR/advanced-camera-card"

# Type 2: single file from release
install_release_file \
  "pkissling/clock-weather-card" \
  "$CLOCK_WEATHER_CARD_VERSION" \
  "clock-weather-card.js" \
  "$CARDS_DIR/clock-weather-card"

install_release_file \
  "NemesisRE/kiosk-mode" \
  "$KIOSK_MODE_VERSION" \
  "kiosk-mode.js" \
  "$CARDS_DIR/kiosk-mode"

install_release_file \
  "kalkih/mini-media-player" \
  "$MINI_MEDIA_PLAYER_VERSION" \
  "mini-media-player-bundle.js" \
  "$CARDS_DIR/mini-media-player"

install_release_file \
  "ofekashery/vertical-stack-in-card" \
  "$VERTICAL_STACK_IN_CARD_VERSION" \
  "vertical-stack-in-card.js" \
  "$CARDS_DIR/vertical-stack-in-card"

install_release_file \
  "KartoffelToby/better-thermostat-ui-card" \
  "$BETTER_THERMOSTAT_UI_CARD_VERSION" \
  "better-thermostat-ui-card.js" \
  "$CARDS_DIR/better-thermostat-ui-card"

install_release_file \
  "piitaya/lovelace-mushroom" \
  "$MUSHROOM_VERSION" \
  "mushroom.js" \
  "$CARDS_DIR/mushroom"

install_release_file \
  "ExperienceLovelace/ha-floorplan" \
  "$HA_FLOORPLAN_VERSION" \
  "floorplan.js" \
  "$CARDS_DIR/ha-floorplan"

install_release_file \
  "kalkih/mini-graph-card" \
  "$MINI_GRAPH_CARD_VERSION" \
  "mini-graph-card-bundle.js" \
  "$CARDS_DIR/mini-graph-card"

install_release_file \
  "joseluis9595/lovelace-navbar-card" \
  "$NAVBAR_CARD_VERSION" \
  "navbar-card.js" \
  "$CARDS_DIR/navbar-card"

# Type 3: single file from source archive
install_from_source \
  "Nerwyn/custom-card-features" \
  "$CUSTOM_CARD_FEATURES_VERSION" \
  "dist/custom-card-features.min.js" \
  "$CARDS_DIR/custom-card-features"

install_from_source \
  "thomasloven/lovelace-card-mod" \
  "$LOVELACE_CARD_MOD_VERSION" \
  "card-mod.js" \
  "$CARDS_DIR/lovelace-card-mod"

install_from_source \
  "Clooos/Bubble-Card" \
  "$BUBBLE_CARD_VERSION" \
  "dist/bubble-card.js" \
  "$CARDS_DIR/bubble-card"

install_from_source \
  "Clooos/Bubble-Card" \
  "$BUBBLE_CARD_VERSION" \
  "dist/bubble-pop-up-fix.js" \
  "$CARDS_DIR/bubble-card"

echo ""
echo "Done. Installed cards:"
find "$CARDS_DIR" -mindepth 1 -maxdepth 1 -type d | sort

# ---------------------------------------------------------------------------
# Generate .storage/lovelace_resources so cards are registered with HA
# without needing to add each one through the UI.
# IMPORTANT: this file is read by HA only at startup, so HA must be
# stopped/restarted for changes to take effect.
# ---------------------------------------------------------------------------
STORAGE_DIR="homeassistant/.storage"
RESOURCES_FILE="$STORAGE_DIR/lovelace_resources"

mkdir -p "$STORAGE_DIR"

# Backup if exists
if [ -f "$RESOURCES_FILE" ]; then
  cp "$RESOURCES_FILE" "${RESOURCES_FILE}.bak"
  echo ""
  echo "Existing $RESOURCES_FILE backed up to ${RESOURCES_FILE}.bak"
fi

# (resource_id, url) pairs — order matters: card-mod must load early so other
# cards can reference its CSS extensions.
cat > "$RESOURCES_FILE" <<'EOF'
{
  "version": 1,
  "minor_version": 1,
  "key": "lovelace_resources",
  "data": {
    "items": [
      { "id": "card-mod",                   "type": "module", "url": "/local/community/lovelace-card-mod/card-mod.js" },
      { "id": "custom-card-features",       "type": "module", "url": "/local/community/custom-card-features/custom-card-features.min.js" },
      { "id": "mushroom",                   "type": "module", "url": "/local/community/mushroom/mushroom.js" },
      { "id": "bubble-card",                "type": "module", "url": "/local/community/bubble-card/bubble-card.js" },
      { "id": "advanced-camera-card",       "type": "module", "url": "/local/community/advanced-camera-card/advanced-camera-card.js" },
      { "id": "better-thermostat-ui-card",  "type": "module", "url": "/local/community/better-thermostat-ui-card/better-thermostat-ui-card.js" },
      { "id": "clock-weather-card",         "type": "module", "url": "/local/community/clock-weather-card/clock-weather-card.js" },
      { "id": "ha-floorplan",               "type": "module", "url": "/local/community/ha-floorplan/floorplan.js" },
      { "id": "kiosk-mode",                 "type": "module", "url": "/local/community/kiosk-mode/kiosk-mode.js" },
      { "id": "mini-graph-card",            "type": "module", "url": "/local/community/mini-graph-card/mini-graph-card-bundle.js" },
      { "id": "mini-media-player",          "type": "module", "url": "/local/community/mini-media-player/mini-media-player-bundle.js" },
      { "id": "navbar-card",                "type": "module", "url": "/local/community/navbar-card/navbar-card.js" },
      { "id": "vertical-stack-in-card",     "type": "module", "url": "/local/community/vertical-stack-in-card/vertical-stack-in-card.js" }
    ]
  }
}
EOF

echo "Wrote $RESOURCES_FILE with $(grep -c '"id":' "$RESOURCES_FILE") resources."
echo ""
echo "Restart Home Assistant for resources to take effect:"
echo "  docker compose restart homeassistant"
