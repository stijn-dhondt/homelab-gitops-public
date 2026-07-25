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
else is Cloudflare **account-level** configuration — not reproducible from git, same category as the
tunnel's own credentials (see [Setting up the tunnel](#setting-up-the-tunnel-not-in-git) above):

1. **Zero Trust must be enabled** on the Cloudflare account (free tier, up to 50 users) — the
   Zero Trust dashboard prompts for this on first visit if not already done.
2. **Register the private network routes** against this tunnel, either via the Zero Trust dashboard
   (Networks → Tunnels → this tunnel → Private Network → Add a route) or the CLI (needs
   `cloudflared tunnel login` against this account first):
   ```bash
   cloudflared tunnel route ip add 10.0.20.0/24 <tunnel-name-or-UUID>
   cloudflared tunnel route ip add 10.0.40.0/24 <tunnel-name-or-UUID>
   ```
3. **Set up at least one Access policy** (Zero Trust → Access → Policies) — WARP client
   enrollment requires an identity/authentication method (e.g. one-time PIN to your own email is
   the simplest for single-user use).
4. **Install the WARP client** on any device that needs this access, log it into this Zero Trust
   organization, and switch its mode from the default "1.1.1.1 (DNS only)" to **"Gateway with
   WARP"** — the DNS-only mode does not route any private-network traffic at all.
5. **Restart the tunnel deployment** after changing `warp-routing` (config isn't hot-reloaded, see
   [Common tasks](#common-tasks) below):
   ```bash
   kubectl rollout restart deployment/cloudflare-tunnel -n cloudflare-tunnel
   ```

**Verify it works:** with WARP connected in Gateway mode, `curl https://grafana.lab.example.com` (or
any other `*.lab.example.com` host) or `talosctl -n 10.0.20.11 version` should succeed from
anywhere with internet access, no LAN/prior VPN required.

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
