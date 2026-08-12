# External Dependencies (Not in Git)

_Added 2026-07-21 — things that live outside this repo and won't come back by just redeploying the
cluster from git._

## Sealed-secrets encryption key

Every `*-sealed.yaml` in this repo (n8n's encryption key, Authentik's secrets, WordPress's
credentials, Forgejo's admin credentials, the Cloudflare Tunnel credentials, etc.) only decrypts
against this specific cluster's sealed-secrets keypair — which lives in the cluster itself, not in
git. Losing it without a backup means every one of those becomes permanently unrecoverable, even
though the repo still has the (encrypted) files.

Backup is now automated nightly (via
[backup/cluster-backup](../clusters/talos-dev/backup/cluster-backup/README.md), no need to remember
to re-run anything by hand. See
[security/sealed-secrets/README.md](../clusters/talos-dev/security/sealed-secrets/README.md) for
the manual/ad-hoc version of the same backup and the full restore procedure onto a new cluster.

## etcd backup

Lower priority than the other items here — see
[talos/README.md](../clusters/talos-dev/talos/README.md)'s "Backing up and restoring etcd" section
for why (most of etcd's contents are already reproducible via Flux + this repo). The backup side is
now automated (nightly, via [backup/cluster-backup](../clusters/talos-dev/backup/cluster-backup/README.md));
the restore side (`bootstrap --recover-from`) is still a manual procedure, documented in the same
`talos/README.md` section.

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

Both must stay proxied (orange cloud). As long as the same Cloudflare Tunnel is reused (not deleted
and recreated), these records keep working across a cluster redeploy — the tunnel ID and secret
live in `cloudflare-tunnel-credentials-sealed.yaml`, not in DNS.

No other hostname under `example.com` should be publicly proxied — every internal admin UI is
`*.lab.example.com`-only (see the internal split-DNS table below) and reachable exclusively via
Cloudflare WARP (see `networking/cloudflare-tunnel/README.md`'s "Remote access via Cloudflare
WARP"), never through a public DNS record. A public-facing jumphost app used to be a third
exception here (removed from this repo — see git history if it reappears), and a couple of
non-cluster services (NAS admin UI, an IPAM tool) had public CNAMEs added directly in Cloudflare's
dashboard outside of git, which is exactly why they weren't caught sooner — those have since been
removed from the zone too, but nothing here would have flagged them since they were never declared
in this file to begin with.

**Internal split-DNS (Pi-hole):**

`*.lab.example.com` is a single wildcard record pointing at `10.0.40.100` (the ingress VIP) —
confirmed live with `dig`. It covers every `*.lab.example.com` hostname, including any added later
without a DNS change. The hosts actually in use today:

| Host | Target |
|------|--------|
| `example.com` | `10.0.40.100` |
| `grafana.lab.example.com` | `10.0.40.100` |
| `grafana-mcp.lab.example.com` | `10.0.40.100` |
| `prometheus.lab.example.com` | `10.0.40.100` |
| `alertmanager.lab.example.com` | `10.0.40.100` |
| `longhorn.lab.example.com` | `10.0.40.100` |
| `n8n.lab.example.com` | `10.0.40.100` |
| `authentik.lab.example.com` | `10.0.40.100` |
| `hubble.lab.example.com` | `10.0.40.100` |
| `forgejo.lab.example.com` | `10.0.40.100` |

`example.com` itself is a separate, non-wildcard entry (the bare domain isn't covered by a
`*.lab.example.com` wildcard). These exist purely so LAN clients hit the ingress VIP directly instead
of round-tripping through the Cloudflare tunnel. Rebuilding onto new infrastructure (new NAS, new
Pi-hole instance, etc.) means recreating the wildcard record (and the bare-domain one) by hand —
the per-host table above is for reference, not something to recreate entry-by-entry.
