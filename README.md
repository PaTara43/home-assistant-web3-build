# home-assistant-web3-build

This repository contains all nessesary packages to start Assistant + ipfs daemon + libp2p proxy + zigbee2mqtt + mosquitto on RISCV64 architecture.


## Requirements 

ожидается что у вас установлена убунта по этой инструкции и вы успешно на нее зашли - https://canonical-ubuntu-boards.readthedocs-hosted.com/en/latest/how-to/starfive-visionfive/

## Installation

Run bash script:

сначала надо поставить пакеты котроые пока не обернуты в докер. Также постпавить и сам докер.
Для этого достаточно запустить скрипт `pre-setup.sh`


After everything started, Home Assistant web interface will be on 8123 port and zigbee2mqtt on 8099 port.


It will stop and delete running docker containers.


## Run