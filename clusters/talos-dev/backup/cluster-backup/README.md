# Cluster backup (etcd snapshot + sealed-secrets key)

Automates two backups that used to be fully manual — an etcd snapshot and an export of the
sealed-secrets controller's signing key(s) — by writing both onto a small Longhorn-backed PVC every
night. Since it's a plain `longhorn`-class volume, it's automatically covered by the existing
`nightly-backup` Longhorn `RecurringJob` (`storage/longhorn`) — no separate NAS wiring, no new
retention logic here. That job already backs up every Longhorn volume in the cluster nightly with
14 days of history; this volume just rides along.

- **Namespace:** `cluster-backup`
- **Storage:** 2Gi on Longhorn (an etcd snapshot on this cluster is ~85MB; plenty of headroom)
- **Schedule:** `01:00` daily — an hour before Longhorn's own `02:00` nightly backup run

## Why no encryption

Deliberate choice, not an oversight: these files ride through the exact same trust boundary every
other Longhorn-backed volume already uses unencrypted on the way to the NAS (Authentik's real
Postgres DB, WordPress's DB, etc.). Adding a separate encryption layer just for this volume would
mean managing yet another key (where does *that* live?) for a boundary already implicitly trusted
by everything else backed up the same way.

## Files in this folder

| File | Purpose |
|------|---------|
| `namespace.yaml` | Creates the `cluster-backup` namespace. |
| `pvc.yaml` | The `longhorn`-class PVC both backup steps write into. |
| `talos-backup-credentials-sealed.yaml` | A `SealedSecret` holding a **restricted** `talosconfig` — role `os:etcd:backup` only, which per Talos's own RBAC "only allows the `etcd snapshot` API call." Minted once via `talosctl config new --roles=os:etcd:backup`, completely separate from the admin `talosconfig` used for everyday cluster work (that one is never committed — see `talos/README.md`). |
| `serviceaccount.yaml` | `ServiceAccount` the `CronJob` runs as. |
| `sealed-secrets-reader-role.yaml`, `sealed-secrets-reader-rolebinding.yaml` | **Live in the `sealed-secrets` namespace** (explicit `metadata.namespace`, even though the files sit in this folder) — grant that `ServiceAccount` read-only `get`/`list` on `Secrets` there, and only there. Least privilege: this job can read the sealed-secrets controller's own keys, nothing else in the cluster. |
| `cronjob.yaml` | The actual job — an `initContainer` (`talosctl`) takes the etcd snapshot, then the main container (`kubectl`) exports the sealed-secrets key(s), both writing fixed filenames onto the shared PVC. |
| `kustomization.yaml` | Lists all of the above. |

## How it fits together

1. Flux reconciles `clusters/talos-dev/kustomization.yaml`, which includes this folder.
2. Every night at `01:00`, the `CronJob` spins up a pod that:
   - Runs `talosctl etcd snapshot` against a control-plane node (`10.0.20.11`), using the
     restricted `talosconfig` — writes `/backup/db.snapshot`.
   - Runs `kubectl get secret -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml`, capturing
     *every* current signing key (the label selector matches all of them, including older ones kept
     around after rotation) — writes `/backup/sealed-secrets-key-backup.yaml`.
3. Both files overwrite the previous night's copy — this volume only ever holds the *latest* backup.
4. An hour later, Longhorn's `nightly-backup` job snapshots this volume to the NAS along with every
   other volume, giving 14 days of distinct historical recovery points even though the live files
   themselves are just "latest."

## Retrieving a backup

**Live copy (fastest, works as long as the cluster itself is healthy):**
```bash
kubectl run cluster-backup-access --rm -it --image=busybox --restart=Never \
  --overrides='{"spec":{"containers":[{"name":"cluster-backup-access","image":"busybox","command":["sh"],"stdin":true,"tty":true,"volumeMounts":[{"name":"backup","mountPath":"/backup"}]}],"volumes":[{"name":"backup","persistentVolumeClaim":{"claimName":"cluster-backup-data"}}]}}' \
  -n cluster-backup
# then, inside the shell: cat /backup/db.snapshot, cat /backup/sealed-secrets-key-backup.yaml
```

**From a historical NAS backup (actual disaster recovery — cluster is gone/rebuilt):** restore the
`cluster-backup-data` volume from Longhorn's backup store onto the new cluster (Longhorn UI or a
`Volume.spec.fromBackup` restore, same as any other volume), then read the files from it the same
way. See `storage/longhorn/README.md` for the general restore flow, and
`talos/README.md`/`security/sealed-secrets/README.md` for what to actually *do* with the recovered
etcd snapshot / sealed-secrets key once you have them.

## Rotating the restricted talosconfig

Not expected to need this often, but if it's ever compromised or you want a fresh one:
```bash
talosctl config new etcd-backup-talosconfig.yaml --roles=os:etcd:backup
kubectl create secret generic talos-backup-credentials \
  --namespace cluster-backup \
  --from-file=talosconfig=etcd-backup-talosconfig.yaml \
  --dry-run=client -o yaml | \
kubeseal --controller-namespace sealed-secrets --controller-name sealed-secrets-controller \
  --format yaml > talos-backup-credentials-sealed.yaml
rm etcd-backup-talosconfig.yaml   # never leave the plaintext lying around
```
Replace the file in this folder, push. The old certificate keeps working until it naturally expires
unless separately revoked — Talos RBAC certs don't have a built-in revocation list, so treat this as
"issue a new one, retire the old talosconfig file" rather than an urgent rotation.

## Common tasks

**Check it's running:**
```bash
kubectl get pods -n cluster-backup
kubectl get cronjob -n cluster-backup
```

**Trigger a run right now instead of waiting for 01:00:**
```bash
kubectl create job -n cluster-backup --from=cronjob/cluster-backup manual-test-1
kubectl logs -n cluster-backup job/manual-test-1 -c etcd-snapshot
kubectl logs -n cluster-backup job/manual-test-1 -c sealed-secrets-key-export
```

**Debug a failed run:**
```bash
kubectl get jobs -n cluster-backup
kubectl describe job -n cluster-backup <job-name>
```
A `PermissionDenied` from the `etcd-snapshot` container almost always means the restricted
talosconfig's role scoping — it can *only* call `etcd snapshot`, by design; nothing else.
