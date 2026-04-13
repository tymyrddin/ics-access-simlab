 # What we are building toward

  Each device runs multiple real protocols simultaneously. An attacker enumerating the turbine PLC doesn't find a Python Modbus server — they find OPC-UA on 4840,
   IEC-104 on 2404, Modbus on 502, and MQTT publishing to a broker. Each protocol is a real implementation with real weak defaults, real CVEs in pinned versions,
  real authentication gaps.

  SCADA-LTS as the real HMI/SCADA layer. It is to speak Modbus RTU/TCP, OPC-UA, S7, BACnet, MQTT, Ethernet/IP. Replace the custom Flask SCADA and HMI containers
  with FUXA connected to the real protocol endpoints below it. Real process visualization, real operator screen, real session handling to attack.

  Mosquitto as the MQTT fabric. Devices publish sensor readings to topics (uupl/turbine/rpm, uupl/relay_a/trip). Mosquitto with no auth (default) means an
  attacker who reaches the control zone can subscribe to all telemetry passively, then inject false readings by publishing. This is a real ICS attack pattern
  (MQTT topic spoofing).

  IEC-104 simulator on the PLC and IEDs. The RichyP7 simulator has configurable datapoints, predefined profiles for realistic measurement curves, and no
  authentication ("not started"). Drop it alongside the Modbus stack on turbine_plc and ied_relay containers — now DNP3, IEC-104, and Modbus all answer on the
  same simulated device.

  OPC-UA (thin-edge) for the engineering layer. The pump simulation with filter degradation, auto-reset, and methods (startPump, stopPump, resetFilter) maps
  directly onto the turbine. No auth on port 4840. An attacker with OPC-UA tools (like python-opcua) can browse the node tree, read live physics values, and call
  methods directly.

  iotechsys/modbus-sim fills the gap where you want a Modbus device that's purely a register/coil map — actuators, meter — without running physics logic.

  ---
  How the device inventory changes

  ┌───────────────┬──────────────────────────────────────┬────────────────────────────────────────────────────────────────────────────────────────────────────┐
  │   Container   │                 Now                  │                                              Expanded                                              │
  ├───────────────┼──────────────────────────────────────┼────────────────────────────────────────────────────────────────────────────────────────────────────┤
  │ turbine_plc   │ Custom Python: Modbus + DNP3 +       │ + OPC-UA (thin-edge) + MQTT publish (Mosquitto client) + IEC-104 (RichyP7 sidecar or integrated)   │
  │               │ IEC-104                              │                                                                                                    │
  ├───────────────┼──────────────────────────────────────┼────────────────────────────────────────────────────────────────────────────────────────────────────┤
  │ hmi_main      │ Custom Flask                         │ → FUXA: connects to PLC via Modbus + OPC-UA, operator screen, real session auth to attack          │
  ├───────────────┼──────────────────────────────────────┼────────────────────────────────────────────────────────────────────────────────────────────────────┤
  │ ied_relay_a/b │ Custom Python: Modbus + HTTP         │ + IEC-104 datapoints + MQTT trip events                                                            │
  ├───────────────┼──────────────────────────────────────┼────────────────────────────────────────────────────────────────────────────────────────────────────┤
  │ scada-server  │ Custom Flask proxy                   │ → FUXA second instance or keep as thin credential store (its SQLi/credential-dump vulns are the    │
  │               │                                      │ point)                                                                                             │
  ├───────────────┼──────────────────────────────────────┼────────────────────────────────────────────────────────────────────────────────────────────────────┤
  │ actuators     │ Custom Python Modbus                 │ → iotechsys/modbus-sim with pinned register maps                                                   │
  ├───────────────┼──────────────────────────────────────┼────────────────────────────────────────────────────────────────────────────────────────────────────┤   
  │ historian     │ SQLite Flask                         │ Keep (SQLi is the designed vuln) OR augment with real TSDB underneath                              │
  ├───────────────┼──────────────────────────────────────┼────────────────────────────────────────────────────────────────────────────────────────────────────┤   
  │ (new)         │ —                                    │ Mosquitto broker at 10.10.3.60, unauthenticated, publishes all telemetry                           │
  └───────────────┴──────────────────────────────────────┴────────────────────────────────────────────────────────────────────────────────────────────────────┘   
                  
  ---                                                                                                                                                             
  What this means for the architecture
                                      
  The zones/control/ container library grows: each device gets a docker-compose.yml fragment that composes the physics engine (your Python, which owns ground
  truth) with real protocol frontends that serve its register state. The physics engine writes to shared memory or a local socket; the protocol servers read from 
  it.
                                                                                                                                                                  
  The orchestrator (ctf-config.yaml) stays the same shape — it controls what gets deployed, not how vulnerable things are. A challenge config activates FUXA +    
  Mosquitto + IEC-104; another activates only Modbus + OPC-UA. Depth is always there; exposure is configured.

 And these ready dockers allow for creating vulnerabilities?                                                                                                     
                                                              
