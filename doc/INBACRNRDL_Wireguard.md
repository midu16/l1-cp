# VXLAN over WireGuard Tunnel Configuration

## Overview

This document describes a VXLAN-over-WireGuard architecture that extends IP connectivity
between two physically separated hosts over an encrypted WireGuard tunnel. The design uses
**routed VXLAN** — the VXLAN interface is kept on a standalone transit network, separate from
the VM bridge — so that the VXLAN's lower MTU does not drag down local VM-to-VM traffic.

Cross-hypervisor traffic is forwarded via L3 routing with proxy ARP, while local VM traffic
stays on the full-MTU bridge.

### Architecture Diagram

```
 INBACRNRDL0102 (192.168.18.53)                    INBACRNRDL0103 (192.168.18.54)
 ┌────────────────────────────────┐                ┌────────────────────────────────┐
 │                                │                │                                │
 │  br0  (172.16.30.1/24)        │                │  br0  (172.16.30.2/24)        │
 │  MTU 1500 │ proxy_arp=1       │                │  MTU 1500 │ proxy_arp=1       │
 │  ┌──────┬──────┬──────┐       │                │  ┌──────┬──────┐              │
 │  │vnet  │vnet  │vnet  │       │                │  │vnet  │vnet  │              │
 │  │421   │422   │423   │       │                │  │(w0)  │(w1)  │              │
 │  │MTU   │MTU   │MTU   │       │                │  │MTU   │MTU   │              │
 │  │1500  │1500  │1500  │       │                │  │1500  │1500  │              │
 │  └──────┴──────┴──────┘       │                │  └──────┴──────┘              │
 │           │                   │                │           │                   │
 │     ┌─────┘    routing        │                │     ┌─────┘    routing        │
 │     │    ┌───────────┐        │                │     │    ┌───────────┐        │
 │     │    │  /32 host │        │                │     │    │  /32 host │        │
 │     │    │  routes   │        │                │     │    │  routes   │        │
 │     │    └─────┬─────┘        │                │     │    └─────┬─────┘        │
 │     │          │              │                │     │          │              │
 │  to-node2 (standalone)       │                │  to-node1 (standalone)       │
 │  10.0.0.1/30  MTU 1370       │                │  10.0.0.2/30  MTU 1370       │
 │  ┌────────────────────┐       │                │  ┌────────────────────┐       │
 │  │  VXLAN ID=1        │       │                │  │  VXLAN ID=1        │       │
 │  │  remote=172.16.0.2 │       │                │  │  remote=172.16.0.1 │       │
 │  └─────────┬──────────┘       │                │  └─────────┬──────────┘       │
 │            │                  │                │            │                  │
 │  wg0 (172.16.0.1/16)         │                │  wg0 (172.16.0.2/16)         │
 │  ┌─────────────────┐         │                │  ┌─────────────────┐         │
 │  │   WireGuard      │         │                │  │   WireGuard      │         │
 │  │   MTU 1420       │         │                │  │   MTU 1420       │         │
 │  │   Port 51820     │         │                │  │   Port 51820     │         │
 │  └────────┬────────┘         │                │  └────────┬────────┘         │
 │           │                  │                │           │                  │
 │  ens10f0 (192.168.18.53)     │                │  ens10f0 (192.168.18.54)     │
 │  MTU 1500                    │                │  MTU 1500                    │
 └───────────┬──────────────────┘                └───────────┬──────────────────┘
             │          Physical Network (192.168.18.0/24)   │
             └───────────────────────────────────────────────┘
```

### Current Network Topology — VMs, Services, and Traffic Flows

The diagram below shows every VM, container service, interface, and IP address as currently
deployed, and illustrates how traffic flows between VMs on different hypervisors.

```
  INBACRNRDL0102 (192.168.18.53)                          INBACRNRDL0103 (192.168.18.54)
 ┌──────────────────────────────────────────┐             ┌──────────────────────────────────────────┐
 │                                          │             │                                          │
 │  ┌─────────────┐ ┌─Podman containers──┐ │             │                                          │
 │  │ hub-ctlplane │ │ ┌───────────────┐  │ │             │  ┌──────────────┐  ┌──────────────┐      │
 │  │     -0       │ │ │    Gitea       │  │ │             │  │ hub-worker-0 │  │ hub-worker-1 │      │
 │  │ 172.16.30.20 │ │ │  :3000/tcp     │  │ │             │  │ 172.16.30.23 │  │ 172.16.30.24 │      │
 │  │ enp3s0  1500 │ │ └───────────────┘  │ │             │  │ enp3s0  1500 │  │ enp3s0  1500 │      │
 │  └──────┬───────┘ │ ┌───────────────┐  │ │             │  └──────┬───────┘  └──────┬───────┘      │
 │  ┌──────┴───────┐ │ │   Registry    │  │ │             │         │                 │              │
 │  │ hub-ctlplane │ │ │  :5000/tcp     │  │ │             │  ┌──────┴──────┐   ┌──────┴──────┐      │
 │  │     -1       │ │ └───────────────┘  │ │             │  │   vnet(w0)   │   │   vnet(w1)  │      │
 │  │ 172.16.30.21 │ │       │ podman0    │ │             │  │   MTU 1500   │   │   MTU 1500  │      │
 │  │ enp3s0  1500 │ └───────┼────────────┘ │             │  └──────┬───────┘   └──────┬──────┘      │
 │  └──────┬───────┘         │              │             │         │                  │             │
 │  ┌──────┴───────┐         │              │             │         │                  │             │
 │  │ hub-ctlplane │         │              │             │  ┌──────┴──────────────────┴──────┐      │
 │  │     -2       │         │              │             │  │  br0  (172.16.30.2/24)         │      │
 │  │ 172.16.30.22 │         │              │             │  │  MTU 1500  │  proxy_arp = 1    │      │
 │  │ enp3s0  1500 │         │              │             │  └─────────────────┬──────────────┘      │
 │  └──────┬───────┘         │              │             │                    │                     │
 │         │                 │              │             │              L3 routing                  │
 │  ┌──────┴─────┐  ┌───────┴──────┐       │             │        ┌───────────┴───────────┐         │
 │  │  vnet421   │  │  vnet422     │       │             │        │  /32 host routes:     │         │
 │  │  vnet422   │  │  vnet423     │       │             │        │  .1  → 10.0.0.1       │         │
 │  │  vnet423   │  │  MTU 1500    │       │             │        │  .10 → 10.0.0.1 (API) │         │
 │  │  MTU 1500  │  └──────────────┘       │             │        │  .20 → 10.0.0.1       │         │
 │  └──────┬─────┘                         │             │        │  .21 → 10.0.0.1       │         │
 │         │                               │             │        │  .22 → 10.0.0.1       │         │
 │  ┌──────┴───────────────────────┐       │             │        └───────────┬───────────┘         │
 │  │  br0  (172.16.30.1/24)      │       │             │                    │                     │
 │  │  MTU 1500  │ proxy_arp = 1  │       │             │                    │                     │
 │  └──────────────────┬───────────┘       │             │                    │                     │
 │                     │                   │             │                    │                     │
 │               L3 routing                │             │  ┌────────────────┴─────────────────┐    │
 │         ┌───────────┴──────────┐        │             │  │  to-node1 (standalone)           │    │
 │         │  /32 host routes:    │        │             │  │  10.0.0.2/30      MTU 1370       │    │
 │         │  .2  → 10.0.0.2     │        │             │  │  VXLAN ID=1  remote=172.16.0.1   │    │
 │         │  .11 → 10.0.0.2(Ing)│        │             │  └────────────────┬──────────────────┘    │
 │         │  .23 → 10.0.0.2     │        │             │                   │                      │
 │         │  .24 → 10.0.0.2     │        │             │                   │                      │
 │         └───────────┬──────────┘        │             │                   │                      │
 │                     │                   │             │  ┌────────────────┴──────────────────┐    │
 │  ┌──────────────────┴───────────────┐   │             │  │  wg0  (172.16.0.2/16)  MTU 1420  │    │
 │  │  to-node2 (standalone)           │   │             │  │  WireGuard  Port 51820           │    │
 │  │  10.0.0.1/30      MTU 1370      │   │             │  └────────────────┬──────────────────┘    │
 │  │  VXLAN ID=1  remote=172.16.0.2  │   │             │                   │                      │
 │  └──────────────────┬───────────────┘   │             │  ┌────────────────┴──────────────────┐    │
 │                     │                   │             │  │  ens10f0  (192.168.18.54)         │    │
 │  ┌──────────────────┴───────────────┐   │             │  │  MTU 1500                        │    │
 │  │  wg0  (172.16.0.1/16)  MTU 1420 │   │             │  └────────────────┬──────────────────┘    │
 │  │  WireGuard  Port 51820          │   │             │                   │                      │
 │  └──────────────────┬───────────────┘   │             └───────────────────┼──────────────────────┘
 │                     │                   │                                 │
 │  ┌──────────────────┴───────────────┐   │                                 │
 │  │  ens10f0  (192.168.18.53)        │   │                                 │
 │  │  MTU 1500                        │   │                                 │
 │  └──────────────────┬───────────────┘   │                                 │
 │                     │                   │                                 │
 └─────────────────────┼───────────────────┘                                 │
                       │                                                     │
                       │       Physical Network  (192.168.18.0/24)           │
                       └─────────────────────────────────────────────────────┘
```

