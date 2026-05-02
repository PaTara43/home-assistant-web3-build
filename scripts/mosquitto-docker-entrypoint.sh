#!/bin/ash
set -eu

# Create password file on first start, hashed by mosquitto_passwd.
if [ ! -f /mosquitto/passwd ]; then
  echo "mosquitto password file does not exist, creating..."
  : > /mosquitto/passwd
  mosquitto_passwd -b /mosquitto/passwd connectivity "$MOSQUITTO_PASSWORD"
  chmod 0600 /mosquitto/passwd
fi

# Fix ownership for runtime directories.
chown mosquitto:mosquitto /mosquitto/passwd
chown -R mosquitto /mosquitto/log /mosquitto/data
mkdir -p /var/run/mosquitto
chown -R mosquitto /var/run/mosquitto

exec "$@"