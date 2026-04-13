WireGuard VPN client — UU P&L enterprise network
=================================================

To connect:
  wg-quick up ~/.vpn/uupl-vpn.conf

To disconnect:
  wg-quick down ~/.vpn/uupl-vpn.conf

Provides access to:
  10.10.1.0/24  enterprise zone (workstations, legacy systems)
  10.10.2.0/24  operational zone (historian, SCADA)

For access problems contact Ponder Stibbons: p.stibbons@uupl.ank
Do not install this config on shared or unmanaged devices.
