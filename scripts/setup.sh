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
  echo "ERROR: .env not found in repo root. Copy template.env to .env first:" >&2
  echo "  cp template.env .env" >&2
  exit 1
fi

# Refuse to run on a non-clean install.
for d in homeassistant mosquitto zigbee2mqtt matter-server matter-hub; do
  if [ -e "./$d" ]; then
    echo "ERROR: ./$d already exists. setup.sh expects a clean install." >&2
    echo "       To reset, run: bash scripts/stop.sh && rm -rf homeassistant mosquitto zigbee2mqtt matter-server matter-hub && rm -f .env && cp template.env .env && bash scripts/setup.sh" >&2
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
# Detect / configure Zigbee coordinator
#
# Two transports are supported:
#   usb (default) — auto-detected from /dev/serial/by-id/; device is mapped
#                   into the container as /dev/ttyACM0.
#   tcp           — PoE coordinators reached over the network (e.g. SMLight
#                   SLZB-06 on tcp://<host>:6638). No USB device is mapped;
#                   zigbee2mqtt reaches the coordinator via host networking.
# ---------------------------------------------------------------------------
if [ "${Z2M_TRANSPORT:-usb}" = "tcp" ]; then
  echo "Zigbee transport: tcp (PoE coordinator)"
  : "${Z2M_TCP_PORT:=6638}"
  if [ -z "${Z2M_TCP_HOST:-}" ]; then
    read -r -p "Enter PoE coordinator host/IP (e.g. 192.168.1.42): " Z2M_TCP_HOST
    if [ -z "$Z2M_TCP_HOST" ]; then
      echo "ERROR: Z2M_TCP_HOST is required for Z2M_TRANSPORT=tcp." >&2
      exit 1
    fi
  fi
  if [ -z "${Z2M_BAUDRATE:-}" ]; then
    echo "WARNING: Z2M_BAUDRATE is empty. Most PoE coordinators need a baudrate"
    echo "         (SLZB-06 -> 115200). Set it in .env or edit zigbee2mqtt/data/configuration.yaml later." >&2
  fi
  Z2M_SERIAL_PORT="tcp://${Z2M_TCP_HOST}:${Z2M_TCP_PORT}"
  Z2M_DEVICE_MAP="/dev/null:/dev/null"
  # Reuse Z2MPATH as the "z2m is enabled" marker (non-"." value).
  Z2MPATH="$Z2M_SERIAL_PORT"
else
  echo "Zigbee transport: usb"
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
  if [ "$Z2MPATH" != "." ]; then
    Z2M_SERIAL_PORT="/dev/ttyACM0"
    Z2M_DEVICE_MAP="${Z2MPATH}:/dev/ttyACM0"
  else
    Z2M_SERIAL_PORT=""
    Z2M_DEVICE_MAP="/dev/null:/dev/null"
  fi
fi

export Z2MPATH Z2M_SERIAL_PORT Z2M_DEVICE_MAP
echo "Z2MPATH=$Z2MPATH"
echo "Z2M_SERIAL_PORT=$Z2M_SERIAL_PORT"
echo "Z2M_DEVICE_MAP=$Z2M_DEVICE_MAP"

# ---------------------------------------------------------------------------
# Mosquitto + z2m: directories, config, password
# ---------------------------------------------------------------------------
echo "Creating mosquitto and zigbee2mqtt directories..."
mkdir -p mosquitto/config mosquitto/data mosquitto/log zigbee2mqtt/data

MOSQUITTO_PASSWORD="$(openssl rand -hex 16)"
echo -n "$MOSQUITTO_PASSWORD" > ./mosquitto/raw.txt
chmod 600 ./mosquitto/raw.txt
export MOSQUITTO_PASSWORD

# Single shared secret used as: HA admin password, matter-hub HTTP basic-auth
# password (username 'admin' is hardcoded in compose.yaml), and zigbee2mqtt
# frontend auth_token. Mosquitto's password is intentionally separate — it's
# a service-to-service credential, not a UI password.
MASTER_PASSWORD="$(openssl rand -hex 16)"
HA_ADMIN_PASSWORD="$MASTER_PASSWORD"
HAMH_HTTP_AUTH_PASSWORD="$MASTER_PASSWORD"
Z2M_AUTH_TOKEN="$MASTER_PASSWORD"
export Z2M_AUTH_TOKEN

