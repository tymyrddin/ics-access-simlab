# Secure supply chain review

This project is an intentionally vulnerable industrial simulation environment built from widely used open source 
components. It is designed to reproduce realistic failure modes found in OT and ICS ecosystems, including insecure 
defaults, protocol weaknesses, and trust boundary ambiguity.

The supply chain is not an accident here. It is part of the model. That said, open source does not become less 
unpredictable just because it is invited to behave badly on purpose.

## Scope

This review covers:

* SCADA and HMI layer
* Protocol simulators and gateways
* Messaging and transport components
* Actuator simulation
* Python libraries used for control, messaging, and protocol handling

The focus is on how supply chain behaviour contributes to realistic attack surfaces in a controlled lab context.

## Design intent

This environment intentionally reflects common real-world conditions:

* Mixed trust zones across industrial networks
* Protocol translation between insecure and semi-secure systems
* Legacy protocols with minimal authentication
* Monitoring and logging systems with uneven integrity guarantees

The goal is realism, not sanitisation. Industrial systems rarely fail in neat ways.

## SCADA and HMI

Scada-LTS forms the supervisory control layer. It is Java-based and dependency-heavy, which already places it close to typical enterprise SCADA realities.

Key characteristics in this context:

* Large dependency trees reflect real-world maintenance challenges
* Demo and default configurations can expose administrative surfaces
* Plugin extensibility increases both realism and attack surface variety

In this environment, Scada-LTS behaves less like a product and more like a small ecosystem pretending it is a single application.

## Protocol simulators and gateways

### Neuron (EMQ Technologies)

This component bridges industrial protocols and messaging systems, creating a deliberate trust boundary.

* Protocol translation introduces realistic cross-domain trust risks
* Misalignment between protocol assumptions can produce exploitable data flows
* Broad network access mirrors real deployment conditions

This is one of the primary “interesting failure points” in the system, by design.

### umatiGateway (umati community)

* OPC UA certificate handling reflects common industrial deployment complexity
* Trust relationships can persist longer than intended in lab setups
* Configuration drift can turn test trust into permanent trust

### opc-ua-demo-server (thin-edge.io)

* Demo-focused configuration reflects common onboarding shortcuts
* Authentication and access controls may be simplified
* Useful for modelling early-stage integration risk

### IEC 60870-5-104 Simulator (RichyP7)

* IEC-104 protocol behaviour is faithfully reproduced, including its historical security gaps
* Lack of strong authentication is part of the protocol model
* Suitable for replay-style and injection-style simulation scenarios

## Messaging and transport

### Eclipse Mosquitto

Mosquitto acts as the central messaging backbone.

* Broker-level trust assumptions are central to system behaviour
* Anonymous or weak authentication modes may exist in lab configurations
* Topic isolation depends heavily on configuration discipline

In practice, this component defines how far trust can spread before it becomes visible.

### stunnel (dweomer image)

* TLS wrapping introduces realistic secure tunnel modelling
* Misconfiguration can produce a false sense of encryption coverage
* Third-party image provenance introduces realistic supply chain uncertainty

### BIND9 (Ubuntu)

* DNS behaviour is critical to system-wide identity resolution
* Recursive resolution and caching reflect real operational risks
* Misconfiguration can create systemic rather than local failures

### cturra/ntp

* Time synchronisation supports correlation and forensic accuracy
* Drift or spoofing affects system interpretation of events
* Exposure risk depends on network placement

### atmoz/sftp

* File transfer services often act as staging points between zones
* Authentication simplicity reflects common deployment shortcuts
* Upload paths can become unintended data ingress channels

### syslog-ng

* Central logging concentrates observability and sensitive data
* Integrity is often assumed rather than enforced
* Logging pipelines can become secondary attack surfaces

## Actuator simulation

### pymodbus-sim (IOTech Systems)

* Modbus protocol assumes trust in network locality
* Simulation faithfully reproduces unsafe but realistic behaviour
* Input handling can expose protocol-level weaknesses

This layer is intentionally close to real industrial fragility, including its tendency to assume polite traffic.

## Python libraries

### pymodbus

* Handles untrusted protocol data by design
* Parsing edge cases can produce unexpected behaviour
* Often used as a building block for higher-level simulation logic

### paho-mqtt

* Security posture depends heavily on configuration choices
* Example usage patterns can influence insecure deployments
* Common in both secure and insecure real-world systems

## Cross cutting supply chain behaviour

### Mixed provenance containers

The system combines:

* Official upstream images
* Community maintained images
* Domain specific builds

This creates a deliberate trust gradient, which reflects real industrial ecosystems where not all components originate from the same assurance level.

### Dependency depth and drift

The stack spans Java, Python, and C-based networking components. Each evolves independently, creating natural version drift across the system.

This drift is not necessarily a flaw. It is often what real deployments look like after a few procurement cycles.

### Configuration drift as a feature of realism

The most significant long term behaviour is configuration evolution:

* Debug modes that persist longer than intended
* Demo credentials that become structural dependencies
* Security settings adjusted for convenience and never reverted

In real environments, these are not edge cases. They are the default outcome of time.

### Trust boundary design

The architecture intentionally includes multiple trust transitions:

* protocol translation layers
* messaging brokers
* storage and logging systems

Each boundary represents a point where assumptions about trust are tested. Sometimes gently. Sometimes not.

## Baseline security model for the environment

Security controls in this environment are treated as adjustable parameters rather than fixed constraints.

Common patterns include:

* Version pinning across container builds for reproducibility
* SBOM generation to track dependency composition
* Selective TLS usage to model both secure and insecure deployments
* Network segmentation aligned with industrial zones
* Explicit broker access configuration
* Centralised logging for observability of failure scenarios
* Automated scanning to surface known vulnerabilities as part of the learning model

## Closing note

This is a deliberately constructed vulnerable ecosystem, assembled from real-world components that are already used 
in production environments.

The supply chain does not introduce artificial weakness. It exposes existing ones in a controlled form.

The key lesson is not that these components are unsafe. It is that they are safe only within very specific 
assumptions about configuration, trust, and attention.

And industrial systems are famously optimistic about all three.
