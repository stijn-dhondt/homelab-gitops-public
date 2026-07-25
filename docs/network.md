# Network Configuration

Physical/VLAN network design — configured on the Unifi router/switch, not git-managed. For the
*cluster-facing* DNS records this design produces (Cloudflare + Pi-hole split-DNS), see
[external-dependencies.md](external-dependencies.md) instead — that list is the one that actually
needs redoing after a rebuild.

## Network Architecture

This homelab uses **VLAN segmentation** for security, isolation, and scalability following
production best practices:

- **Traffic Isolation**: Each service type on dedicated VLAN
- **Security**: Firewall rules between VLANs prevent unauthorized access
- **Scalability**: Easy to add nodes and services without reconfiguration
- **Troubleshooting**: Clear separation enables faster diagnosis

## VLAN Design

| VLAN ID | Name | Subnet | Gateway | Purpose |
|---------|------|--------|---------|---------|
| 10 | Management | `10.0.10.0/24` | `.1` | Infrastructure admin, switch management, DNS |
| 20 | Talos cluster | `10.0.20.0/24` | `.1` | Cluster nodes (control planes + workers) |
| 30 | Pod Network | `10.0.0.0/8` | Cilium | Pod-to-pod communication (Cilium IPAM managed) |
| 40 | Services/Ingress | `10.0.40.0/24` | `.1` | LoadBalancer IPs, Ingress endpoints |
| 50 | Storage (Optional) | `10.0.50.0/24` | `.1` | NAS and persistent volume traffic, PXE boot server |

### Management subnet (VLAN 10)

```
10.0.10.0/24
├── Virtual IP (VIP)        → 10.0.10.6    (switch)
├── NAS                     → 10.0.10.11   (NAS Admin interface)
├── PI-Hole DNS             → 10.0.10.12   (PI-Hole)
├── PXE Booter              → 10.0.10.13   (BOOTER)
```

### Talos Cluster Subnet (VLAN 20)

```
10.0.20.0/24
├── Virtual IP (VIP)        → 10.0.20.10   (kube-apiserver endpoint)
├── Control Plane 1 (CP-01) → 10.0.20.11   (Mac: 00:4e:01:ba:5b:3f)
├── Control Plane 2 (CP-02) → 10.0.20.12   (Mac: 00:4e:01:a0:5c:4f)
├── Control Plane 3 (CP-03) → 10.0.20.13   (Mac: 00:4e:01:a5:65:b3)
├── Worker 1 (WRKR-01)      → 10.0.20.21   (Mac: 00:4e:01:a5:b4:9b)
```

### Pod Network (VLAN 30)

```
10.0.0.0/8
└── Cilium IPAM auto-manages per-node allocation
```

Cilium automatically distributes pod subnets per node. No conflicts with host networking
(different subnet). In practice, Cilium hands out from `10.244.0.0/16` — see
[clusters/talos-dev/networking/cilium/README.md](../clusters/talos-dev/networking/cilium/README.md).

### Services/Ingress Network (VLAN 40)

```
10.0.40.0/24
├── Ingress Controller VIP     → 10.0.40.100  (first IP from the LB IPAM pool)
├── LoadBalancer Service Range → 10.0.40.100-10.0.40.200
└── External API access       → (configured per service)
```

### Storage Network for persistent volumes (VLAN 50)

```
10.0.50.0/24
├── NAS (Maiyunda)          → 10.0.50.100
```

Use this VLAN to prevent storage I/O from saturating cluster traffic. The PXE boot server runs in
a Docker container on the NAS.

## DNS Strategy

**Internal DNS (Pi-hole @ 10.0.10.12, docker on NAS):**

```
kubernetes.local          → 10.0.20.10   (API VIP - cluster endpoint)
cp-01.local               → 10.0.20.11
cp-02.local               → 10.0.20.12
cp-03.local               → 10.0.20.13
wrkr-01.local             → 10.0.20.21
*.svc.cluster.local       → CoreDNS (Cilium managed)
```

**External DNS (non-cluster services on the same Cloudflare zone):**

```
omv.example.com           → 10.0.10.11:1080  (NAS admin interface - OMV)
code.example.com          → 10.0.10.11:8443  (VS Code Server used for local coding)
```

These two are unrelated to the Kubernetes cluster's ingress — direct exposures of other services
on the same domain. The cluster's *own* DNS records (Cloudflare Tunnel + Pi-hole split-DNS for
`*.lab.example.com` and the public apps) are tracked separately in
[external-dependencies.md](external-dependencies.md), since those are the ones that actually need
recreating after a cluster rebuild.

## Network Policies

Apply these firewall rules on Unifi to enforce traffic flow:

| From | To | Ports | Action | Purpose |
|------|-----|-------|--------|---------|
| VLAN 20 (K8s) | VLAN 30 (Pods) | All | Allow | Pod access from nodes |
| VLAN 30 (Pods) | VLAN 20 (K8s) | 443, 53 | Allow | Pods reach kube-apiserver & DNS |
| VLAN 20 (K8s) | VLAN 40 (Services) | All | Allow | Internal service communication |
| VLAN 40 (Services) | External | 80, 443 | Allow | Ingress public access |
| VLAN 10 (Mgmt) | VLAN 20 (K8s) | 22, 50000 | Allow | SSH & Talos API |
| VLAN 20 (K8s) | VLAN 50 (Storage) | 111, 2049, 3260 | Allow | NFS/iSCSI for persistent volumes |
| VLAN 20 (K8s) | VLAN 10 (Management) | 67, 68, 69 | Allow | DHCP/TFTP for PXE boot |
| External | VLAN 20 (K8s) | None | Deny | Block direct cluster access |

**Remote access (WARP):** Cloudflare Zero Trust WARP routes remote clients into VLAN 20 + VLAN 40
through the existing Cloudflare Tunnel (see
[networking/cloudflare-tunnel/README.md](../clusters/talos-dev/networking/cloudflare-tunnel/README.md)'s
"Remote access via Cloudflare WARP") — chosen over a router-hosted VPN because Starlink's CGNAT
blocks any inbound connection to the router. That traffic still enters at VLAN 20, so it's subject
to every rule in the table above — it does **not** get VLAN 10/50 access beyond what's already
listed here.
