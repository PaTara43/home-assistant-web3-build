# Home Assistant integration (MQTT discovery)
homeassistant:
  enabled: true
  legacy_action_sensor: true

# Allow new devices to join (toggle from frontend later)
permit_join: false

mqtt:
  base_topic: zigbee2mqtt
  server: 'mqtt://localhost'
  user: connectivity
  password: ${MOSQUITTO_PASSWORD}

advanced:
  channel: ${ZIGBEE_CHANNEL}
  last_seen: 'ISO_8601'

frontend:
  port: 8099

serial:
  port: /dev/ttyACM0
  adapter: ${ZIGBEE_ADAPTER}

availability:
  enabled: true

device_options:
  homeassistant:
    last_seen:
      enabled_by_default: true