#### Cross-Hypervisor Traffic Flow: worker-0 (.23) → ctlplane-0 (.20)

The following shows the step-by-step path when `hub-worker-0` (172.16.30.23) on INBACRNRDL0103
sends a packet to `hub-ctlplane-0` (172.16.30.20) on INBACRNRDL0102:

```
 hub-worker-0                                                    hub-ctlplane-0
 172.16.30.23                                                    172.16.30.20
 (INBACRNRDL0103)                                                (INBACRNRDL0102)
      │                                                               ▲
      │ ① ARP: "who has .20?"                                        │
      │    proxy_arp on br0 →                                        │
      │    host replies with br0 MAC                                 │
      │                                                               │
      ▼                                                               │
 ┌─────────┐  ② Packet sent to br0 MAC                          ┌────┴────┐
 │  br0    ├──────────────────────┐                              │  br0    │
 │  (.2)   │                      │                              │  (.1)   │
 └─────────┘                      │                              └────▲────┘
                                  │                                   │
                           ③ Kernel routing:                    ⑧ br0 delivers
                              .20 matches /32                     to vnet421
                              → via 10.0.0.1                      (MAC lookup)
                              → dev to-node1                          │
                                  │                                   │
                                  │  ┌─iptables mangle──────┐        │
                                  ├──┤ TCPMSS --clamp-mss   │        │
                                  │  │ (SYN only)           │        │
                                  │  └──────────────────────┘        │
                                  ▼                                   │
                           ┌────────────┐                      ┌─────┴──────┐
                           │  to-node1  │                      │  to-node2  │
                           │ 10.0.0.2   │                      │ 10.0.0.1   │
                           │ MTU 1370   │                      │ MTU 1370   │
                           └─────┬──────┘                      └─────▲──────┘
                                 │                                   │
                           ④ VXLAN encapsulates:               ⑦ VXLAN decapsulates:
                              outer dst=172.16.0.1                extracts original
                              VNI=1, UDP 4789                     Ethernet frame
                                 │                                   │
                                 ▼                                   │
                           ┌───────────┐                       ┌─────┴─────┐
                           │   wg0     │                       │    wg0    │
                           │ .0.2/16   │                       │  .0.1/16  │
                           │ MTU 1420  │                       │  MTU 1420 │
                           └─────┬─────┘                       └─────▲─────┘
                                 │                                   │
                           ⑤ WireGuard encrypts                ⑥ WireGuard decrypts
                              outer: .53 ← .54                    outer: .53 ← .54
                              UDP 51820                            UDP 51820
                                 │                                   │
                                 ▼                                   │
                           ┌───────────┐                       ┌─────┴─────┐
                           │ ens10f0   │                       │  ens10f0  │
                           │   .54     │                       │    .53    │
                           └─────┬─────┘                       └─────▲─────┘
                                 │    Physical Network               │
                                 └───────────────────────────────────┘
```

#### Local Traffic Flow: ctlplane-1 (.21) → ctlplane-0 (.20)

Local VM-to-VM traffic on the same hypervisor stays entirely within `br0` at full MTU 1500.
The VXLAN tunnel is never involved:

```
 hub-ctlplane-1               hub-ctlplane-0
 172.16.30.21                 172.16.30.20
      │                            ▲
      │ ARP: "who has .20?"        │
      │ .20 is on same br0 →      │
      │ direct L2 response         │
      │                            │
      ▼                            │
 ┌─────────┐  L2 switch      ┌────┴────┐
 │ vnet422 ├─────────────────►│ vnet421 │
 │ MTU 1500│    br0 forwards  │ MTU 1500│
 └─────────┘    at MTU 1500   └─────────┘
                (no VXLAN,
                 no routing,
                 no MSS clamp)
```

### Key Design Principle: Decoupled VXLAN

In the **original (bridged) design**, the VXLAN interface was a member of `br0` alongside the
VM `vnetX` interfaces. This is simple but has a critical flaw: Linux bridges inherit the
**minimum MTU** of all members. With the VXLAN at MTU 1370 inside br0, the bridge MTU drops
to 1370, which cascades to all VM host-side interfaces (`vnetX`) — clamping local VM traffic
to 1370 even though those VMs communicate entirely within the same host and never traverse the
VXLAN tunnel.

The **decoupled (routed) design** separates them:

| Aspect | Bridged (old) | Routed (current) |
|--------|--------------|-------------------|
| VXLAN membership | Bridge slave of `br0` | Standalone interface |
| br0 MTU | 1370 (clamped by VXLAN) | 1500 (full speed) |
| Local VM-to-VM | 1370 byte limit | 1500 byte limit |
| Cross-hypervisor | L2 bridged | L3 routed via /32 host routes |
| ARP resolution | Native broadcast | Proxy ARP on br0 |
| TCP large-segment safety | Implicit (low MTU) | Explicit MSS clamping via iptables |

### Packet Encapsulation Stack

When a VM on INBACRNRDL0102 sends traffic to a VM on INBACRNRDL0103, the packet traverses:

