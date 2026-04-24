FROM ghcr.io/richyp7/iec60870-5-104-simulator:v0.1.7
# IEC-60870-5-104 simulator seeded with UUPL substation datapoints.
# Datapoints represent Dolly Sisters / Nap Hill feeder segment:
#   feeder_a/b_voltage (TypeId 13, short float): energised feeders ~10.8-11.1 kV
#   load_current (TypeId 13): moderate load at 340 A
#   frequency (TypeId 13): 49.98 Hz (slightly off nominal, within normal tolerance)
#   breaker_a/b_state (TypeId 1, boolean): closed, correlating with non-zero voltage
# Values are internally consistent: an attacker who sets feeder voltage to 0 while
# breaker_state stays true creates an operationally impossible reading.
# :2404  IEC-104 protocol endpoint
# :8080  REST API with no authentication (reconfigure datapoints on the fly)
# Attack path: POST to :8080 API -> falsify datapoint values -> operator mis-response.
USER root
RUN apt-get update \
    && apt-get install -y --no-install-recommends iproute2 gosu \
    && rm -rf /var/lib/apt/lists/*
COPY SimulationOptions.json /app/Configuration/SimulationOptions.json
COPY entrypoint.sh /dmz-entrypoint.sh
RUN chmod +x /dmz-entrypoint.sh
EXPOSE 2404 8080
ENTRYPOINT ["/dmz-entrypoint.sh"]
