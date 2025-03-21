#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"


sudo apt-get update
sudo apt-get install wget unzip git jq -y

#install mosquitto

# create password for mqtt. Then save it in mosquitto home directory and provide this data to z2m configuration
MOSQUITTO_PASSWORD=$(openssl rand -hex 10)
echo "$MOSQUITTO_PASSWORD" > $SCRIPT_DIR/raw_passwd_mqtt.txt

sudo apt install mosquitto mosquitto-clients -y
sudo mosquitto_passwd -b -c /etc/mosquitto/passwd mosquitto $MOSQUITTO_PASSWORD

echo "listener 1883
allow_anonymous false
password_file /etc/mosquitto/passwd" | sudo tee /etc/mosquitto/conf.d/local.conf

sudo chmod 664 /etc/mosquitto/passwd
sudo systemctl restart mosquitto

# install go

sudo tar -vxf $SCRIPT_DIR/../pkg/go1.24.0.linux-riscv64.tar.gz -C /usr/local
# Add to your PATH
export PATH="/usr/local/go/bin:$PATH"
# Add to bashrc
echo "export PATH=/usr/local/go/bin:$PATH" >> ~/.bashrc

#install ipfs
sudo cp $SCRIPT_DIR/../pkg/ipfs_riscv64 /usr/local/bin/ipfs

ipfs init -p local-discovery
ipfs bootstrap add /dns4/1.pubsub.aira.life/tcp/443/wss/ipfs/QmdfQmbmXt6sqjZyowxPUsmvBsgSGQjm4VXrV7WGy62dv8
ipfs bootstrap add /dns4/2.pubsub.aira.life/tcp/443/wss/ipfs/QmPTFt7GJ2MfDuVYwJJTULr6EnsQtGVp8ahYn9NSyoxmd9
ipfs bootstrap add /dns4/3.pubsub.aira.life/tcp/443/wss/ipfs/QmWZSKTEQQ985mnNzMqhGCrwQ1aTA6sxVsorsycQz9cQrw

echo "[Unit]
Description=IPFS Daemon Service
Documentation=https://docs.ipfs.tech/
After=network.target

[Service]
# don't use swap
MemorySwapMax=0
MemoryHigh=1.5G
MemoryMax=2G

# Don't timeout on startup. Opening the IPFS repo can take a long time in some cases (e.g., when badger is recovering) and migrations can delay startup.
TimeoutStartSec=infinity

Type=notify
User=$USER
ExecStart=/usr/local/bin/ipfs daemon --enable-gc
Restart=on-failure
KillSignal=SIGINT

[Install]
WantedBy=default.target

  " | sudo tee /etc/systemd/system/ipfs.service

sudo systemctl enable ipfs.service
sudo systemctl start ipfs.service

# install libp2p proxy
sudo apt-get install npm -y
git clone https://github.com/PinoutLTD/libp2p-ws-proxy.git -C $SCRIPT_DIR/
cd $SCRIPT_DIR/libp2p-ws-proxy
npm install

echo "[Unit]
Description= Libp2p Proxy Service

[Service]
Type=simple
WorkingDirectory=$SCRIPT_DIR/libp2p-ws-proxy/
ExecStart=/usr/bin/node src/index.js
User=$USER
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
  " | sudo tee /etc/systemd/system/libp2p-proxy.service

sudo systemctl enable libp2p-proxy.service
sudo systemctl start libp2p-proxy.service