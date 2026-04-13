FROM iotechsys/pymodbus-sim:1.0.6-x86_64
COPY configs/ /sim/configs/
COPY scripts/ /sim/scripts/
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
EXPOSE 502
ENTRYPOINT ["/entrypoint.sh"]