cp ./scripts/addons_conf/mosquitto/mosquitto.conf ./mosquitto/config/mosquitto.conf

# Render zigbee2mqtt config from the template matching the transport.
if [ "$Z2M_TRANSPORT" = "tcp" ]; then
  Z2M_TPL="configuration.yaml.tcp.tpl"
else
  Z2M_TPL="configuration.yaml.usb.tpl"
fi
echo "Rendering zigbee2mqtt config from $Z2M_TPL"
envsubst < "./scripts/addons_conf/zigbee2mqtt/$Z2M_TPL" \
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
if profiles_has "matter-hub"; then
  mkdir -p matter-hub/data
fi
# ---------------------------------------------------------------------------
# Persist runtime values into .env
# ---------------------------------------------------------------------------
upsert_env_var "MOSQUITTO_PASSWORD" "$MOSQUITTO_PASSWORD" ".env"
upsert_env_var "Z2MPATH" "$Z2MPATH" ".env"
upsert_env_var "Z2M_AUTH_TOKEN" "$Z2M_AUTH_TOKEN" ".env"
upsert_env_var "Z2M_TRANSPORT" "$Z2M_TRANSPORT" ".env"
upsert_env_var "Z2M_TCP_HOST" "${Z2M_TCP_HOST:-}" ".env"
upsert_env_var "Z2M_TCP_PORT" "${Z2M_TCP_PORT:-6638}" ".env"
upsert_env_var "Z2M_BAUDRATE" "${Z2M_BAUDRATE:-}" ".env"
upsert_env_var "Z2M_DEVICE_MAP" "$Z2M_DEVICE_MAP" ".env"
upsert_env_var "Z2M_SERIAL_PORT" "$Z2M_SERIAL_PORT" ".env"

# ---------------------------------------------------------------------------
# Stage 1: bring up the stack WITHOUT matter-hub (it needs an HA token first).
# ---------------------------------------------------------------------------
FULL_PROFILES="$COMPOSE_PROFILES"
STAGE1_PROFILES="$(echo ",${COMPOSE_PROFILES}," | sed 's/,matter-hub,/,/g; s/^,//; s/,$//')"
export COMPOSE_PROFILES="$STAGE1_PROFILES"

echo "----"
echo "Stage 1: docker compose up with profiles: '${COMPOSE_PROFILES:-<none>}'"
echo "----"
docker compose up -d

# ---------------------------------------------------------------------------
# Headless HA onboarding (always done — gives us a ready-to-use admin account
# and lets the UI skip the wizard on first login). Whether matter-hub starts
# afterwards depends on the profile.
#
# Flow:
#   1. Wait for /api/onboarding to respond.
#   2. POST /api/onboarding/users  -> auth_code (creates the first HA user).
#   3. POST /auth/token            -> short-lived access_token.
#   4. WebSocket auth/long_lived_access_token -> token for matter-hub.
#   5. POST core_config / analytics / integration -> finish wizard headlessly.
#   6. Persist token in .env, optionally start matter-hub.
# ---------------------------------------------------------------------------
HA_ADMIN_USERNAME="admin"
HA_ADMIN_LANGUAGE="en"

echo -n "$HA_ADMIN_PASSWORD" > ./homeassistant/raw.txt
chmod 600 ./homeassistant/raw.txt

if echo ",${FULL_PROFILES}," | grep -q ",matter-hub,"; then
  echo -n "$HAMH_HTTP_AUTH_PASSWORD" > ./matter-hub/raw.txt
  chmod 600 ./matter-hub/raw.txt
fi

echo "Waiting for Home Assistant API on http://localhost:8123 ..."
HA_READY=0
for i in $(seq 1 18); do
  if curl -fs -o /dev/null "http://localhost:8123/api/onboarding"; then
    HA_READY=1
    break
  fi
  JOKE_JSON="$(curl -fs --max-time 3 \
    -H 'Accept: application/json' \
    -A 'home-assistant-web3-build setup (https://github.com/PaTara43/home-assistant-web3-build)' \
    'https://v2.jokeapi.dev/joke/Any?type=single&safe-mode' 2>/dev/null || true)"
  JOKE="$(printf '%s' "$JOKE_JSON" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("joke","").strip())
