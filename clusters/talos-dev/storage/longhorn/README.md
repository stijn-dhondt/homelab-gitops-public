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
| `helmrelease.yaml` | Data path, replica auto-balancing, the NFS backup target, `allowRecurringJobWhileVolumeDetached` (see below), and the deliberate `persistence.defaultClass: false` (see above). |
| `recurringjob-nightly.yaml` | A `RecurringJob` — nightly backup at 02:00, 14 days retention, 2 concurrent. Applies to volumes in the `default` group (Longhorn's implicit group every volume belongs to unless configured otherwise). |
| `recurringjob-trim.yaml` | A `RecurringJob` — nightly filesystem trim at 03:00 (after the backup), 2 concurrent. Same `default` group as the backup job. |
| `ingress.yaml` | Longhorn's own UI, at `longhorn.lab.example.com` — forward-auth annotations, see the authentik README's "How apps get protected". |
| `authentik-auth-headers-configmap.yaml`, `authentik-outpost-service.yaml` | Forward-auth plumbing shared with every protected app. |
| `servicemonitor.yaml` | Prometheus scrape config for Longhorn's own metrics. |
| `grafana-dashboard-configmap.yaml` | Volume health/replica status/disk usage per PV — the dashboard Longhorn's own docs recommend ([grafana.com #17626](https://grafana.com/grafana/dashboards/17626)). Auto-loaded by Grafana's sidecar, see `monitoring/kube-prometheus-stack/README.md`. |
| `networkpolicy-allow-prometheus.yaml` | Lets Prometheus (in `monitoring`) reach `longhorn-manager`'s metrics port — see below (issue #43). |

## Detached volumes need `allowRecurringJobWhileVolumeDetached`

A volume with no running workload attached to it (e.g. a PVC only ever mounted by a `CronJob` pod
that has already completed, like `cluster-backup-data` — see `backup/cluster-backup/README.md`) is
**detached** most of the time. By default a Longhorn `RecurringJob` (`nightly-backup` or
`nightly-trim`) silently skips detached volumes instead of attaching them — no error, no event, the
`RecurringJob` object looks fine, the volume just never gets backed up or trimmed (issue #15).
`helmrelease.yaml` sets `allowRecurringJobWhileVolumeDetached: true` globally so any
currently-detached volume gets attached just long enough for its scheduled job, then detached
again.

## The chart's default NetworkPolicy blocks Prometheus (issue #43)

The Longhorn chart's `networkPolicies.restrictInternalTraffic` defaults to `true` — separate from,
and independent of, `networkPolicies.enabled` (defaults `false`). Neither is set in
`helmrelease.yaml`, so the chart's default silently applies: a `NetworkPolicy` named
`longhorn-manager` that only allows ingress to `longhorn-manager` pods from other same-namespace
Longhorn components. Prometheus lives in `monitoring`, so every scrape against port `9500` got
dropped by Cilium — no error on the Longhorn side, volumes/replicas/UI all looked completely
healthy, the only symptom was the Grafana dashboard going blank. A dropped `NetworkPolicy` packet
shows up in Prometheus as a scrape timeout (`context deadline exceeded`), not a connection refusal
— that's the tell that it's a policy, not the exporter itself.

`networkpolicy-allow-prometheus.yaml` adds a separate, additive `NetworkPolicy` (Kubernetes
`NetworkPolicy` objects for the same pod selector are OR'd together) allowing the `monitoring`
namespace on TCP `9500`, rather than touching or disabling the chart-managed one — a future chart
upgrade won't clobber it, and the internal restriction stays in effect for everyone else.

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
