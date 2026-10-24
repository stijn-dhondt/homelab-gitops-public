# Longhorn

Distributed block storage backed by local disk on each node — the cluster's only storage backend
and its default `StorageClass` (`persistence.defaultClass: true`). Every app in this repo (n8n,
WordPress, Authentik's Postgres, Forgejo, Grafana/Prometheus/Alertmanager/Loki) still names
`longhorn` or `longhorn-single-replica` explicitly.

Until 2026-10-23 the default was `zfs-nfs`, from democratic-csi (ZFS datasets on the NAS over NFS).
No volume ever used it, and it couldn't provision because of a broken driver config, so it was
removed along with its NAS dataset. It's still in git history if NAS-backed volumes are wanted again.

Each Longhorn volume keeps 3 replicas across nodes (`replicaAutoBalance: best-effort`) — each of
the 4 nodes has roughly 90-100GB of local disk available for this, so even several apps each with
a handful of GB has plenty of headroom. `allowVolumeExpansion` is on, so growing a volume later is
online/non-disruptive — every `apps/*/README.md`'s "grow the storage" section relies on this.

## Files in this folder

| File | Purpose |
|------|---------|
| `namespace.yaml` | Creates the `longhorn-system` namespace. |
| `helmrepository.yaml` | The `longhorn` chart from `https://charts.longhorn.io`. |
| `helmrelease.yaml` | Data path, replica auto-balancing, the NFS backup target, `allowRecurringJobWhileVolumeDetached` (see below), and `persistence.defaultClass: true` (see above). |
| `recurringjob-nightly.yaml` | A `RecurringJob` — nightly backup at 02:00, 14 days retention, 2 concurrent. Applies to volumes in the `default` group (Longhorn's implicit group every volume belongs to unless configured otherwise). |
| `recurringjob-trim.yaml` | A `RecurringJob` — nightly filesystem trim at 03:00 (after the backup), 2 concurrent. Same `default` group as the backup job. Can't reclaim space held by the backup's snapshot unless the volume allows it — see "Backup snapshots keep deleted blocks" below. |
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

That attach only happens for snapshot and backup jobs. `nightly-trim` needs the filesystem mounted
by a workload, so on a detached volume it fails with `Action [trimFilesystem] not available` — and
since Longhorn 1.13 one failed volume fails the whole `nightly-trim` Job and fires `KubeJobFailed`.
That happened every night from 2026-10-06 to 2026-10-24 because of `cluster-backup-data`. A volume
that's detached most of the time should therefore leave the `default` group: label its PVC with
`recurring-job.longhorn.io/source: enabled` plus only the jobs it needs (e.g.
`recurring-job.longhorn.io/nightly-backup: enabled`) — with the `source` label, the PVC's
recurring-job labels replace the volume's own. See `backup/cluster-backup/pvc.yaml`.

## Backup snapshots keep deleted blocks

Every `nightly-backup` run takes a Longhorn snapshot first and keeps it on the volume as the base
for the next incremental backup; each night's snapshot is merged into the previous one. Longhorn
works on blocks, not files, so that snapshot holds on to every block the filesystem has ever
written, including ones whose files were since deleted. `nightly-trim` only punches holes in the
part written after the snapshot: with the global `remove-snapshots-during-filesystem-trim: false`
it may not touch snapshots.

For most volumes this barely matters. For a write-heavy volume that constantly rewrites and deletes
its own files it does: Prometheus's TSDB compaction touches nearly every block, so on 2026-10-23
its 35Gi volume used **39.8GB on disk for ~23GB of actual data** (one 37GB snapshot plus the newest
writes). Compare Longhorn's `status.actualSize` against kubelet's
`kubelet_volume_stats_used_bytes` to spot this:
```bash
kubectl -n longhorn-system get volumes.longhorn.io <pv-name> -o jsonpath='{.status.actualSize}'
```

Fix, applied live to the Prometheus volume only (`pvc-bc0f8e6a-…`), not in git — Longhorn creates
`Volume` objects itself, Flux doesn't manage them:
```bash
kubectl -n longhorn-system patch volumes.longhorn.io <pv-name> --type merge \
  -p '{"spec":{"unmapMarkSnapChainRemoved":"enabled"}}'
```
The 03:00 trim then removes the snapshot and hands the freed blocks back. Tradeoff: with its base
snapshot gone, the next backup has to read the whole volume instead of only changed blocks. Not set
globally or on `longhorn-single-replica`, so volumes where this doesn't pay off keep cheap
incremental backups (and StorageClass parameters are immutable anyway). If the Prometheus PVC is
ever recreated, patch the new volume again.

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

## Longhorn doesn't auto-grow volumes (issue #44)

`allowVolumeExpansion: true` only makes a **manual** size increase resize online/non-disruptively
— nothing watches usage and grows a volume on its own. This isn't a Longhorn gap specifically,
virtually no Kubernetes CSI driver does this; capacity planning is on the operator. Hit repeatedly
with Prometheus's own storage (`monitoring/kube-prometheus-stack/helmrelease.yaml`) — `5Gi → 10Gi`
on 2026-07-25, then `10Gi → 20Gi` on 2026-08-08, then `20Gi → 35Gi` on 2026-09-11, each caught by
manually checking usage rather than any alert (see that README's "Grow Prometheus's storage" for
the mechanism). Any volume with `retention`/data that grows unbounded over time (Prometheus, Loki,
MariaDB) will need this again — don't assume a one-time fix.

Worth noting: kube-prometheus-stack ships `KubePersistentVolumeFillingUp` by default, which should
warn before a volume actually fills. It likely already fired every time above — but until
2026-09-11, Alertmanager's only configured receiver in this cluster was `"null"` (no Slack/email/
webhook route in git), so every alert went nowhere. Fixed in issue #45: Alertmanager now emails
real notifications — see that README's "Check whether an alert will actually reach anyone" for the
mechanism and how to send a manual test alert.

## The NAS backup share needs manual permissions (not in git)

Longhorn's backup pods run as root; NFS `root_squash` (the default) maps root to an
anonymous/unprivileged user that can't create the `backupstore` directory on first backup. See
[docs/external-dependencies.md](../../../../docs/external-dependencies.md) for the exact fix
(`no_root_squash`, or permissive `777` folder permissions). Without it, backups fail silently — invisible from `kubectl` alone, since the
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
