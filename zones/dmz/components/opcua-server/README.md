# OPC-UA server

`guild-register` runs the thin-edge OPC-UA demo server, a Rust application that
simulates an industrial pump with callable OPC-UA methods. Authentication is
anonymous. Security mode is None. Any OPC-UA client that reaches port 4840 can
browse the node tree, read all values, and call all methods including
`stopPump()`.

## Anonymous OPC-UA in the wild

OPC-UA servers with anonymous authentication and `SecurityMode=None` are common
in industrial environments where the OPC-UA specification was adopted for data
integration but the security model was left at factory defaults. Callable methods
are the most operationally significant feature: unlike passive data reads, method
calls can change device state. In a real site, calling `stopPump` on a process-
critical cooling pump has immediate physical consequences.

## Container details

Base image: `ghcr.io/thin-edge/opc-ua-demo-server:0.0.8`. Rust application. https://github.com/thin-edge/opc-ua-demo-server

Exposed port: 4840/tcp (OPC-UA binary protocol).

Endpoint: `opc.tcp://10.10.5.13:4840`

Authentication: anonymous (no credentials required).
Security mode: None (no signing or encryption).

Simulated device: industrial pump.

Available methods (callable via any OPC-UA client):
- `startPump`: starts the pump
- `stopPump`: stops the pump
- `resetFilter`: resets the filter state
- `changeOil`: marks an oil change

Browsable variables include pump status, flow rate, pressure, and operational
parameters.

## Connections

- `ics_dmz`: 10.10.5.13
- Reachable from `ics_internet` and from within `ics_dmz`
- umatiGateway (guild-exchange, 10.10.5.10) can be configured to subscribe to
  this server's nodes

## Protocols

OPC-UA binary: port 4840. No security. Anonymous authentication.

## Built-in vulnerabilities

Anonymous OPC-UA access: no username or password required. Any client with a
network route to port 4840 can connect and interact with the server.

`SecurityMode=None`: the connection is unsigned and unencrypted. An on-path
attacker can observe all OPC-UA traffic in plaintext, including read responses
containing process values and method call requests.

Callable methods: `stopPump()` and `startPump()` change device state. No access
control restricts which client can call these methods.

## Modifying vulnerabilities

To add authentication: the thin-edge demo server supports user/password
authentication via configuration. Consult the upstream repository for the config
file format and location within the container.

To add signing or encryption: configure a non-None security policy. This requires
generating application certificates and configuring the server's certificate store.

To add additional nodes or change method names: this requires a custom build
or a different OPC-UA server image.

## Hardening suggestions

Enable at minimum `SecurityMode=Sign` (or `SignAndEncrypt` where supported).
Disable anonymous authentication. Restrict callable methods to authenticated
users with appropriate roles. Restrict network access to port 4840 to the
specific OPC-UA client addresses that legitimately need it.

## Observability and debugging

```bash
docker logs opcua-server
```

Connect and browse with an OPC-UA client (e.g. UaExpert, opcua-client, or
the Python `opcua` library):

```python
from opcua import Client
c = Client("opc.tcp://10.10.5.13:4840")
c.connect()
root = c.get_root_node()
print(root.get_children())
```

## Concrete attack paths

From the internet zone or from within the DMZ:

1. Connect anonymously: `opc.tcp://10.10.5.13:4840`
2. Browse the address space to identify pump state nodes and method nodes.
3. Read current pump status variables.
4. Call `stopPump()` to stop the simulated pump.

Using the Python `opcua` library:

```python
from opcua import Client
c = Client("opc.tcp://10.10.5.13:4840")
c.connect()
# Browse objects to find the pump node
objects = c.get_objects_node()
# Call stopPump method on the pump object — exact NodeId depends on the server tree
pump_node = objects.get_child(["..."])
pump_node.call_method("stopPump")
```

Alternatively, configure the umatiGateway at 10.10.5.10 to connect to this
server and relay its data to the DMZ MQTT broker. The umati web UI does not
require authentication.

## Before you dig in

The thin-edge demo server generates a self-signed certificate at startup for its
application instance certificate. Clients in `SecurityMode=None` do not validate
this certificate. Clients that attempt higher security modes may reject the
self-signed cert without a trust-list addition.

The available methods and their exact NodeIds depend on the server implementation.
Browse the address space before calling methods; the node tree is the
authoritative reference.

## The short version

OPC-UA demo server simulating an industrial pump. Anonymous authentication,
`SecurityMode=None`. Callable methods include `stopPump()`. Any OPC-UA client
with a route to port 4840 can stop the pump without credentials.
