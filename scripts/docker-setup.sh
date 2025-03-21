#!/bin/bash

set -euo pipefail
#isntall Docker.io

sudo apt-get update
sudo apt-get install docker.io wget unzip git jq -y

GROUP="docker"
USER_TO_ADD="$USER"

# Check if the group exists
if getent group "$GROUP" > /dev/null; then
    echo "Group '$GROUP' already exists."
else
    echo "Group '$GROUP' not found. Creating..."
    sudo groupadd "$GROUP"
    echo "Group '$GROUP' successfully created."
fi

# Check if the user is already in the group
if id -nG "$USER_TO_ADD" | grep -qw "$GROUP"; then
    echo "User '$USER_TO_ADD' is already in the group '$GROUP'."
else
    echo "Adding user '$USER_TO_ADD' to group '$GROUP'..."
    sudo usermod -aG "$GROUP" "$USER_TO_ADD"
    echo "User '$USER_TO_ADD' added to group '$GROUP'."
fi
newgrp docker