● Yes — in three distinct ways, each more realistic than a custom container:                                                                                      
                                                                                                                                                                
  ---                                                                                                                                                             
  1. Protocol-inherent (no work needed)
                                                                                                                                                                  
  Some of these protocols have no authentication by design. That's not a misconfiguration — it's the protocol.
                                                                                                                                                                  
  ┌──────────────────────┬──────────────────────────────┬─────────────────────────────────────────────────────────────────────────┐
  │        Image         │           Protocol           │                              Vulnerability                              │                               
  ├──────────────────────┼──────────────────────────────┼─────────────────────────────────────────────────────────────────────────┤                               
  │ iotechsys/modbus-sim │ Modbus TCP                   │ No auth, any host reads/writes all registers — inherent to the protocol │
  ├──────────────────────┼──────────────────────────────┼─────────────────────────────────────────────────────────────────────────┤                               
  │ RichyP7 IEC-104      │ IEC 60870-5-104              │ Auth explicitly "not started", any client sends APDU commands           │                               
  ├──────────────────────┼──────────────────────────────┼─────────────────────────────────────────────────────────────────────────┤                               
  │ thin-edge OPC-UA     │ OPC-UA (Security Mode: None) │ Unauthenticated node browse, read, and method calls                     │                               
  └──────────────────────┴──────────────────────────────┴─────────────────────────────────────────────────────────────────────────┘                               
                  
  You configure the security mode in OPC-UA and it exposes everything. That's a real-world misconfiguration attackers find constantly in substations.             
                  
  ---                                                                                                                                                             
  2. Configurable weak defaults
                               
  ┌──────────────────┬────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┐
  │      Image       │                                                       How to make it vulnerable                                                        │   
  ├──────────────────┼────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
  │ Eclipse          │ allow_anonymous true in mosquitto.conf (was default before 2.0); mount a config with no ACLs — any client subscribes/publishes to any  │   
  │ Mosquitto        │ topic                                                                                                                                  │
  ├──────────────────┼────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤   
  │ FUXA             │ Set admin password to admin or fuxa on first-run setup; or disable authentication via config                                           │
  ├──────────────────┼────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤   
  │ thin-edge OPC-UA │ Leave OPCUA_SECURITY_MODE=None — exposed by default                                                                                    │
  └──────────────────┴────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘   
                  
  These are realistic misconfigurations — exactly what an ICS engineer who "just needed it working" would do.                                                     
                  
  ---                                                                                                                                                             
  3. Real CVEs in pinned versions
                                                                                                                                                                  
  FUXA has documented CVEs you can pin deliberately:
                                                                                                                                                                  
  - CVE-2023-32545 — path traversal in the file upload endpoint                                                                                                   
  - CVE-2023-32546 — stored XSS in device/tag names
  - CVE-2023-32547 — unauthenticated access to project files                                                                                                      
                  
  Pin frangoteam/fuxa:1.1.7 (or whichever version carries the CVE you want) and the vulnerability is real, not simulated. An attacker using a real exploit against
   it will succeed.
                                                                                                                                                                  
  This is the key advantage over custom Flask containers: the SQLi in your historian is designed and known. A CVE in a pinned FUXA version is undocumented to the 
  participant — they have to identify the software, find the version, research the CVE, and exploit it.
                                                                                                                                                                  
  ---             
  What you can't do
                                                                                                                                                                  
  You can't inject an arbitrary vulnerability (like your historian's specific SQLi) into FUXA's code without forking and modifying it. So the split stays:
                                                                                                                                                                  
  - Custom containers (historian, legacy workstation, scada credential store): designed vulnerabilities you control precisely                                     
  - Real image containers (FUXA, Mosquitto, OPC-UA, IEC-104, Modbus): protocol-inherent auth gaps + real CVEs in pinned versions + misconfiguration               
                                                                                                                                                                  
  Both belong in the lab. They model two different real-world failure modes.     