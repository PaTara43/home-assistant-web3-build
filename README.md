
# home-assistant-web3-build

This repository contains all the necessary packages to run **Home Assistant**, **IPFS daemon**, **libp2p proxy**, **Zigbee2MQTT**, and **Mosquitto** on the **RISCV64** architecture.

---

## Requirements

It is expected that you have Ubuntu installed and running according to this guide:  
👉 [StarFive VisionFive - Ubuntu Installation Guide](https://canonical-ubuntu-boards.readthedocs-hosted.com/en/latest/how-to/starfive-visionfive-2/)

It is also recommended to update all dependencies:

```bash
sudo apt-get update && sudo apt-get upgrade
```

---

## Installation

⚠️ **IMPORTANT:** All scripts must be executed under the same user. Some of them will require superuser (sudo) privileges.

1. **Install Docker**  
   Run the Docker  and Docker compose installation script:
   ```bash
   bash scripts/docker-setup.sh
   ```

2. **Install additional required packages (Non-Docker)**  
   Run the pre-setup script to install packages that are not containerized yet:
   ```bash
   bash scripts/pre-setup.sh
   ```

3. **Create and configure the environment file**  
   - Copy the environment template to create your `.env` file:
     ```bash
     cp template.env .env
     ```
   - Open the `.env` file and edit the following values:
     - `CONFIG_PATH`: Path to the repository where all configuration folders will be stored
     - `ZIGBEE_CHANNEL`: Zigbee channel number
   - Example:
     ```
     CONFIG_PATH=/home/user/home-assistant-web3-build
     ZIGBEE_CHANNEL=15
     ```

4. **Setup configuration**  
   Run the setup script to create all necessary configuration directories and load environment variables:
   ```bash
   bash scripts/setup.sh
   ```

---

## Run

Everything is ready! To start the Docker containers with **Home Assistant** and **Zigbee2MQTT**, simply run:

```bash
bash scripts/start.sh
```


✅ **Setup complete! You're ready to run your self-hosted Home Assistant environment with Zigbee, IPFS, and Web3 capabilities.**
