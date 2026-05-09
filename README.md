# wg-port-forward-duct-tape

A small Bash + Python helper for building a WireGuard-based TCP/UDP port relay.

It is designed for a topology where an IPv6-reachable entry node exposes public ports, forwards traffic through a WireGuard tunnel to a relay node, and the relay node provides IPv4 egress to reach one or more target services.

This project is intended for personal servers and small-scale deployments.

It is not designed as a production-grade proxy or SDWAN system.

## Features

- WireGuard tunnel setup between an entry node and a relay node
- IPv6 public listening on the entry node
- TCP and UDP forwarding support
- IPv4 target forwarding through the relay node
- DDNS target support
- Multiple target services
- Interactive setup mode
- Non-interactive setup mode
- Rollback support
- Compatibility aliases for older command names

## Topology

```text
Client
  |
  | Connect to entry.example.com:54677 over IPv6
  v
Entry Node
  |
  | WireGuard tunnel
  v
Relay Node
  |
  | IPv4 NAT egress
  v
Target Service
````

Example:

```text
Client
  |
  | entry.example.com:54677
  v
Entry Node
  |
  | wg-sdwan
  v
Relay Node
  |
  | IPv4 egress
  v
203.0.113.10:54677
```

## Requirements

Supported Linux distributions:

* Debian / Ubuntu
* Fedora
* CentOS / RHEL compatible distributions

Required packages are installed automatically when possible:

* `wireguard-tools`
* `iproute2` or `iproute`
* `iptables`
* `python3`

The script must be run as root.

## Installation

Download or copy the script to both the entry node and relay node:

```bash
wget -O wg-sdwan-port-relay.sh https://raw.githubusercontent.com/SPRMD/wg-port-forward-duct-tape/main/wg-sdwan-port-relay.sh && chmod +x wg-sdwan-port-relay.sh
```

## Roles

### Entry Node

The entry node:

* Has public IPv6 connectivity
* Listens on public TCP/UDP ports
* Forwards traffic through WireGuard
* Usually does not need public IPv4

### Relay Node

The relay node:

* Accepts WireGuard connections from the entry node
* Provides IPv4 egress
* Performs NAT for WireGuard traffic

### Target Service

The target service:

* Can be an IPv4 address or a DDNS hostname
* Can run any TCP/UDP service
* Is reached from the relay node's IPv4 egress path

## Quick Start

### 1. Generate WireGuard keys

Run this command on both the entry node and the relay node:

```bash
sudo bash /root/wg-sdwan-port-relay.sh keygen
```

Save the public key printed on each node.

You will need:

* Entry node public key
* Relay node public key

## 2. Initialize the Relay Node

On the relay node, run:

```bash
sudo bash /root/wg-sdwan-port-relay.sh init-relay
```

The script will ask for:

```text
WireGuard interface name [wg-sdwan]:
WireGuard UDP listen port [51820]:
Relay node WireGuard address CIDR [10.233.233.1/24]:
Entry node WireGuard IP without CIDR [10.233.233.2]:
WireGuard IPv4 subnet for NAT [10.233.233.0/24]:
Entry node WireGuard public key:
```

Make sure the relay node firewall allows inbound UDP traffic on the WireGuard port, for example:

```text
UDP 51820
```

## 3. Initialize the Entry Node

On the entry node, run:

```bash
sudo bash /root/wg-sdwan-port-relay.sh init-entry
```

The script will ask for:

```text
WireGuard interface name [wg-sdwan]:
Entry node WireGuard address CIDR [10.233.233.2/24]:
Relay node address or DDNS hostname:
Relay WireGuard UDP port [51820]:
Relay node WireGuard public key:
AllowedIPs, default is usually recommended [0.0.0.0/0]:
```

The relay address can be:

* A domain name
* A DDNS hostname
* An IPv6 address
* An IPv4 address, if reachable

Example relay hostname:

```text
sdwan.example.com
```

## 4. Add a Target

On the entry node, add a target service:

```bash
sudo bash /root/wg-sdwan-port-relay.sh add-target target1 203.0.113.10 54677 54677
```

This means:

```text
Entry listen port: [::]:54677
Target service:    203.0.113.10:54677
```

Clients can then connect to:

```text
entry.example.com:54677
```

The traffic will be forwarded through the WireGuard tunnel and egress from the relay node.

## DDNS Target Example

You can also use a DDNS hostname as the target:

```bash
sudo bash /root/wg-sdwan-port-relay.sh add-target target2 exit.example.com 54677 54678
```

This means:

```text
Entry listen port: [::]:54678
Target service:    exit.example.com:54677
```

The target hostname is resolved when new TCP or UDP sessions are created.

By default, the relay helper resolves IPv4 A records only. This prevents traffic from accidentally bypassing the relay node through IPv6 when the target hostname also has an AAAA record.

## Managing Targets

### List targets

```bash
sudo bash /root/wg-sdwan-port-relay.sh list-targets
```

### Delete a target

```bash
sudo bash /root/wg-sdwan-port-relay.sh del-target target1
```

### Show status

```bash
sudo bash /root/wg-sdwan-port-relay.sh status
```

This shows:

* WireGuard status
* Relay service status
* Current target list

## Non-interactive Usage

### Initialize Relay Node

```bash
sudo bash /root/wg-sdwan-port-relay.sh init-relay \
  --entry-pub <ENTRY_PUBLIC_KEY> \
  --listen-port 51820 \
  --wg-if wg-sdwan \
  --relay-wg-ip-cidr 10.233.233.1/24 \
  --entry-wg-ip 10.233.233.2 \
  --wg-net-v4 10.233.233.0/24
