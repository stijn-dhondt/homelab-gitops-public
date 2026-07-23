# External Dependencies (Not in Git)

_Added 2026-07-21 — things that live outside this repo and won't come back by just redeploying the
cluster from git._

## NAS: Longhorn backup share permissions

Longhorn's nightly backup job writes to `nfs://10.0.50.100:/Longhorn` (configured in
`clusters/talos-dev/storage/longhorn/helmrelease.yaml`). The NFS export itself, and specifically
its permissions, live entirely on the NAS (OMV) — not in git.

Longhorn's backup pods run as root. By default, NFS `root_squash` maps root to an
anonymous/unprivileged user, which can't create the `backupstore` directory the first time a
backup runs. On a fresh NAS, this share needs either:

- `no_root_squash` enabled on the `/Longhorn` NFS export, **or**
- permissions on the underlying folder that allow the anonymous/nobody user to write (e.g.
  `chmod 777`, matching the permissive `datasetPermissionsMode: "0777"` already used for the
  democratic-csi ZFS datasets)

Without this, every backup fails with `mkdir .../backupstore: permission denied`, and it's
invisible from `kubectl` alone — the `RecurringJob` just silently never produces a working backup.
See [clusters/talos-dev/storage/longhorn/README.md](../clusters/talos-dev/storage/longhorn/README.md).

## DNS records (Cloudflare + internal split-DNS)

None of the following are declared anywhere in this repo — they live in Cloudflare's dashboard and
the internal Pi-hole (`10.0.10.12`).

**Cloudflare (public, zone `example.com`):**

| Host | Type | Target |
|------|------|--------|
| `example.com` | CNAME | `<tunnel-id>.cfargotunnel.com` |
| `www.example.com` | CNAME | `<tunnel-id>.cfargotunnel.com` |
| `jump.example.com` | CNAME | `<tunnel-id>.cfargotunnel.com` |

`jump.example.com` is the [jumphost](../clusters/talos-dev/apps/jumphost/README.md) — the one
internal-app gateway deliberately reachable from the public internet, unlike everything under
`*.lab.example.com`. All three must stay proxied (orange cloud). As long as the same Cloudflare
Tunnel is reused (not deleted and recreated), these records keep working across a cluster
redeploy — the tunnel ID and secret live in `cloudflare-tunnel-credentials-sealed.yaml`, not in DNS.

**Internal split-DNS (Pi-hole):**

| Host | Target |
|------|--------|
| `example.com` | `10.0.40.100` |
| `grafana.lab.example.com` | `10.0.40.100` |
| `prometheus.lab.example.com` | `10.0.40.100` |
| `alertmanager.lab.example.com` | `10.0.40.100` |
| `longhorn.lab.example.com` | `10.0.40.100` |
| `n8n.lab.example.com` | `10.0.40.100` |
| `authentik.lab.example.com` | `10.0.40.100` |
| `hubble.lab.example.com` | `10.0.40.100` |

These exist purely so LAN clients hit the ingress VIP directly instead of round-tripping through
the Cloudflare tunnel. Rebuilding onto new infrastructure (new NAS, new Pi-hole instance, etc.)
means recreating all of the above by hand.
