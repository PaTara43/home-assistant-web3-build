#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Get environment variables
source $SCRIPT_DIR/raw_passwd_mqtt.txt
source $SCRIPT_DIR/../.env

cd $SCRIPT_DIR/../

if [ "$Z2MENABLE" = "true" ]; then
    echo "start docker with zigbee2mqtt"
    docker compose --profile z2m up -d
else
    echo "start docker without zigbee2mqtt"
    docker compose up -d
fi