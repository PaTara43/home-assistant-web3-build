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

THEMES_DIR="homeassistant/themes"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$THEMES_DIR"

# ---------------------------------------------------------------------------
# Helper: download a subfolder from a GitHub release tarball into a target.
# install_subfolder REPO TAG SUBPATH TARGET_DIR
# ---------------------------------------------------------------------------
install_subfolder() {
  local repo="$1" tag="$2" subpath="$3" target="$4"
  local url="https://codeload.github.com/${repo}/tar.gz/refs/tags/${tag}"

  echo "==> ${repo}@${tag} :: ${subpath} -> ${target}"

  # Wipe target so removed files in upstream don't linger
  rm -rf "$target"
  mkdir -p "$target"

  # Tar inside the github tarball is wrapped in a top-level dir like
  # "lovelace-ios-themes-3.0.1/", so total strip = 1 (top dir) + path depth.
  local depth
  depth=$(awk -F'/' '{print NF}' <<<"$subpath")
  local strip=$((1 + depth))

curl -fsSL "$url" \
    | tar -xz -C "$target" --strip-components="$strip" --wildcards "*/${subpath}/*"
}

install_subfolder \
  "basnijholt/lovelace-ios-themes" \
  "$IOS_THEMES_VERSION" \
  "themes" \
  "$THEMES_DIR/ios_themes"

install_subfolder \
  "Nezz/homeassistant-visionos-theme" \
  "$VISIONOS_THEME_VERSION" \
  "themes" \
  "$THEMES_DIR/visionos"

install_subfolder \
  "PinoutLTD/HA.Themes" \
  "$PINOUT_THEME_VERSION" \
  "themes" \
  "$THEMES_DIR/pinout"

echo ""
echo "Done. Installed themes:"
find "$THEMES_DIR" -mindepth 1 -maxdepth 2 -type d | sort
