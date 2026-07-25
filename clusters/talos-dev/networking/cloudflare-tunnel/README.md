# Cloudflare Tunnel

The only way traffic reaches this cluster from the public internet — `example.com`, `www.example.com`,
and `jump.example.com` (see `apps/jumphost/README.md`) all route in through here. There is
deliberately no port-forwarding or public ingress exposure at the router; `cloudflared` makes an
outbound-only connection to Cloudflare, which then proxies matching hostnames back through it.

Every `*.lab.example.com` app is **not** routed through this tunnel — those are internal-only,
split-DNS-only (see [docs/external-dependencies.md](../../../../docs/external-dependencies.md)).

## Files in this folder

| File | Purpose |
|------|---------|
| `namespace.yaml` | Creates the `cloudflare-tunnel` namespace. |
| `serviceaccount.yaml` | ServiceAccount the tunnel pods run as. |
| `cloudflare-tunnel-credentials-sealed.yaml` | A `SealedSecret` holding the tunnel's credentials JSON (`tunnel.json`) — see [Setting up the tunnel](#setting-up-the-tunnel-not-in-git) below. |
| `cloudflared-configmap.yaml` | `config.yml` — the tunnel ID and the `ingress:` list mapping each public hostname to `ingress-nginx-controller.ingress-nginx.svc.cluster.local:443` (SNI-matched via `originServerName`). Adding a new publicly-exposed hostname means adding an entry here. |
| `deployment.yaml` | The `cloudflared` connector itself, 2 replicas. |

## Setting up the tunnel (not in git)

The tunnel itself (its ID, and the credentials file) is created once, outside the cluster, and
isn't reproducible from git — only its *use* is:

```bash
cloudflared tunnel login
cloudflared tunnel create <NAME>
```

This downloads a credentials JSON to `~/.cloudflared/<UUID>.json`. Copy its contents into
`cloudflare-tunnel-credentials-sealed.yaml` as the sealed `tunnel.json` key (see the root README's
Sealed Secrets section for the general `kubeseal` workflow), and put the same `<UUID>` as the
`tunnel:` field in `cloudflared-configmap.yaml`.

As long as the same tunnel is reused (not deleted and recreated) across a cluster rebuild, the
public DNS records in [docs/external-dependencies.md](../../../../docs/external-dependencies.md)
keep working unchanged — only the credentials secret needs restoring.

## Remote access via Cloudflare WARP

Added because the homelab is behind Starlink's CGNAT — no public IP means a router-hosted VPN
(WireGuard/UniFi Teleport/etc.) can't work, since nothing could open an inbound connection to it.
This tunnel already proves outbound-only connectivity works fine through that CGNAT (it's how
`example.com`/`jump.example.com` are reachable at all), so remote LAN access reuses it instead of
standing up new infrastructure: Cloudflare Zero Trust's WARP client routes matching traffic through
this same tunnel to specific private IP ranges, rather than only proxying the public hostnames
above.

