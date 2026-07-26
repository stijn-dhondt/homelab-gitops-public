# Longhorn

Distributed block storage backed by local disk on each node — the `longhorn` `StorageClass` every
app in this repo uses when it explicitly asks for it (n8n, WordPress, Authentik's Postgres,
Grafana/Prometheus/Alertmanager). **Not** the cluster's default
`StorageClass` — that's `zfs-nfs` via democratic-csi (see `storage/democratic-csi/README.md`);
Longhorn is used where local block storage makes more sense than NFS.

Each Longhorn volume keeps 3 replicas across nodes (`replicaAutoBalance: best-effort`) — each of
the 4 nodes has roughly 90-100GB of local disk available for this, so even several apps each with
a handful of GB has plenty of headroom. `allowVolumeExpansion` is on, so growing a volume later is
online/non-disruptive — every `apps/*/README.md`'s "grow the storage" section relies on this.

## Files in this folder

| File | Purpose |
|------|---------|
| `namespace.yaml` | Creates the `longhorn-system` namespace. |
| `helmrepository.yaml` | The `longhorn` chart from `https://charts.longhorn.io`. |
| `helmrelease.yaml` | Data path, replica auto-balancing, the NFS backup target, and the deliberate `persistence.defaultClass: false` (see above). |
| `recurringjob-nightly.yaml` | A `RecurringJob` — nightly backup at 02:00, 14 days retention, 2 concurrent. Applies to volumes in the `default` group (Longhorn's implicit group every volume belongs to unless configured otherwise). |
| `ingress.yaml` | Longhorn's own UI, at `longhorn.lab.example.com` — forward-auth annotations, see the authentik README's "How apps get protected". |
| `authentik-auth-headers-configmap.yaml`, `authentik-outpost-service.yaml` | Forward-auth plumbing shared with every protected app. |
| `servicemonitor.yaml` | Prometheus scrape config for Longhorn's own metrics. |
| `grafana-dashboard-configmap.yaml` | Volume health/replica status/disk usage per PV — the dashboard Longhorn's own docs recommend ([grafana.com #17626](https://grafana.com/grafana/dashboards/17626)). Auto-loaded by Grafana's sidecar, see `monitoring/kube-prometheus-stack/README.md`. |

## The NAS backup share needs manual permissions (not in git)

Longhorn's backup pods run as root; NFS `root_squash` (the default) maps root to an
anonymous/unprivileged user that can't create the `backupstore` directory on first backup. See
[docs/external-dependencies.md](../../../../docs/external-dependencies.md) for the exact fix
(`no_root_squash`, or permissive folder permissions matching the ZFS datasets used by
democratic-csi). Without it, backups fail silently — invisible from `kubectl` alone, since the
`RecurringJob` object itself looks fine.

## Common tasks

**Check node storage capacity:**
```bash
kubectl get nodes.longhorn.io -n longhorn-system -o json | \
  jq '.items[] | {name: .metadata.name, disks: .status.diskStatus}'
```

**Check volume/replica health:**
```bash
kubectl get volumes.longhorn.io -n longhorn-system
kubectl get replicas.longhorn.io -n longhorn-system
```

**Check backup history:**
```bash
kubectl get backups.longhorn.io -n longhorn-system
```

**Grow a volume** — covered per-app in each `apps/*/README.md`, but the mechanism is always the
same: bump the `size` in the relevant `HelmRelease`/PVC spec and push; Longhorn resizes online.
