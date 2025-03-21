#!/bin/ash

set -e

if ! test -f /mosquitto/passwd; then
  echo "mosquitto passwordfile does not exist."
  # create mosquitto passwordfile
  touch /mosquitto/passwd
  chmod 0700 /mosquitto/passwd
  mosquitto_passwd -b -c /mosquitto/passwd connectivity $MOSQUITTO_PASSWORD
fi

# Fix write permissions for mosquitto directories
chown --no-dereference --recursive mosquitto:mosquitto /mosquitto/passwd
chown --no-dereference --recursive mosquitto /mosquitto/log
chown --no-dereference --recursive mosquitto /mosquitto/data

mkdir -p /var/run/mosquitto \
  && chown --no-dereference --recursive mosquitto /var/run/mosquitto

exec "$@"