**Deliberately scoped to VLAN 20 (Talos cluster) + VLAN 40 (Services/Ingress) only** —
`10.0.20.0/24` and `10.0.40.0/24` — covering the cluster nodes (`kubectl`/`talosctl`/SSH) and
every `*.lab.example.com` app (all resolve into the `10.0.40.0/24` range). **Not** VLAN 10
(Management: Pi-hole, NAS admin) or VLAN 50 (Storage) beyond what's already routed — the existing
Unifi firewall policy (see [docs/network.md](../../../../docs/network.md)'s "Network Policies")
only allows VLAN 20 into those two for narrow specific ports (DHCP/TFTP, NFS/iSCSI), and that's
intentional, unchanged segmentation, not a gap to route around.

`warp-routing: enabled: true` in `cloudflared-configmap.yaml` is the only in-repo piece. Everything
else is Cloudflare **account-level** configuration (and one Unifi firewall rule) — not reproducible
from git, same category as the tunnel's own credentials (see
[Setting up the tunnel](#setting-up-the-tunnel-not-in-git) above).

**Private network routes currently registered against this tunnel** (`cloudflared tunnel route ip
show`) — the CLI needs `cloudflared tunnel login` against this account first, or use the Zero Trust
dashboard instead (Networks → Tunnels → this tunnel → Private Network → Add a route). Comment is
the third positional argument, not a `--comment` flag:
```bash
cloudflared tunnel route ip add 10.0.20.0/24 homelab-2 "Talos cluster"
cloudflared tunnel route ip add 10.0.40.0/24 homelab-2 "Services/Ingress"
cloudflared tunnel route ip add 10.0.10.12/32 homelab-2 "Pi-hole DNS"
```
That third route is deliberately a `/32` (Pi-hole's exact IP), **not** `10.0.10.0/24` — the
latter would be the entire Management VLAN (NAS admin, PXE booter, switch VIP, everything else that
ever lands there), which defeats the point of keeping this scoped to "cluster + apps" plus just
enough DNS to make `*.lab.example.com` hostnames resolve. Registering the route is only step one,
though — three more pieces are needed for that DNS resolution to actually work, none of them
in-repo:

1. **Zero Trust must be enabled** on the Cloudflare account (free tier, up to 50 users) — the
   Zero Trust dashboard prompts for this on first visit if not already done.
2. **Set up at least one Access policy** (Zero Trust → Access → Policies) — WARP client
   enrollment requires an identity/authentication method (e.g. one-time PIN to your own email is
   the simplest for single-user use).
3. **Install the WARP client**, log it into this Zero Trust organization, and switch its mode from
   the default "1.1.1.1 (DNS only)" to **"Gateway with WARP"** — DNS-only mode routes nothing.
4. **Add all three CIDRs above to the WARP Client's Split Tunnel Include list** (Zero Trust →
   Settings → WARP Client → Device settings profiles → your profile → Split Tunnels). This is a
   *separate* setting from the tunnel routes above — the tunnel routes tell Cloudflare's edge what's
   reachable through this tunnel at all; Split Tunnel decides what the client actually sends into
   WARP in the first place. Confirmed live: a route existing here without also being in this list is
   silently never used — no error, the traffic just goes direct and fails.
5. **Add a Gateway DNS Resolver Policy** (Zero Trust → Gateway → Firewall Policies → DNS, or
   Resolver Policies depending on dashboard version) so queries for `lab.example.com` resolve via
   `10.0.10.12` (Pi-hole) instead of Cloudflare's own default Gateway resolver — otherwise every
   `*.lab.example.com` hostname returns NXDOMAIN over this connection even once routing itself works.
6. **Add a Unifi firewall rule**: `VLAN 20 (K8s) → 10.0.10.12, port 53 (DNS), Allow` — same
   narrow-rule pattern as the existing table in
   [docs/network.md](../../../../docs/network.md)'s "Network Policies". Without this, the DNS
   query leaves `cloudflared`'s pod (effectively VLAN 20) but the router drops it before it reaches
   Pi-hole, since VLAN 20 → VLAN 10 currently only allows DHCP/TFTP ports (67/68/69).
7. **Restart the tunnel deployment** after changing `warp-routing` (config isn't hot-reloaded, see
   [Common tasks](#common-tasks) below):
   ```bash
   kubectl rollout restart deployment/cloudflare-tunnel -n cloudflare-tunnel
   ```

**Verify it works:** `warp-cli settings` should show all three CIDRs under "Include mode" — if any
are missing there, that's the most common silent failure (see point 4 above), regardless of what
`cloudflared tunnel route ip show` says. Once confirmed, with WARP connected in Gateway mode:
`talosctl -n 10.0.20.11 version` (VLAN 20), `curl https://10.0.40.100` (VLAN 40, expect a
`404` from ingress-nginx's default backend if hit without a matching Host header — that's success,
not failure), and `curl https://grafana.lab.example.com` (needs steps 5+6 above too) should all work
from anywhere with internet access, no LAN/prior VPN required. `ping`/ICMP will never work through
this path — Cloudflare Tunnel's WARP routing only proxies TCP/UDP — that's expected, not a sign
something's broken.

## Common tasks

**Add a new publicly-exposed hostname:** add an `ingress:` entry to `cloudflared-configmap.yaml`
(same `service`/`originServerName` pattern as the existing ones), create the matching Cloudflare
DNS CNAME record (see docs/external-dependencies.md), and **restart the deployment** —
`cloudflared` reads its config file once at startup and does not hot-reload it on a `ConfigMap`
change:
```bash
kubectl rollout restart deployment/cloudflare-tunnel -n cloudflare-tunnel
```

**Check the tunnel is connected:**
```bash
kubectl logs -n cloudflare-tunnel -l app=cloudflare-tunnel
```
