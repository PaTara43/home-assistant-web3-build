# home-assistant-web3-build

This repository contains all nessesary packages to start Assistant + ipfs daemon + libp2p proxy + zigbee2mqtt + mosquitto on RISCV64 architecture.


## Requirements 

ожидается что у вас установлена убунта по этой инструкции и вы успешно на нее зашли - https://canonical-ubuntu-boards.readthedocs-hosted.com/en/latest/how-to/starfive-visionfive/
также рекомендуется обновить все зависимости:
```commandline
sudo apt-get update && sudo apt-get upgrade
```

## Installation

ВАЖНО - все скрипты должны хапускаться под одним пользователем.

сначала ставим докер. для этого достаточно запустить скрипт docker-setup.sh
```commandline
bash scripts/docker-setup.sh
```

Далее надо поставить пакеты котроые пока не обернуты в докер.
Для этого достаточно запустить скрипт `pre-setup.sh`

```commandline
bash scripts/pre-setup.sh
```


## Run