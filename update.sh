#!/bin/bash

# first we need to find installed version of images
IFS='   ' #setting space as delimiter

STR="$(docker image ls | grep koenkk/zigbee2mqtt)"
read -a ADDR <<<"$STR"
Z2M_CUR_VER=${ADDR[1]}

STR="$(docker image ls | grep ghcr.io/home-assistant/home-assistant)"
read -a ADDR <<<"$STR"
HA_CUR_VER=${ADDR[1]}

echo "Current version of packages:"
echo "Zigbee2MQTT version - $Z2M_CUR_VER"
echo "Home Assistant version - $HA_CUR_VER"

echo "Update git repository"
git pull

# grap variables from .env file excluding comments
export $(grep -v '^#' .env | xargs)
export Z2MPATH

# Check the last symbol in path. if it is "/", then delete it.
LAST_SYMBOL=${CONFIG_PATH: -1}
echo "$LAST_SYMBOL"
if [ "$LAST_SYMBOL" = "/" ]; then
  CONFIG_PATH="${CONFIG_PATH%?}"
fi

# find new version of the packages
export $(grep -v '^#' scripts/packages.env | xargs)

# download new docker images

docker compose --profile z2m pull

# save current path to return later
CURRENT_PATH=$(pwd)

cd $CONFIG_PATH
echo "config path - $CONFIG_PATH"
sh stop.sh

#check Z2M path - if we have it, then start compose with Z2M
if [ "$Z2MPATH" = "." ]; then
    echo "Don't have zigbee coordinator. Start compose without it."
    docker compose up -d
else
    echo "Find zigbee coordinator. Start compose with Z2M container."
    docker compose --profile z2m up -d
fi

echo "compose started. Start cleaning old images."

if [ "$Z2M_CUR_VER" = "$Z2M_VERSION" ]; then
    echo "Z2M image uptodate"

else
    echo "Delete old Z2m image"
    docker image rm koenkk/zigbee2mqtt:${Z2M_CUR_VER}
fi

if [ "$HA_CUR_VER" = "$HA_VERSION" ]; then
    echo "HA image uptodate"

else
    echo "Delete old HA image"
    docker image rm ghcr.io/home-assistant/home-assistant:${HA_CUR_VER}
fi