```
┌─────────────────────────────────────────────────────────────┐
│ Physical Ethernet Frame (ens10f0, MTU 1500)                 │
│ ┌─────────────────────────────────────────────────────────┐ │
│ │ Outer IP (192.168.18.53 → 192.168.18.54) + UDP 51820   │ │
│ │ ┌─────────────────────────────────────────────────────┐ │ │
│ │ │ WireGuard Encrypted Payload (MTU 1420)              │ │ │
│ │ │ ┌───────────────────────────────────────────────┐   │ │ │
│ │ │ │ Inner IP (172.16.0.1 → 172.16.0.2) + UDP 4789│   │ │ │
│ │ │ │ ┌───────────────────────────────────────────┐ │   │ │ │
│ │ │ │ │ VXLAN Header (8 bytes, VNI=1)             │ │   │ │ │
│ │ │ │ │ ┌───────────────────────────────────────┐ │ │   │ │ │
│ │ │ │ │ │ Original Ethernet Frame (VM traffic)  │ │ │   │ │ │
│ │ │ │ │ │ Max payload = 1370 bytes               │ │ │   │ │ │
│ │ │ │ │ └───────────────────────────────────────┘ │ │   │ │ │
│ │ │ │ └───────────────────────────────────────────┘ │   │ │ │
│ │ │ └───────────────────────────────────────────────┘   │ │ │
│ │ └─────────────────────────────────────────────────────┘ │ │
│ └─────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────┘
```

### MTU Calculation

This is the critical piece. The overhead from each layer must be subtracted:

| Layer | Overhead (bytes) | Description |
|-------|-----------------|-------------|
| WireGuard | ~60-80 | Encryption headers + UDP + outer IP. Results in `wg0` MTU = 1420 |
| Outer IP header | 20 | IP header for VXLAN outer packet (172.16.0.x → 172.16.0.x) |
| UDP header | 8 | UDP encapsulation for VXLAN (dst port 4789) |
| VXLAN header | 8 | 8-byte VXLAN header including VNI |
| Inner Ethernet | 14 | MAC header of the encapsulated frame |
| **Total VXLAN overhead** | **50** | IP + UDP + VXLAN + inner Ethernet |

**Correct VXLAN MTU** = WireGuard MTU - VXLAN overhead (excluding inner Ethernet, since MTU is an IP-level concept):

```
VXLAN interface MTU = 1420 - 20 (outer IP) - 8 (UDP) - 8 (VXLAN) - 14 (inner Ethernet) = 1370
```

> **Important**: If the VXLAN interface MTU is set higher than 1370 (e.g., left at the default
> 1500), TCP segments that exceed the effective path MTU will be silently dropped. Small packets
> (DNS, TCP handshakes, HTTP headers) will work, but large data transfers will hang indefinitely.
> This is known as a **PMTUD black hole** and is extremely difficult to diagnose because
> connectivity _appears_ to work for small requests.

---

## Step-by-Step Configuration Guide

### Prerequisites

- Two (or more) Linux hosts with network connectivity between them (e.g., 192.168.18.0/24)
- `wireguard-tools` package installed on all hosts
- Kernel support for WireGuard (Linux 5.6+ has built-in support; older kernels need the `wireguard` DKMS module)
- Root access on all hosts

### Step 1: Generate WireGuard Key Pairs

On **each host**, generate a private/public key pair:

```bash
wg genkey | tee /etc/wireguard/privatekey | wg pubkey > /etc/wireguard/pubkey
chmod 600 /etc/wireguard/privatekey
```

**INBACRNRDL0102 results:**

```
# cat /etc/wireguard/pubkey
4K9Vfw71Co4ctfGe7D0M1gZolifEmjmAgX/FA8QXNwQ=
```

**INBACRNRDL0103 results:**

```
# cat /etc/wireguard/pubkey
XVljtBChNWrHTF/UJKQZumZX3fTNiGrpPl9BEJ6KjQE=
```

### Step 2: Create WireGuard Configuration

Each host needs a `/etc/wireguard/wg0.conf` containing its own private key, the tunnel IP address,
and the peer's public key and endpoint.

**INBACRNRDL0102** (`/etc/wireguard/wg0.conf`):

```ini
[Interface]
PrivateKey = <INBACRNRDL0102_PRIVATE_KEY>
Address = 172.16.0.1/16
ListenPort = 51820
PostUp   = iptables -A FORWARD -i %i -j ACCEPT; iptables -A FORWARD -o %i -j ACCEPT; iptables -t nat -A POSTROUTING -o ens10f0 -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -D FORWARD -o %i -j ACCEPT; iptables -t nat -D POSTROUTING -o ens10f0 -j MASQUERADE

[Peer]
PublicKey = XVljtBChNWrHTF/UJKQZumZX3fTNiGrpPl9BEJ6KjQE=
Endpoint = 192.168.18.54:51820
AllowedIPs = 172.16.0.0/16
PersistentKeepalive = 25
```

**INBACRNRDL0103** (`/etc/wireguard/wg0.conf`):

```ini
[Interface]
PrivateKey = <INBACRNRDL0103_PRIVATE_KEY>
Address = 172.16.0.2/16
ListenPort = 51820
PostUp   = iptables -A FORWARD -i %i -j ACCEPT; iptables -A FORWARD -o %i -j ACCEPT; iptables -t nat -A POSTROUTING -o ens10f0 -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -D FORWARD -o %i -j ACCEPT; iptables -t nat -D POSTROUTING -o ens10f0 -j MASQUERADE

[Peer]
PublicKey = 4K9Vfw71Co4ctfGe7D0M1gZolifEmjmAgX/FA8QXNwQ=
Endpoint = 192.168.18.53:51820
AllowedIPs = 172.16.0.0/16
PersistentKeepalive = 25
```

**Key configuration details:**

| Parameter | Purpose |
|-----------|---------|
| `Address = 172.16.0.x/16` | Assigns the WireGuard tunnel IP. The /16 mask allows the entire 172.16.0.0/16 range to be routed through the tunnel |
| `AllowedIPs = 172.16.0.0/16` | Tells WireGuard which destination IPs should be sent through this peer. Also acts as a routing directive — the kernel creates a route for this prefix via `wg0` |
| `Endpoint` | The physical IP and port of the remote peer. WireGuard sends encrypted UDP packets to this address |
| `PersistentKeepalive = 25` | Sends a keepalive packet every 25 seconds to maintain NAT mappings and detect peer loss |
| `PostUp` iptables rules | Enable forwarding through the WireGuard interface and MASQUERADE outbound traffic. Required for traffic that transits the host (e.g., VXLAN encapsulated packets) |

### Step 3: Enable and Start WireGuard

```bash
sysctl -w net.ipv4.ip_forward=1
echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.d/99-wireguard.conf

wg-quick up wg0

systemctl enable wg-quick@wg0
```

**Verification on INBACRNRDL0102:**

```
# wg show wg0
interface: wg0
  public key: 4K9Vfw71Co4ctfGe7D0M1gZolifEmjmAgX/FA8QXNwQ=
  private key: (hidden)
  listening port: 51820

peer: XVljtBChNWrHTF/UJKQZumZX3fTNiGrpPl9BEJ6KjQE=
  endpoint: 192.168.18.54:51820
  allowed ips: 172.16.0.0/16
  latest handshake: 25 seconds ago
  transfer: 6.23 TiB received, 364.76 GiB sent
  persistent keepalive: every 25 seconds
```

```
# ip -d link show wg0
9: wg0: <POINTOPOINT,NOARP,UP,LOWER_UP> mtu 1420 qdisc noqueue state UNKNOWN
    link/none  promiscuity 0
    wireguard
```

**Test tunnel connectivity:**

```bash
# From INBACRNRDL0102
ping -c 3 172.16.0.2

# From INBACRNRDL0103
ping -c 3 172.16.0.1
```

