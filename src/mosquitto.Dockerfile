ARG MOSQUITTO_VERSION
FROM eclipse-mosquitto:${MOSQUITTO_VERSION}

COPY mosquitto-docker-entrypoint.sh /
ENTRYPOINT ["sh", "./mosquitto-docker-entrypoint.sh"]
CMD ["/usr/sbin/mosquitto","-c","/mosquitto/config/mosquitto.conf"]