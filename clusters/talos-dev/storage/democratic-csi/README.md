# democratic-csi

Dynamic PersistentVolume provisioning backed by ZFS datasets over NFS on the NAS
(`10.0.50.100`). Each PV gets its own ZFS dataset with quota enforcement — this is the
`zfs-nfs` `StorageClass`, and the **default** one in this cluster (Longhorn is the other option,
used where local block storage makes more sense — see `storage/longhorn/README.md`).

## NAS prerequisites (not in git)

```bash
zfs create Talos/k8s
zfs create Talos/k8s-snapshots
# Enable NFS server in OMV: Services → NFS → Enable
```

## Files in this folder

| File | Purpose |
|------|---------|
| `namespace.yaml` | Creates the `democratic-csi` namespace. Needs `pod-security.kubernetes.io/enforce: privileged` — see the gotcha below. |
| `helmrepository.yaml` | The `democratic-csi` chart. |
| `helmrelease.yaml` | The CSI driver config — 4 node pods (one per cluster node), 15m timeout (see gotcha below). |
| `driver-config-sealed.yaml` | A `SealedSecret` holding the driver's connection config (NAS SSH credentials, ZFS dataset paths, NFS share options) — see [Secrets](#secrets) below. |

> **Gotcha:** The `democratic-csi` namespace needs `pod-security.kubernetes.io/enforce: privileged`
> — CSI node drivers require `SYS_ADMIN`, hostPath volumes, `hostNetwork`, and `hostIPC`, all
> blocked by the default `baseline` policy.

> **Gotcha:** The default Flux `HelmRelease` timeout (5m) isn't enough for 4 node pods to pull
> images and start. Set `spec.timeout: 15m`.

> **Gotcha:** If the `HelmRelease` gets stuck in a failed state after fixing an issue:
> ```bash
> flux suspend helmrelease democratic-csi -n democratic-csi
> helm uninstall democratic-csi -n democratic-csi
> flux resume helmrelease democratic-csi -n democratic-csi
> ```

## Secrets

**Driver credentials** (not stored in git — create manually, then seal):
```bash
kubectl create secret generic democratic-csi-driver-config \
  --namespace democratic-csi \
  --from-literal=driver-config-file.yaml='
driver: zfs-generic-nfs
sshConnection:
  host: "10.0.50.100"
  port: 22
  username: "root"
  password: "<password>"
zfs:
  datasetParentName: "Talos/k8s"
  detachedSnapshotsDatasetParentName: "Talos/k8s-snapshots"
  datasetEnableQuotas: true
  datasetEnableReservation: false
  datasetPermissionsMode: "0777"
  datasetPermissionsUser: 0
  datasetPermissionsGroup: 0
nfs:
  shareStrategy: "setDatasetProperties"
  shareStrategySetDatasetProperties:
    properties:
      sharenfs: "rw=@10.0.20.0/24,no_root_squash"
  shareHost: "10.0.50.100"
' \
  --dry-run=client -o yaml | \
kubeseal --controller-namespace sealed-secrets --controller-name sealed-secrets-controller --format yaml \
  > clusters/talos-dev/storage/democratic-csi/driver-config-sealed.yaml
```

After Flux applies the new `SealedSecret`, restart the controller once — democratic-csi only reads
its config at startup:
```bash
kubectl -n democratic-csi rollout restart deployment democratic-csi-controller
```

> **Gotcha:** `zfs-generic-nfs` shares each dataset by setting its ZFS `sharenfs` property, so the
> `nfs:` block needs `shareStrategy: setDatasetProperties` **and** the
> `shareStrategySetDatasetProperties.properties` map. Without that map every `CreateVolume` fails
> with `TypeError: Cannot read properties of undefined (reading 'properties')` and the PVC stays
> `Pending` — found 2026-10-23 on the first real `zfs-nfs` PVC; until then no volume in the cluster
> had used this class. The older `shareAlldirs`/`shareAllowedHosts`/`shareOptions` keys belong to
> the FreeNAS/TrueNAS drivers and are ignored here. `rw=@10.0.20.0/24` limits the export to the
> cluster VLAN; `no_root_squash` is needed because kubelet runs as root when it applies a pod's
> `fsGroup` (e.g. Prometheus's) to the volume. A failed attempt can leave its dataset behind on
> the NAS (`Talos/k8s/pvc-<uid>`) — remove it there with `zfs destroy`.

## Common tasks

**Verify provisioning:**
```bash
kubectl get storageclass
kubectl get pods -n democratic-csi
```

**Test a PV:**
```bash
kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-nfs-pvc
  namespace: default
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: zfs-nfs
  resources:
    requests:
      storage: 100Mi
EOF
```