### Step 4: Create VXLAN Interfaces via NetworkManager (Standalone — Not Bridged)

In the decoupled design, the VXLAN interface is **not** a bridge slave. It gets its own IP
address on a transit subnet (`10.0.0.0/30`) and acts as a routed point-to-point link between
the two hypervisors.

**On INBACRNRDL0102** — create `to-node2` with transit IP `10.0.0.1/30` and static /32 routes
for all IPs hosted on the remote hypervisor:

```bash
nmcli con add type vxlan \
    con-name to-node2 \
    ifname to-node2 \
    vxlan.id 1 \
    vxlan.remote 172.16.0.2 \
    vxlan.destination-port 4789 \
    ethernet.mtu 1370 \
    ipv4.method manual \
    ipv4.addresses 10.0.0.1/30 \
    ipv4.routes "172.16.30.2/32 10.0.0.2, 172.16.30.11/32 10.0.0.2, 172.16.30.23/32 10.0.0.2, 172.16.30.24/32 10.0.0.2" \
    connection.autoconnect yes
```

> **Note — Ingress VIP route (.11):** The OpenShift Ingress VIP (172.16.30.11) floats via
> keepalived and can land on any node, including workers on INBACRNRDL0103. A /32 route is
> added here so that proxy ARP on `br0` can answer ARP requests from local control-plane VMs
> when the VIP is on a remote worker. The route is intentionally **not** present on
> INBACRNRDL0103 to avoid a routing loop — see [Floating VIP Routing](#floating-vip-routing)
> below.

**On INBACRNRDL0103** — create `to-node1` with transit IP `10.0.0.2/30` and static /32 routes
for all IPs hosted on the remote hypervisor (control planes, API VIP, infra gateway):

```bash
nmcli con add type vxlan \
    con-name to-node1 \
    ifname to-node1 \
    vxlan.id 1 \
    vxlan.remote 172.16.0.1 \
    vxlan.destination-port 4789 \
    ethernet.mtu 1370 \
    ipv4.method manual \
    ipv4.addresses 10.0.0.2/30 \
    ipv4.routes "172.16.30.1/32 10.0.0.1, 172.16.30.10/32 10.0.0.1, 172.16.30.20/32 10.0.0.1, 172.16.30.21/32 10.0.0.1, 172.16.30.22/32 10.0.0.1" \
    connection.autoconnect yes
```

**Key VXLAN parameters:**

| Parameter | Value | Purpose |
|-----------|-------|---------|
| `vxlan.id 1` | VNI (VXLAN Network Identifier) | Identifies the virtual L2 segment. Both ends must match |
| `vxlan.remote` | WireGuard IP of peer | Unicast remote endpoint. VXLAN packets are sent to this IP, which routes through `wg0` |
| `vxlan.destination-port 4789` | IANA standard VXLAN port | The UDP destination port for VXLAN encapsulation |
| `ethernet.mtu 1370` | VXLAN MTU | Accounts for WireGuard + VXLAN encapsulation overhead |
| `ipv4.addresses 10.0.0.x/30` | Transit subnet | Point-to-point IP for routing between hypervisors |
| `ipv4.routes` | /32 host routes | Steers remote VM traffic into the VXLAN tunnel |

**Why /32 routes?** Both hypervisors have `172.16.30.0/24` on `br0`. The /32 routes are more
specific than the /24 connected route, so the kernel uses longest-prefix-match to send traffic
for known remote VMs through the VXLAN tunnel, while all other `172.16.30.0/24` traffic stays
on the local bridge.

**Verification on INBACRNRDL0102:**

```
# ip addr show to-node2
737: to-node2: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1370 qdisc noqueue state UNKNOWN
    link/ether 26:02:92:27:d7:13 brd ff:ff:ff:ff:ff:ff
    inet 10.0.0.1/30 brd 10.0.0.3 scope global noprefixroute to-node2
```

**Verification on INBACRNRDL0103:**

```
# ip addr show to-node1
327: to-node1: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1370 qdisc noqueue state UNKNOWN
    link/ether c6:41:6b:93:b8:3e brd ff:ff:ff:ff:ff:ff
    inet 10.0.0.2/30 brd 10.0.0.3 scope global noprefixroute to-node1
```

### Step 5: Configure the VM Bridge (br0) at Full MTU

The bridge carries only local VM interfaces. Without the VXLAN member, br0 stays at MTU 1500.

**On INBACRNRDL0102:**

```bash
nmcli con modify br0 802-3-ethernet.mtu 1500
nmcli con up br0
```

**On INBACRNRDL0103:**

```bash
nmcli con modify br0 802-3-ethernet.mtu 1500
nmcli con up br0
```

**Verification — bridge members on INBACRNRDL0102 (no VXLAN member):**

```
# bridge link show
733: vnet421: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 master br0 state forwarding
734: vnet422: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 master br0 state forwarding
735: vnet423: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 master br0 state forwarding
```

> **Note**: The `vnetX` interfaces (libvirt VM NICs) are at MTU 1500 because they no longer share
> a bridge with the MTU-1370 VXLAN. Local VM-to-VM traffic can use full 1500-byte frames.
> Libvirt automatically re-attaches VM interfaces to br0 when VMs are started after a reboot.

### Step 6: Define br0 as a Libvirt Network

The `br0` bridge is managed by NetworkManager, but libvirt (and tools like `kcli` that use it)
require a **libvirt network** definition to reference it in VM domain XML. Without this, VM
creation fails with `Invalid network br0`.

The libvirt network uses `forward mode="bridge"` which is a transparent passthrough — no NAT,
no DHCP, no iptables rules. It simply tells libvirt "this network maps to the existing system
bridge named `br0`."

**On both INBACRNRDL0102 and INBACRNRDL0103:**

```bash
cat <<EOF | virsh net-define /dev/stdin
<network>
  <name>br0</name>
  <forward mode="bridge"/>
  <bridge name="br0"/>
</network>
EOF

virsh net-start br0
virsh net-autostart br0
```

**Verification:**

```
# virsh net-info br0
Name:           br0
UUID:           53e89f0a-f197-49d1-9991-05b9288c3ce6
Active:         yes
Persistent:     yes
Autostart:      yes
Bridge:         br0
```

VMs can now be created with `br0` as their network, e.g. via kcli:

```bash
kcli create vm ... -P nets="[{'name': 'br0', 'mac': '$MAC'}]"
```

Or in libvirt domain XML:

```xml
<interface type='network'>
  <source network='br0'/>
  <model type='virtio'/>
</interface>
```

### Step 7: Enable Proxy ARP

With the VXLAN decoupled from br0, VMs on one hypervisor can no longer discover remote VMs via
L2 broadcast (ARP). Proxy ARP makes the hypervisor answer ARP requests on behalf of remote VMs,
so local VMs believe the remote IPs are reachable at L2 (via the hypervisor's MAC).

**On both hosts:**

```bash
sysctl -w net.ipv4.conf.br0.proxy_arp=1

# Persist across reboots
echo "net.ipv4.conf.br0.proxy_arp = 1" > /etc/sysctl.d/99-proxy-arp.conf
```

**How it works:**

1. VM `ctlplane-1` (172.16.30.21 on INBACRNRDL0102) sends ARP "who has 172.16.30.23?"
2. The hypervisor has a /32 route for 172.16.30.23 via `to-node2`
3. With `proxy_arp=1` on `br0`, the kernel responds with br0's MAC address
4. `ctlplane-1` sends the IP packet to br0's MAC
5. The kernel routes it via `to-node2` → VXLAN → WireGuard → INBACRNRDL0103
6. INBACRNRDL0103 receives it on `to-node1`, routes via its `br0` to the worker VM

#### Floating VIP Routing

OpenShift uses keepalived to manage floating Virtual IP addresses (VIPs) that can move between
nodes during failover:

| VIP | Address | Managed by | Can float to |
|-----|---------|------------|--------------|
| API VIP | 172.16.30.10 | keepalived on control-plane nodes only | Any control-plane node (all on INBACRNRDL0102) |
| Ingress VIP | 172.16.30.11 | keepalived on all nodes | Any node (control-planes on 0102 OR workers on 0103) |

Because the Ingress VIP can land on either hypervisor, its /32 route requires **asymmetric
placement** to avoid routing loops:

| Hypervisor | Ingress VIP .11 route | API VIP .10 route | Rationale |
|------------|----------------------|-------------------|-----------|
| INBACRNRDL0102 | `172.16.30.11/32 via 10.0.0.2` (present) | _none_ | Ingress VIP may be on a worker (0103). Proxy ARP needs the route to answer local VM ARP requests. API VIP is always local — L2 resolves directly. |
| INBACRNRDL0103 | _none_ | `172.16.30.10/32 via 10.0.0.1` (present) | Ingress VIP may be local on a worker — if the /32 route existed, packets arriving from the VXLAN would be routed **back** into the tunnel (loop). API VIP is always remote — route is safe. |

**Why a /32 route on the same hypervisor causes a loop:**

```
 ① INBACRNRDL0102 sends packet for .11 via VXLAN to INBACRNRDL0103
 ② INBACRNRDL0103 receives packet on to-node1
 ③ Kernel looks up route for .11:
    - If /32 route exists → .11 via 10.0.0.1 → sends BACK to INBACRNRDL0102 → LOOP!
    - If only /24 route  → .11 dev br0 → ARP on br0 → worker VM responds → DELIVERED ✓
```

When the VIP is local, the /24 connected route on `br0` is sufficient — ARP resolves directly
on the bridge to the VM holding the VIP. The /32 route must only exist on the **opposite**
hypervisor where proxy ARP needs it.

### Step 8: TCP MSS Clamping

The VXLAN transit link has MTU 1370, but VMs internally use MTU 1500. When TCP connections cross
the VXLAN, the SYN segment must advertise an MSS that fits through the tunnel. Without this,
TCP data segments that exceed 1370 bytes will be silently dropped (the PMTUD black hole).

**On INBACRNRDL0102:**

```bash
iptables -t mangle -A FORWARD -o to-node2 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
iptables -t mangle -A FORWARD -i to-node2 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
```

**On INBACRNRDL0103:**

```bash
iptables -t mangle -A FORWARD -o to-node1 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
iptables -t mangle -A FORWARD -i to-node1 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
```

**Persist via NetworkManager dispatcher** — create `/etc/NetworkManager/dispatcher.d/99-mss-clamp`
on each host:

**INBACRNRDL0102** (`/etc/NetworkManager/dispatcher.d/99-mss-clamp`):

```bash
#!/bin/bash
IFACE="$1"
ACTION="$2"
if [ "$IFACE" = "to-node2" ] && [ "$ACTION" = "up" ]; then
    iptables -t mangle -C FORWARD -o to-node2 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || \
        iptables -t mangle -A FORWARD -o to-node2 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
    iptables -t mangle -C FORWARD -i to-node2 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || \
        iptables -t mangle -A FORWARD -i to-node2 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
fi
```

**INBACRNRDL0103** (`/etc/NetworkManager/dispatcher.d/99-mss-clamp`):

```bash
#!/bin/bash
IFACE="$1"
ACTION="$2"
if [ "$IFACE" = "to-node1" ] && [ "$ACTION" = "up" ]; then
    iptables -t mangle -C FORWARD -o to-node1 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || \
        iptables -t mangle -A FORWARD -o to-node1 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
    iptables -t mangle -C FORWARD -i to-node1 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || \
        iptables -t mangle -A FORWARD -i to-node1 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
fi
```

```bash
chmod 755 /etc/NetworkManager/dispatcher.d/99-mss-clamp
```

The `-C` (check) before `-A` (append) pattern prevents duplicate rules if the interface
is brought up multiple times.

### Step 9: Verify Routing

**INBACRNRDL0102:**

```
# ip route
default via 192.168.18.1 dev ens10f0 proto static metric 100
10.0.0.0/30 dev to-node2 proto kernel scope link src 10.0.0.1 metric 500
10.88.0.0/16 dev podman0 proto kernel scope link src 10.88.0.1
172.16.0.0/16 dev wg0 proto kernel scope link src 172.16.0.1
172.16.30.0/24 dev br0 proto kernel scope link src 172.16.30.1 metric 425
172.16.30.2 via 10.0.0.2 dev to-node2 proto static metric 500
172.16.30.11 via 10.0.0.2 dev to-node2 proto static metric 500    ← Ingress VIP (floats to workers)
172.16.30.23 via 10.0.0.2 dev to-node2 proto static metric 500
172.16.30.24 via 10.0.0.2 dev to-node2 proto static metric 500
192.168.18.0/24 dev ens10f0 proto kernel scope link src 192.168.18.53 metric 100
```

> Note: No /32 route for the API VIP (.10) — it always resides on a local control-plane node,
> so L2 ARP on `br0` resolves it directly.

**INBACRNRDL0103:**

```
# ip route
default via 192.168.18.1 dev ens10f0 proto static metric 100
10.0.0.0/30 dev to-node1 proto kernel scope link src 10.0.0.2 metric 500
172.16.0.0/16 dev wg0 proto kernel scope link src 172.16.0.2
172.16.30.0/24 dev br0 proto kernel scope link src 172.16.30.2 metric 425
172.16.30.1 via 10.0.0.1 dev to-node1 proto static metric 500
172.16.30.10 via 10.0.0.1 dev to-node1 proto static metric 500    ← API VIP (always on ctlplanes)
172.16.30.20 via 10.0.0.1 dev to-node1 proto static metric 500
172.16.30.21 via 10.0.0.1 dev to-node1 proto static metric 500
172.16.30.22 via 10.0.0.1 dev to-node1 proto static metric 500
192.168.18.0/25 dev ens10f0 proto kernel scope link src 192.168.18.54 metric 100
```

> Note: No /32 route for the Ingress VIP (.11) — it can reside on a local worker, and a /32
> route would create a routing loop for traffic arriving from the VXLAN tunnel.

**Route precedence explained:**

1. `172.16.30.23/32 via 10.0.0.2 dev to-node2` — /32 is more specific than /24, so traffic
   for a remote VM takes the VXLAN path
2. `172.16.30.0/24 dev br0` — /24 connected route handles local VMs (those with no /32 override)
3. `172.16.0.0/16 dev wg0` — /16 encompasses 172.16.30.0/24, but the more-specific /24 wins.
   Only pure WireGuard tunnel traffic (e.g., 172.16.0.1 → 172.16.0.2) uses this route

### Step 10: Final Connectivity Tests

**Test 1 — Local VM-to-VM at full MTU (1500 bytes):**

```
# From ctlplane-1 to ctlplane-0 (both on INBACRNRDL0102)
$ ping -c2 -W2 -M do -s 1472 172.16.30.20
PING 172.16.30.20 (172.16.30.20) 1472(1500) bytes of data.
1480 bytes from 172.16.30.20: icmp_seq=1 ttl=64 time=0.858 ms
1480 bytes from 172.16.30.20: icmp_seq=2 ttl=64 time=0.872 ms
--- 2 packets transmitted, 2 received, 0% packet loss ---
```

**Test 2 — Cross-hypervisor transit link:**

```
# From INBACRNRDL0102
$ ping -c2 10.0.0.2
64 bytes from 10.0.0.2: icmp_seq=1 ttl=64 time=2.31 ms
64 bytes from 10.0.0.2: icmp_seq=2 ttl=64 time=1.04 ms
```

**Test 3 — Cross-hypervisor Gitea access (large data transfer):**

```
# From INBACRNRDL0103
$ git clone --depth=1 http://172.16.30.1:3000/student/telco-reference.git /tmp/test
Cloning into '/tmp/test'...
CLONE_OK
```

---

## Persistence Summary

All configurations survive reboots via the following mechanisms:

| Component | Persistence Method | File/Location |
|-----------|-------------------|---------------|
| WireGuard tunnel | systemd service | `systemctl enable wg-quick@wg0` + `/etc/wireguard/wg0.conf` |
| VXLAN interface + MTU + transit IP + /32 routes | NetworkManager connection | `nmcli con show to-node2` (or `to-node1`) |
| br0 MTU 1500 | NetworkManager connection | `nmcli con show br0` |
| br0 libvirt network | libvirt persistent network | `virsh net-autostart br0` + `/etc/libvirt/qemu/networks/br0.xml` |
| IP forwarding | sysctl drop-in | `/etc/sysctl.d/99-wireguard.conf` |
| Proxy ARP on br0 | sysctl drop-in | `/etc/sysctl.d/99-proxy-arp.conf` |
| TCP MSS clamping | NM dispatcher script | `/etc/NetworkManager/dispatcher.d/99-mss-clamp` |
| VM vnet attachment to br0 | libvirt domain XML | Automatic when VMs start |

### Adding/Removing Remote VMs

When VMs are added or removed on either hypervisor, update the /32 routes in the NM connection
on the **opposite** hypervisor:

```bash
# Example: add worker-2 (172.16.30.25) on INBACRNRDL0103
# On INBACRNRDL0102, add the route:
nmcli con modify to-node2 +ipv4.routes "172.16.30.25/32 10.0.0.2"
nmcli con up to-node2
```

---

## Findings from the INBACRNRDL0102 / INBACRNRDL0103 Environment

### The PMTUD Black Hole Problem (Cross-Hypervisor)

During the OpenShift 4.19 upgrade, the ArgoCD repo-server pods (running on worker VMs hosted
by INBACRNRDL0103) could not fetch git repositories from Gitea (running on INBACRNRDL0102).
The symptom was:

- TCP handshakes succeeded (small packets, ~64 bytes)
- HTTP headers were exchanged (small packets, <800 bytes)
- Git negotiation completed (small POST/response pairs)
- **Large data transfers hung indefinitely** — `git fetch`, `git clone`, and even large `curl`
  downloads never completed

**Root cause:** The VXLAN interfaces were at the default MTU of 1500, exceeding the WireGuard
tunnel's 1420-byte capacity after encapsulation. Large packets were silently dropped.

**Fix:** Set VXLAN MTU to 1370 on both hosts.

### The PMTUD Black Hole Problem (Intra-Hypervisor, Bridged Design)

After fixing the VXLAN MTU to 1370, a second PMTUD black hole appeared — this time affecting
VMs on the **same hypervisor** (INBACRNRDL0102). The OpenShift agent-based installer reported
`hub-ctlplane-1` and `hub-ctlplane-2` as "disconnected."

**Root cause:** With the VXLAN (MTU 1370) as a bridge member of br0, the bridge MTU dropped
to 1370. This cascaded to the host-side vnet interfaces (1370), but the guest OS inside each
VM retained MTU 1500 on its `enp3s0`. Packets between 1371–1500 bytes from VMs were silently
dropped at the host bridge — a PMTUD black hole for purely local traffic.

**Diagnostic evidence:**

```
# VM internal MTU (guest OS)
$ ip link show enp3s0
2: enp3s0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 ...

# Host-side bridge and vnet MTU (capped by VXLAN member)
# ip link show br0
13: br0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1370 ...

# Large ping from ctlplane-1 to ctlplane-0 (same hypervisor)
$ ping -c2 -W2 -M do -s 1342 172.16.30.20   # 1370 bytes → WORKS
$ ping -c2 -W2 -M do -s 1372 172.16.30.20   # 1400 bytes → 100% loss
$ ping -c2 -W2 -M do -s 1472 172.16.30.20   # 1500 bytes → 100% loss

# br0 TX dropped counter
# ip -s link show br0 | grep -A1 "TX:"
    TX: bytes packets errors dropped ...
        ...     ...     0      46600  ...
```

**Fix:** Decouple the VXLAN from br0 (this document's current architecture). With the VXLAN on
its own routed interface, br0 stays at MTU 1500 and local VM traffic is unaffected.

### The Floating VIP Routing Loop

After decoupling the VXLAN and adding /32 routes for all known remote IPs (including the
OpenShift VIPs), a third connectivity issue appeared: the Ingress VIP (172.16.30.11) was
unreachable from control-plane VMs on INBACRNRDL0102 even though keepalived on worker-1
(INBACRNRDL0103) was correctly holding the VIP.

**Root cause:** Both hypervisors had /32 routes for the Ingress VIP pointing to each other,
creating a routing loop:

1. INBACRNRDL0102 sent traffic for .11 → via VXLAN to INBACRNRDL0103
2. INBACRNRDL0103 received the packet on `to-node1`
3. INBACRNRDL0103's /32 route for .11 pointed back → via VXLAN to INBACRNRDL0102
4. Packet bounced back and forth until TTL expired — silently dropped

**Symptoms:**
- `authentication`, `console`, and `ingress` ClusterOperators reported Degraded
- Route health checks (`*.apps.hub.5g-deployment.lab`) timed out from control-plane pods
- `ping 172.16.30.11` from ctlplane-0 showed 100% packet loss
- keepalived on worker-1 showed MASTER state and sent gratuitous ARPs normally

**Fix:** Apply asymmetric VIP routing — place each VIP's /32 route only on the hypervisor
where the VIP is **not** expected to reside:
- Ingress VIP (.11) route on INBACRNRDL0102 only (VIP can be on workers at 0103)
- API VIP (.10) route on INBACRNRDL0103 only (VIP is always on control-planes at 0102)
- No VIP route where the VIP is local — the /24 connected route on `br0` handles delivery

### MSS Clamping Bypass — Bridged VXLAN on INBACRNRDL0102 (2026-03-24)

During the OpenShift 4.19 upgrade, the ArgoCD `rds-hub-operators-deployment` application on
the hub cluster became permanently stuck at `sync=Unknown`. The ArgoCD repo-server pod (running
on `hub-worker-0` at INBACRNRDL0103) could not complete `git fetch` against the Gitea container
on INBACRNRDL0102. The symptoms were identical to the original PMTUD black hole: TCP handshakes
and small HTTP responses (API version, `git ls-remote`) succeeded, but all data transfers
exceeding ~1370 bytes hung indefinitely.

**Discovery:** On INBACRNRDL0102, `to-node2` was found to be **a bridge member of `br0`** at
MTU 1500 — the **bridged design**, not the decoupled design described in this document:

```
# ip -d link show to-node2
756: to-node2: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue master br0 ...
    vxlan id 1 remote 172.16.0.2 dstport 4789
    bridge_slave state forwarding
```

This had two consequences:

1. **MTU mismatch**: The VXLAN interface had MTU 1500 instead of 1370, so the kernel
   accepted 1500-byte packets into the VXLAN tunnel where they exceeded the WireGuard
   path MTU and were silently dropped.

2. **MSS clamping bypass**: The existing iptables rules targeting `-i to-node2` / `-o to-node2`
   **never matched any traffic**. When a VXLAN device is a bridge member, Linux iptables
   FORWARD chain sees the traffic on the **bridge master** (`br0`), not the individual bridge
   port (`to-node2`). The `bridge-nf-call-iptables` sysctl (which enables per-port matching
   for bridged traffic) was not loaded on this host. As a result, the MSS clamping rules had
   zero effect — all 475+ TCP SYN packets traversed the tunnel with the default MSS of ~1460,
   producing segments too large for the 1370-byte path.

**Diagnostic evidence — path MTU test from hub-worker-0:**

```
# From hub-worker-0 (INBACRNRDL0103) to infra (INBACRNRDL0102)
$ ping -c 3 -M do -s 1400 172.16.30.1
From 172.16.30.1 icmp_seq=1 Frag needed and DF set (mtu = 1370)
100% packet loss

$ ping -c 3 -M do -s 1200 172.16.30.1
3 packets transmitted, 3 received, 0% packet loss
```

**Diagnostic evidence — Gitea zombie connections:**

Each failed `git fetch` left zombie TCP connections in the Gitea container with 44–45 KB of
unsent data stuck in the kernel send buffer. After multiple ArgoCD retry cycles, Gitea
accumulated enough stuck goroutines to deadlock its HTTP handler, blocking all new requests
(even small ones) from the OCP worker node:

```
# podman exec gitea netstat -antp (inside Gitea container)
tcp  0  44536 ::ffff:10.88.0.10:3000  ::ffff:172.16.30.23:51650 CLOSE_WAIT  -
tcp  0  44536 ::ffff:10.88.0.10:3000  ::ffff:172.16.30.23:46304 CLOSE_WAIT  -
tcp  0  44536 ::ffff:10.88.0.10:3000  ::ffff:172.16.30.23:32770 CLOSE_WAIT  -
tcp  0  45113 ::ffff:10.88.0.10:3000  ::ffff:172.16.30.23:54541 ESTABLISHED -
```

Gitea stopped responding to `SIGTERM` (required `SIGKILL` to restart), confirming the
internal deadlock.

**Runtime fixes applied on INBACRNRDL0102:**

```bash
# 1. Correct the VXLAN MTU (runtime only — not persisted by NM)
ip link set to-node2 mtu 1370

# 2. Add global MSS clamping that matches ALL forwarded TCP SYN packets,
#    bypassing the bridge-port iptables visibility problem.
#    MSS 1280 provides margin for TCP timestamps (12 bytes) and any
#    additional IP options.
iptables -t mangle -I FORWARD -p tcp --tcp-flags SYN,RST SYN \
    -j TCPMSS --set-mss 1280

# 3. Restart Gitea to clear deadlocked goroutines and zombie connections
podman restart gitea

# 4. Restart ArgoCD repo-server to establish fresh TCP connections
#    with the corrected MSS
oc delete pod -n openshift-gitops \
    -l app.kubernetes.io/name=openshift-gitops-repo-server
```

**Verification after fix:**

```
# Full git clone from ArgoCD repo-server pod (on hub-worker-0) succeeds
$ timeout 30 git clone -b release-4.19 \
    http://infra.5g-deployment.lab:3000/student/telco-reference.git /tmp/test
Cloning into '/tmp/test'...
exit=0   (completed in ~3 seconds)

# git fetch also works
$ cd /tmp/test && timeout 30 git fetch origin --tags --force --prune
exit=0

# ArgoCD sync operation succeeds
$ oc get apps -A
NAMESPACE          NAME                           SYNC STATUS   HEALTH STATUS
openshift-gitops   rds-hub-operators-deployment   OutOfSync     Healthy
# opPhase=Succeeded, opMsg=successfully synced (all tasks run)
```

**Remaining `OutOfSync` items** after the sync completed are expected drift, not related to
the network fix:

| Resource | Reason |
|----------|--------|
| 4 Policies (`hub-policies.*`, `pull-secret-copy`) | ACM recreates them after ArgoCD prunes; managed by PolicySet |
| `MultiClusterHub` | Admission webhook blocks `LocalClusterName` update |

**Why the existing MSS rules failed — iptables rule counters:**

```
Chain FORWARD (policy ACCEPT)
 pkts bytes target     prot opt in     out     source               destination
  475 28500 TCPMSS     tcp  --  *      *       0/0        0/0       TCPMSS set 1280    ← NEW: matches
    0     0 TCPMSS     tcp  --  to-node2 *     0/0        0/0       TCPMSS set 1330    ← never matches
    0     0 TCPMSS     tcp  --  *      to-node2 0/0       0/0       TCPMSS set 1330    ← never matches
21068  ...  TCPMSS     tcp  --  *      to-node2 0/0       0/0       clamp-mss-to-pmtu  ← pre-existing, stale
22128  ...  TCPMSS     tcp  --  to-node2 *     0/0       0/0        clamp-mss-to-pmtu  ← pre-existing, stale
```

The 21068/22128 counters on the pre-existing `clamp-mss-to-pmtu` rules are stale (accumulated
before the bridge membership change). After the change, zero new matches.

> **These fixes are NOT persistent.** The MTU change and the global iptables rule will be
> lost on reboot. To make them permanent, either:
>
> 1. **Complete the migration to the decoupled (routed) design** described in this document
>    (remove `to-node2` from `br0`, assign it a transit IP on `10.0.0.0/30`, add /32 host
>    routes). This is the recommended approach — the interface-specific MSS clamping rules
>    will then work correctly.
>
> 2. **If the bridged design must be kept**, persist the global MSS rule via the NM dispatcher
>    and set the MTU in the NetworkManager VXLAN connection:
>
>    ```bash
>    nmcli con modify to-node2 ethernet.mtu 1370
>    nmcli con up to-node2
>    ```
>
>    And update `/etc/NetworkManager/dispatcher.d/99-mss-clamp` to use the global rule
>    (without interface filtering) since bridge-port matching does not work:
>
>    ```bash
>    #!/bin/bash
>    IFACE="$1"; ACTION="$2"
>    if [ "$IFACE" = "to-node2" ] && [ "$ACTION" = "up" ]; then
>        iptables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN \
>            -j TCPMSS --set-mss 1280 2>/dev/null || \
>        iptables -t mangle -I FORWARD -p tcp --tcp-flags SYN,RST SYN \
>            -j TCPMSS --set-mss 1280
>    fi
>    ```

---

## Extending to Three Hosts

The two-host setup uses point-to-point VXLAN (`remote <IP>`) which only supports a single
remote peer per VXLAN interface. To extend the architecture to three or more hosts, there are
two approaches:

### Option A: VXLAN with Multicast Group (Recommended for 3+ Hosts)

Instead of specifying a single `remote` IP, use a multicast group that all hosts join. This
allows automatic BUM (Broadcast, Unknown-unicast, Multicast) traffic flooding to all peers.

**Network topology for 3 hosts:**

```
 Host A (172.16.0.1)       Host B (172.16.0.2)       Host C (172.16.0.3)
 ┌──────────────┐          ┌──────────────┐          ┌──────────────┐
 │ br0 (.30.1)  │          │ br0 (.30.2)  │          │ br0 (.30.3)  │
 │ MTU 1500     │          │ MTU 1500     │          │ MTU 1500     │
 │              │          │              │          │              │
 │ vxlan0       │          │ vxlan0       │          │ vxlan0       │
 │ 10.0.0.1/24  │          │ 10.0.0.2/24  │          │ 10.0.0.3/24  │
 │ MTU 1370     │          │ MTU 1370     │          │ MTU 1370     │
 │ (standalone) │          │ (standalone) │          │ (standalone) │
 │      │       │          │      │       │          │      │       │
 │ wg0 (mesh)   │          │ wg0 (mesh)   │          │ wg0 (mesh)   │
 └──────┼───────┘          └──────┼───────┘          └──────┼───────┘
        │                         │                         │
        └─────────────────────────┴─────────────────────────┘
                    Physical Network (192.168.18.0/24)
```

**Step 1: Configure WireGuard as a full mesh**

Each host must have all other hosts as peers in `/etc/wireguard/wg0.conf`. WireGuard does not
natively support multicast, so the VXLAN multicast traffic gets routed as unicast through the
appropriate WireGuard peer based on the destination IP.

**Host A** (`/etc/wireguard/wg0.conf`):

```ini
[Interface]
PrivateKey = <HOST_A_PRIVATE_KEY>
Address = 172.16.0.1/16
ListenPort = 51820
PostUp   = iptables -A FORWARD -i %i -j ACCEPT; iptables -A FORWARD -o %i -j ACCEPT
PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -D FORWARD -o %i -j ACCEPT

[Peer]
# Host B
PublicKey = <HOST_B_PUBLIC_KEY>
Endpoint = 192.168.18.54:51820
AllowedIPs = 172.16.0.2/32

[Peer]
# Host C
PublicKey = <HOST_C_PUBLIC_KEY>
Endpoint = 192.168.18.55:51820
AllowedIPs = 172.16.0.3/32
```

> **Important change for 3+ hosts:** `AllowedIPs` must be split into per-peer /32 routes instead
> of a single /16. Otherwise, WireGuard cannot determine which peer to send a packet to (only one
> peer can own a given route).

**Step 2: Create VXLAN with multicast group**

Since WireGuard does not forward multicast natively, use the **bridge FDB** approach instead
(see Option B). Multicast-based VXLAN requires the underlay to support multicast routing, which
WireGuard does not.

### Option B: VXLAN with Static FDB Entries (Works Over WireGuard)

This is the practical approach for 3+ hosts over WireGuard. Instead of relying on multicast for
BUM traffic flooding, manually populate the bridge forwarding database (FDB) with the remote
VTEPs (VXLAN Tunnel Endpoints).

**On each host, create the VXLAN without a `remote` parameter:**

```bash
nmcli con add type vxlan \
    con-name vxlan0 \
    ifname vxlan0 \
    vxlan.id 1 \
    vxlan.local 172.16.0.1 \
    vxlan.destination-port 4789 \
    ethernet.mtu 1370 \
    ipv4.method manual \
    ipv4.addresses 10.0.0.1/24 \
    ipv4.routes "172.16.30.2/32 10.0.0.2, 172.16.30.3/32 10.0.0.3, <remote-VM-IPs>" \
    connection.autoconnect yes
```

**Then add static FDB entries for each remote VTEP:**

```bash
bridge fdb append 00:00:00:00:00:00 dev vxlan0 dst 172.16.0.2  # Host B
bridge fdb append 00:00:00:00:00:00 dev vxlan0 dst 172.16.0.3  # Host C
```

The `00:00:00:00:00:00` entry is the "default" FDB entry — it tells the VXLAN driver to send
BUM (broadcast/unknown-unicast/multicast) traffic to these VTEPs. As the bridge learns MAC
addresses from incoming traffic, it populates specific FDB entries automatically.

**WireGuard configuration for 3-host mesh:**

Each host's WireGuard config must have peers for all other hosts with /32 `AllowedIPs`:

| Host | WG IP | Physical IP | Peers (AllowedIPs) |
|------|-------|------------|-------------------|
| A (INBACRNRDL0102) | 172.16.0.1 | 192.168.18.53 | B: 172.16.0.2/32, C: 172.16.0.3/32 |
| B (INBACRNRDL0103) | 172.16.0.2 | 192.168.18.54 | A: 172.16.0.1/32, C: 172.16.0.3/32 |
| C (new host) | 172.16.0.3 | 192.168.18.55 | A: 172.16.0.1/32, B: 172.16.0.2/32 |

### Key Differences: 2-Host vs 3-Host Configuration

| Aspect | 2 Hosts (current) | 3+ Hosts |
|--------|-------------------|----------|
| VXLAN remote | `remote <IP>` (single peer) | No `remote`; use FDB entries |
| WireGuard AllowedIPs | `172.16.0.0/16` (single peer owns all) | `/32` per peer (split routing) |
| BUM traffic | Sent to single remote | Replicated to all FDB entries |
| Scalability | Point-to-point only | Full mesh, N*(N-1)/2 tunnels |
| Configuration complexity | Simple | Grows O(N^2) with hosts |

---

## Summary

| Component | INBACRNRDL0102 | INBACRNRDL0103 |
|-----------|---------------|---------------|
| Hostname | INBACRNRDL0102.workload.bos2.lab | INBACRNRDL0103.workload.bos2.lab |
| Physical NIC | ens10f0 (192.168.18.53/24, MTU 1500) | ens10f0 (192.168.18.54/25, MTU 1500) |
| WireGuard IP | 172.16.0.1/16 (wg0, MTU 1420) | 172.16.0.2/16 (wg0, MTU 1420) |
| WG Public Key | `4K9Vfw71Co...` | `XVljtBChNW...` |
| VXLAN Interface | to-node2 (VNI=1, remote=172.16.0.2) | to-node1 (VNI=1, remote=172.16.0.1) |
| VXLAN MTU | **1370** | **1370** |
| VXLAN IP (transit) | **10.0.0.1/30** | **10.0.0.2/30** |
| VXLAN bridge membership | **Standalone (not bridged)** | **Standalone (not bridged)** |
| Bridge IP | 172.16.30.1/24 (br0, **MTU 1500**) | 172.16.30.2/24 (br0, **MTU 1500**) |
| Bridge Members | vnet421, vnet422, vnet423 (VMs only) | vnetX (worker VMs only) |
| Proxy ARP | Enabled on br0 | Enabled on br0 |
| MSS Clamping | iptables FORWARD on to-node2 | iptables FORWARD on to-node1 |
| /32 Routes via VXLAN | .2, **.11** (Ingress VIP), .23, .24 → 10.0.0.2 | .1, **.10** (API VIP), .20, .21, .22 → 10.0.0.1 |
| Role | Infrastructure host (Gitea, Registry) + control plane VMs | Hypervisor (OCP worker VMs) |
