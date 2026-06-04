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
  pan_id: GENERATE
  ext_pan_id: GENERATE
  network_key: GENERATE
  last_seen: 'ISO_8601'
  log_level: warn

frontend:
  port: 8099
  auth_token: ${Z2M_AUTH_TOKEN}

serial:
  port: /dev/ttyACM0
  adapter: ${ZIGBEE_ADAPTER}

availability:
  enabled: true

device_options:
  homeassistant:
    last_seen:
      enabled_by_default: true
