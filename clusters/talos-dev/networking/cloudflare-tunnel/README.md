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