except: pass' 2>/dev/null || true)"
  if [ -n "$JOKE" ]; then
    echo "  [${i}/18] HA still booting. Here's a joke while you wait:"
    printf '%s\n' "$JOKE" | sed 's/^/         /'
  else
    echo "  [${i}/18] Home Assistant hasn't responded yet — that's fine, it's still booting. Retrying in 10s..."
  fi
  sleep 10
done
if [ "$HA_READY" -ne 1 ]; then
  echo "ERROR: Home Assistant did not come up within 180s." >&2
  exit 1
fi
echo "Home Assistant is responding."

CLIENT_ID="http://localhost:8123/"

echo "Creating first HA user '${HA_ADMIN_USERNAME}' via /api/onboarding/users ..."
ONBOARD_BODY="$(python3 -c 'import json,sys; cid,name,user,pwd,lang=sys.argv[1:6]; print(json.dumps({"client_id":cid,"name":name,"username":user,"password":pwd,"language":lang}))' \
  "$CLIENT_ID" "Admin" "$HA_ADMIN_USERNAME" "$HA_ADMIN_PASSWORD" "$HA_ADMIN_LANGUAGE")"
ONBOARD_RESP="$(curl -fsS -X POST "http://localhost:8123/api/onboarding/users" \
  -H "Content-Type: application/json" \
  -d "$ONBOARD_BODY")"
AUTH_CODE="$(printf '%s' "$ONBOARD_RESP" | python3 -c 'import json,sys; print(json.load(sys.stdin)["auth_code"])')"
if [ -z "$AUTH_CODE" ]; then
  echo "ERROR: failed to obtain auth_code from onboarding. Response: $ONBOARD_RESP" >&2
  exit 1
fi

echo "Exchanging auth_code for access token ..."
TOKEN_RESP="$(curl -fsS -X POST "http://localhost:8123/auth/token" \
  --data-urlencode "client_id=${CLIENT_ID}" \
  --data-urlencode "grant_type=authorization_code" \
  --data-urlencode "code=${AUTH_CODE}")"
ACCESS_TOKEN="$(printf '%s' "$TOKEN_RESP" | python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"])')"
if [ -z "$ACCESS_TOKEN" ]; then
  echo "ERROR: failed to obtain access_token. Response: $TOKEN_RESP" >&2
  exit 1
fi

echo "Requesting long-lived access token for matter-hub ..."
LL_TOKEN="$(docker compose exec -T homeassistant python3 - "$ACCESS_TOKEN" <<'PYEOF'
import asyncio, sys, aiohttp

async def main():
    token = sys.argv[1]
    async with aiohttp.ClientSession() as s:
        async with s.ws_connect("http://localhost:8123/api/websocket") as ws:
            await ws.receive_json()  # auth_required
            await ws.send_json({"type": "auth", "access_token": token})
            msg = await ws.receive_json()
            if msg.get("type") != "auth_ok":
                raise SystemExit(f"auth failed: {msg}")
            await ws.send_json({
                "id": 1,
                "type": "auth/long_lived_access_token",
                "client_name": "matter-hub",
                "lifespan": 3650,
            })
            resp = await ws.receive_json()
            if not resp.get("success"):
                raise SystemExit(f"token creation failed: {resp}")
            print(resp["result"])

asyncio.run(main())
PYEOF
)"
LL_TOKEN="$(printf '%s' "$LL_TOKEN" | tr -d '\r\n')"
if [ -z "$LL_TOKEN" ]; then
  echo "ERROR: long-lived token came back empty." >&2
  exit 1
fi

upsert_env_var "HA_ADMIN_PASSWORD" "$HA_ADMIN_PASSWORD" ".env"
upsert_env_var "HAMH_HTTP_AUTH_PASSWORD" "$HAMH_HTTP_AUTH_PASSWORD" ".env"
upsert_env_var "HAMH_HOME_ASSISTANT_ACCESS_TOKEN" "$LL_TOKEN" ".env"
echo "Long-lived token persisted in .env."

