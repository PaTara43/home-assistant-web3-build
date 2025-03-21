# home-assistant-web3-build

This repository contains all nessesary packages to start Assistant + ipfs daemon + libp2p proxy + zigbee2mqtt + mosquitto on RISCV64 architecture.


## Requirements 

ожидается что у вас установлена убунта по этой инструкции и вы успешно на нее зашли - https://canonical-ubuntu-boards.readthedocs-hosted.com/en/latest/how-to/starfive-visionfive/
также рекомендуется обновить все зависимости:
```commandline
sudo apt-get update && sudo apt-get upgrade
```

## Installation

ВАЖНО - все скрипты должны хапускаться под одним пользователем.  также они будут требоавть права суперюхера

сначала ставим докер. для этого достаточно запустить скрипт docker-setup.sh
```commandline
bash scripts/docker-setup.sh
```

Далее надо поставить пакеты котроые пока не обернуты в докер.
Для этого достаточно запустить скрипт `pre-setup.sh`

```commandline
bash scripts/pre-setup.sh
```

Теперь давайте создадим все необходимы конфиг файлы. Для этого скопирйте все из шаблона конфига к свой конфиг:
```commandline
cp template.env .env
```
After that,You may open the file and edit default values such as:

- path to repository where will be stored all configurations folders.
- time zone in "tz database name".
- зигби канал

и запукаем скрипт. Данный скрипт создст все необходимые конфигурационные директории и подтянет переменные окружения

```commandline
bash scripts/setup.sh
```
## Run
Теперь все готово чтобы запустить доер контейнеры с home assistant и zigbee2mqtt. Достаточно вызвать скрипт start.sh