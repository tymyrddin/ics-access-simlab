FROM ghcr.io/richyp7/iec60870-5-104-simulator:v0.1.7
# IEC-60870-5-104 simulator.
# :2404  — IEC-104 protocol endpoint
# :8080  — REST API with no authentication (reconfigure datapoints on the fly)
# Attack path: POST to :8080 API → falsify datapoint values → operator mis-response.
EXPOSE 2404 8080
