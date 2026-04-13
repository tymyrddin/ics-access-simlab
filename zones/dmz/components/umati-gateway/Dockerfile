FROM ghcr.io/umati/umatigateway:pr-375
# Pre-fix build — web UI on :8080 has no authentication (CVE-2025-27615).
# Attacker can read and modify all OPC UA server connections and MQTT routing.
EXPOSE 8080
