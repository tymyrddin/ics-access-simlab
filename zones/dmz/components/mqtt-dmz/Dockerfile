FROM eclipse-mosquitto:2.0.22
USER root
RUN apk add --no-cache iproute2 su-exec
COPY mosquitto.conf /mosquitto/config/mosquitto.conf
COPY entrypoint.sh /dmz-entrypoint.sh
RUN chmod +x /dmz-entrypoint.sh
EXPOSE 1883
ENTRYPOINT ["/dmz-entrypoint.sh"]
CMD ["/usr/sbin/mosquitto", "-c", "/mosquitto/config/mosquitto.conf"]
