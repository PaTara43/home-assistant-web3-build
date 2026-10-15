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

# iOS themes backgrounds are served by HA itself. The "-alternative" themes
# expect them in /config/www/ios-themes/; the regular ones load the same jpgs
# from cdn.jsdelivr.net, which is unreachable offline or behind blocks, so
# point those at the local copy too.
IOS_BG_DIR="homeassistant/www/ios-themes"
rm -rf "$IOS_BG_DIR"
mkdir -p "$IOS_BG_DIR"
mv "$THEMES_DIR"/ios_themes/*.jpg "$IOS_BG_DIR"/
sed -i -E 's#https://cdn\.jsdelivr\.net/gh/basnijholt/lovelace-ios-themes@[0-9a-f]+/themes/#/local/ios-themes/#g' \
  "$THEMES_DIR"/ios_themes/*.yaml
if grep -q "url('http" "$THEMES_DIR"/ios_themes/*.yaml; then
  echo "WARNING: remote URLs left in iOS themes (upstream format changed?):" >&2
  grep -n "url('http" "$THEMES_DIR"/ios_themes/*.yaml >&2
fi
echo "==> iOS themes backgrounds -> ${IOS_BG_DIR}"

install_subfolder \
  "Nezz/homeassistant-visionos-theme" \
  "$VISIONOS_THEME_VERSION" \
  "themes" \
  "$THEMES_DIR/visionos"

# visionOS themes load their backgrounds from raw.githubusercontent.com (some
# from the moving "static" branch) and the release tarball doesn't ship them:
# fetch each one now and serve it from /config/www/visionos/.
VISIONOS_BG_DIR="homeassistant/www/visionos"
VISIONOS_BG_RE="https://raw\.githubusercontent\.com/Nezz/homeassistant-visionos-theme/[^']*/([^/']+)'"
rm -rf "$VISIONOS_BG_DIR"
mkdir -p "$VISIONOS_BG_DIR"
mapfile -t visionos_bg_urls < <(
  grep -ohE "$VISIONOS_BG_RE" "$THEMES_DIR"/visionos/*.yaml | tr -d "'" | sort -u
)
for url in "${visionos_bg_urls[@]}"; do
  name="${url##*/}"
  if [[ -e "$VISIONOS_BG_DIR/$name" ]]; then
    echo "ERROR: two visionOS backgrounds share the file name ${name}" >&2
    exit 1
  fi
  curl -fsSL "$url" -o "$VISIONOS_BG_DIR/$name"
done
sed -i -E "s#${VISIONOS_BG_RE}#/local/visionos/\\1'#g" "$THEMES_DIR"/visionos/*.yaml
echo "==> visionOS themes backgrounds (${#visionos_bg_urls[@]}) -> ${VISIONOS_BG_DIR}"

if grep -q "url('http" "$THEMES_DIR"/visionos/*.yaml; then
  echo "WARNING: remote URLs left in visionOS themes (upstream format changed?):" >&2
  grep -n "url('http" "$THEMES_DIR"/visionos/*.yaml >&2
fi

install_subfolder \
  "PinoutLTD/HA.Themes" \
  "$PINOUT_THEME_VERSION" \
  "themes" \
  "$THEMES_DIR/pinout"

echo ""
echo "Done. Installed themes:"
find "$THEMES_DIR" -mindepth 1 -maxdepth 2 -type d | sort