# ---------------------------------------------------------------------------
# Finish HA onboarding (steps 2-4) headlessly so that the UI doesn't try
# to resume the wizard on first login (which fails without a browser session).
#   - core_config: empty body -> HA uses defaults; TZ comes from container env.
#   - analytics  : empty body -> opt-out by default.
#   - integration: requires client_id + redirect_uri; the returned auth_code
#                  is unused — we just need the step flipped to "done".
# ---------------------------------------------------------------------------
echo "Finishing HA onboarding (core_config, analytics, integration) ..."
for step in core_config analytics; do
  curl -fsS -o /dev/null -X POST "http://localhost:8123/api/onboarding/${step}" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{}' \
    || echo "WARNING: onboarding step '${step}' returned non-2xx (continuing)." >&2
done
INTEGRATION_BODY="$(python3 -c 'import json,sys; cid=sys.argv[1]; print(json.dumps({"client_id":cid,"redirect_uri":cid}))' "$CLIENT_ID")"
curl -fsS -o /dev/null -X POST "http://localhost:8123/api/onboarding/integration" \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "$INTEGRATION_BODY" \
  || echo "WARNING: onboarding step 'integration' returned non-2xx (continuing)." >&2
echo "HA onboarding completed."

# ---------------------------------------------------------------------------
# Stage 2: bring up matter-hub now that the token is in .env (only if the
# profile is enabled — onboarding always runs, matter-hub does not).
# ---------------------------------------------------------------------------
if echo ",${FULL_PROFILES}," | grep -q ",matter-hub,"; then
  # Reload .env so docker compose sees HAMH_HOME_ASSISTANT_ACCESS_TOKEN,
  # then restore the reconciled COMPOSE_PROFILES (which sourcing .env clobbered).
  set -a
  # shellcheck disable=SC1091
  source ./.env
  set +a
  export COMPOSE_PROFILES="$FULL_PROFILES"
  echo "----"
  echo "Stage 2: docker compose up with profiles: '${COMPOSE_PROFILES:-<none>}'"
  echo "----"
  docker compose up -d
fi

echo ""
echo "Done. Service URLs (when respective profiles are enabled):"
echo "  Home Assistant : http://localhost:8123"
echo "  Zigbee2MQTT    : http://localhost:8099  (profile: z2m)"
echo "  Matter Server  : ws://localhost:5580/ws (profile: matter)"
echo "  Matter Hub     : http://localhost:8482  (profile: matter-hub)"
echo ""
echo "============================================================"
echo " Generated credentials"
echo ""
echo "  Master password (HA admin / matter-hub UI / z2m frontend token):"
echo "    ${MASTER_PASSWORD}"
echo ""
echo "  Home Assistant       http://localhost:8123"
echo "    user: ${HA_ADMIN_USERNAME}    pass: <master>    file: homeassistant/raw.txt"
echo ""
if echo ",${FULL_PROFILES}," | grep -q ",matter-hub,"; then
  echo "  Matter Hub web UI    http://localhost:8482"
  echo "    user: admin    pass: <master>    file: matter-hub/raw.txt"
  echo ""
  echo "  Note: a long-lived HA token for matter-hub is in .env"
  echo "        (HAMH_HOME_ASSISTANT_ACCESS_TOKEN). Do NOT delete the"
  echo "        '${HA_ADMIN_USERNAME}' HA user — the token is bound to it."
  echo ""
fi
if [ "$Z2MPATH" != "." ]; then
  echo "  Zigbee2MQTT          http://localhost:8099/?token=<master>"
  echo "    (single-token auth — paste master password as token, no user)"
  if [ "$Z2M_TRANSPORT" = "tcp" ]; then
    echo "    transport: TCP/PoE, coordinator at $Z2MPATH"
  else
    echo "    transport: USB, coordinator at $Z2MPATH"
  fi
  echo ""
fi
echo "  Mosquitto MQTT       (separate, service-to-service)"
echo "    user: connectivity    pass: ${MOSQUITTO_PASSWORD}    file: mosquitto/raw.txt"
echo "============================================================"
echo ""
echo "NOTE: .env now contains secrets. Do NOT commit it."