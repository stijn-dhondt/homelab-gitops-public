> **This is an automatically generated, sanitized mirror.**
>
> Hostnames, internal IPs, and a couple of other identifying values have been
> replaced with generic placeholders. It is not intended to be applied to a real
> cluster as-is, and isn't edited directly here - changes happen in the source repo
> and sync here automatically on every push.
>

# Kubernetes Homelab

A 4-node bare-metal [Talos Linux](https://www.talos.dev/) Kubernetes cluster, entirely managed via
GitOps ([Flux](https://fluxcd.io/)) from this repository. Push to `prod` and the cluster
reconciles — nothing described here is applied by hand except the one-time bootstrap.

This README stays high-level on purpose — everything else lives next to what it describes: each
app under `clusters/talos-dev/apps/<name>/README.md`, each infrastructure component under its own
folder, and cross-cutting topics (hardware, network, the bootstrap runbook) under `docs/`.

## Architecture at a glance

- **4x Dell Optiplex 3070** — 3 control planes + 1 worker, VLAN-segmented network, PXE-booted from
  a NAS. See [docs/hardware.md](docs/hardware.md) and [docs/network.md](docs/network.md).
- **Talos Linux** — immutable, API-managed Kubernetes OS. No SSH, no package manager; config
  changes are machine-config patches. See
  [clusters/talos-dev/talos/README.md](clusters/talos-dev/talos/README.md).
- **Cilium** — CNI, kube-proxy replacement, LoadBalancer IPAM, and Hubble observability. See
  [clusters/talos-dev/networking/cilium/README.md](clusters/talos-dev/networking/cilium/README.md).
- **Flux** — reconciles everything under `clusters/talos-dev/` on every push to `prod`.
- **Two storage backends** — `zfs-nfs` (democratic-csi, the cluster default) and `longhorn` (local
  block storage with replication), used per-app depending on what fits better.
- **Authentik** — SSO in front of every internal admin UI (Grafana, Prometheus, Alertmanager, n8n,
  Longhorn UI, Hubble UI), each gated by its own group, sharing one login. See
  [clusters/talos-dev/apps/authentik/README.md](clusters/talos-dev/apps/authentik/README.md).
- **Nothing internal is public** — every one of those admin UIs is `*.lab.example.com`-only, reachable
  exclusively over Cloudflare Zero Trust WARP, never through a public DNS record. The only thing the
  Cloudflare Tunnel exposes to the internet at all is the WordPress site (`example.com`). See
  [clusters/talos-dev/networking/cloudflare-tunnel/README.md](clusters/talos-dev/networking/cloudflare-tunnel/README.md).

## Documentation map

**Getting a cluster running from scratch:**
- [docs/hardware.md](docs/hardware.md) — physical inventory
- [docs/network.md](docs/network.md) — VLAN design, subnets, firewall rules
- [docs/pxe-boot.md](docs/pxe-boot.md) — netbooting Talos onto bare metal
- [docs/cluster-bootstrap.md](docs/cluster-bootstrap.md) — the one-time runbook: Talos config,
  Cilium bootstrap, Flux bootstrap
- [docs/external-dependencies.md](docs/external-dependencies.md) — everything that lives outside
  git and won't come back from a redeploy alone (DNS records, NAS share permissions)
- [docs/quick-reference.md](docs/quick-reference.md) — command cheat-sheet
- [docs/claude-code-mcp.md](docs/claude-code-mcp.md) — Claude Code's MCP server setup (Grafana,
  Cloudflare, GitHub, UniFi) and the gotchas hit getting there

**Cluster-managed infrastructure** (`clusters/talos-dev/`):
- [talos/](clusters/talos-dev/talos/README.md) — machine-config patches, Talos Image Factory schematic
- [networking/cilium/](clusters/talos-dev/networking/cilium/README.md) — CNI, LB IPAM, Hubble
- [networking/ingress-nginx/](clusters/talos-dev/networking/ingress-nginx/README.md) — the ingress controller
- [networking/cert-manager/](clusters/talos-dev/networking/cert-manager/README.md) — Let's Encrypt via Cloudflare DNS-01
- [networking/cloudflare-tunnel/](clusters/talos-dev/networking/cloudflare-tunnel/README.md) — the only public entry point
- [storage/democratic-csi/](clusters/talos-dev/storage/democratic-csi/README.md) — ZFS-over-NFS, the default StorageClass
- [storage/longhorn/](clusters/talos-dev/storage/longhorn/README.md) — replicated local block storage
- [security/sealed-secrets/](clusters/talos-dev/security/sealed-secrets/README.md) — how every `*-sealed.yaml` in this repo works

**Apps** (`clusters/talos-dev/apps/`) — see
[clusters/talos-dev/apps/README.md](clusters/talos-dev/apps/README.md) for the full index and the
shared per-app file convention:
- [n8n](clusters/talos-dev/apps/n8n/README.md), [WordPress](clusters/talos-dev/apps/wordpress/README.md),
  [Authentik](clusters/talos-dev/apps/authentik/README.md), [Forgejo](clusters/talos-dev/apps/forgejo/README.md)

## Work in progress

- [ ] Use Talos Omni for fully automated cluster deployment via dashboard
- [ ] Enable Secure Boot after initial deployment
- [X] Implement automated backups of etcd

## Ownership

See [OWNERSHIP.md](OWNERSHIP.md).