```

### Initialize Entry Node

```bash
sudo bash /root/wg-sdwan-port-relay.sh init-entry \
  --relay-host sdwan.example.com \
  --relay-pub <RELAY_PUBLIC_KEY> \
  --relay-port 51820 \
  --wg-if wg-sdwan \
  --entry-wg-ip-cidr 10.233.233.2/24 \
  --allowed-ips 0.0.0.0/0
```

### Add Target

```bash
sudo bash /root/wg-sdwan-port-relay.sh add-target target1 203.0.113.10 54677 54677
```

### Add DDNS Target

```bash
sudo bash /root/wg-sdwan-port-relay.sh add-target target2 exit.example.com 54677 54678
```

## Compatibility Aliases

The following aliases are supported:

```text
init-sdwan   -> init-relay
init-a       -> init-entry
add-exit     -> add-target
del-exit     -> del-target
list-exits   -> list-targets
```

For example, this still works:

```bash
sudo bash /root/wg-sdwan-port-relay.sh init-sdwan
```

And is equivalent to:

```bash
sudo bash /root/wg-sdwan-port-relay.sh init-relay
```

## Rollback

The script records backups before modifying files.

To rollback changes on the current machine:

```bash
sudo bash /root/wg-sdwan-port-relay.sh rollback
```

To skip the confirmation prompt:

```bash
sudo bash /root/wg-sdwan-port-relay.sh rollback --yes
```

For old installations without a rollback manifest:

```bash
sudo bash /root/wg-sdwan-port-relay.sh rollback --force-clean
```

If you used a custom WireGuard interface name:

```bash
sudo bash /root/wg-sdwan-port-relay.sh rollback --force-clean --wg-if wg-custom
```

If you used a custom WireGuard IPv4 subnet:

```bash
sudo bash /root/wg-sdwan-port-relay.sh rollback --force-clean --wg-net-v4 10.88.88.0/24
```

## Files Created

The script may create or modify the following paths:

```text
/etc/wg-sdwan-port-relay/
/etc/wg-sdwan-port-relay/keys/privatekey
/etc/wg-sdwan-port-relay/keys/publickey
/etc/wg-sdwan-port-relay/forwards.csv
/etc/wg-sdwan-port-relay/config.env
/etc/wireguard/<interface>.conf
/usr/local/bin/wg-sdwan-port-relay.py
/etc/systemd/system/wg-sdwan-port-relay.service
/var/lib/wg-sdwan-port-relay/
/var/backups/wg-sdwan-port-relay/
```

## Firewall Notes

On the relay node, allow the WireGuard UDP port:

```text
UDP 51820
```

On the entry node, allow the public target listen ports, for example:

```text
TCP 54677
UDP 54677
```

If you add another target using port `54678`, allow:

```text
TCP 54678
UDP 54678
```

## How DDNS Resolution Works

When a target is added with a hostname:

```bash
sudo bash /root/wg-sdwan-port-relay.sh add-target target2 exit.example.com 54677 54678
```

The hostname is resolved when a new TCP or UDP session is created.

The generated route is added like this:

```text
ip route replace <resolved-ip>/32 dev <wireguard-interface>
```

This ensures traffic to the resolved IPv4 target goes through the WireGuard tunnel.

## Security Notes

Do not commit runtime files or generated keys to Git.

Recommended `.gitignore`:

```gitignore
# Runtime configs and generated secrets
*.conf
*.key
privatekey
publickey
forwards.csv
config.env
manifest.tsv

# Runtime state
wg-sdwan-port-relay/
var/
backups/

# Logs
*.log
```

Before publishing, scan the repository for secrets:

```bash
grep -RInE 'PrivateKey|PublicKey|Endpoint|password|passwd|secret|token|key' .
```

Scan for IP addresses and hostnames:

```bash
grep -RInE '([a-zA-Z0-9-]+\.)+[a-zA-Z]{2,}|([0-9]{1,3}\.){3}[0-9]{1,3}' .
```

## Notes

* The script uses `iptables` for IPv4 NAT on the relay node.
* The NAT rule is tagged with the comment `wg-sdwan-port-relay`.
* Rollback removes only NAT rules created by this script when a rollback manifest exists.
* The script does not uninstall packages during rollback.
* The script is intended for servers and networks you own or are authorized to administer.

## License

MIT License

