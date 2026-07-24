# Talos Machine Configuration

Raw Talos config for the 4 bare-metal nodes — the OS/machine layer *underneath* Kubernetes.
**None of this is applied by Flux.** Everything else in `clusters/talos-dev/` is a Flux
`Kustomization` target reconciled automatically on push; this folder is the one exception. Talos
machine config is applied by hand, from a client machine, via `talosctl` — there's no
`kustomization.yaml` here and nothing in this folder is referenced by
`clusters/talos-dev/kustomization.yaml`. These files are committed purely so a from-scratch
rebuild is reproducible, not because anything reads them automatically.

For the actual step-by-step commands (`talosctl gen config`, `apply-config`, bootstrap), see the
root README's ["Cluster Deployment"](../../../README.md) section — this file explains *why each
file here exists*, not the deployment walkthrough itself.

## Why these files and not others

`talosctl gen config` produces `controlplane.yaml`, `worker.yaml`, and `talosconfig` — these are
**not** committed (see the root `.gitignore`): they're regenerated locally each time and contain
cluster secrets/certs. What *is* committed are the **patches** layered on top of that generated
config (via `--config-patch`, `-p`, or `talosctl patch machineconfig`) — those are the only inputs
that are both reproducible and safe to store in git.

## Files

### `schematic.yaml`

Added 2026-07-20 (`bda06b1`, "added talos additional longhorn configurations"). Defines the
[Talos Image Factory](https://factory.talos.dev/) customization — currently the `iscsi-tools` and
`util-linux-tools` system extensions, which Longhorn needs on the host OS for iSCSI-based volume
attachment. This is the *input* recipe: POST it to the Factory to get back a schematic ID:

```bash
curl -X POST --data-binary @schematic.yaml https://factory.talos.dev/schematics
```

That ID is what turns into an installer image reference (`factory.talos.dev/installer/<id>:<talos-version>`),
used both for the initial PXE boot (`booter_compose.yaml`'s `--schematic-id`, see the root README)
and for `talosctl upgrade` on existing nodes. **If you ever edit `schematic.yaml`, you need to
regenerate the schematic ID and update the upgrade commands below** — the ID is a hash of the
customization content, not something you pick.

### `README.md` (this file)

Further down, this file keeps the *resolved output* of the above: the current schematic ID, the
Factory URL, and the ready-to-run `talosctl upgrade` command for each node. It's a cache of what
`schematic.yaml` last produced — regenerate and update it together whenever the extensions list
changes.

### `longhorn-patch.yaml`

Added alongside `schematic.yaml` in the same commit (`bda06b1`, 2026-07-20). A machine-config patch
applied live to already-running nodes:

```bash
talosctl patch machineconfig --patch @longhorn-patch.yaml -n <node-ip>
```

- Loads the `iscsi_tcp` kernel module (Longhorn's iSCSI-based volume attach/detach needs it at
  runtime, in addition to the Factory extension above which only gets the *tooling* onto the
  image).
- Bind-mounts `/var/lib/longhorn` so Longhorn's data path survives independently of the ephemeral
  Talos root filesystem.
- Sets `vm.max_map_count: 262144` — a standard prerequisite for storage engines that mmap large
  numbers of regions (Longhorn's engine included).

Applies to every node that runs Longhorn workloads — i.e. all 4.

### `config/cni-patch.yaml`

Added 2026-07-20 (`86bd054`, "add host configuration to GIT"). Applied once, at initial
`talosctl gen config --config-patch @cni-patch.yaml` time (documented in the root README). Disables
the default Flannel CNI and kube-proxy (`cni.name: none`, `proxy.disabled: true`) since Cilium
replaces both, and enables scheduling pods on control-plane nodes — needed here since this cluster
only has one worker node.

### `config/cp-01.yaml`, `config/cp-02.yaml`, `config/cp-03.yaml`, `config/wrkr-01.yaml`

Added 2026-07-20 (`86bd054`), refined over several follow-up commits the same day (VLAN 40/50
interfaces added, `vlanID` → `vlanId` key fix). One file per node, applied as `talosctl
apply-config -p @<file>.yaml` alongside `cni-patch.yaml`. Each sets:

- Static hostname and a static IP on the VLAN 20 (cluster) interface, with the shared `.10` VIP on
  the 3 control-plane files only (`wrkr-01.yaml` has no `vip:` block — only control planes serve
  the API).
- VLAN 40 (ingress/services) and VLAN 50 (storage) sub-interfaces, matching the VLAN design in the
  root README.
- `machine.install.disk` / `wipe: true` — where the OS gets installed on first boot.

That last part used to live in a separate shared `disk-patch.yaml`. It was deleted and folded
directly into each node's own file on 2026-07-22 (`6fe78a0`, "cleanup config files") — see
[Known drift](#known-drift-worth-fixing) below, since the root README's deployment commands still
reference the old file.

### `config/metrics-patch.yaml`

Added 2026-07-21 (`5ed1634`, "Add Talos patch exposing control-plane component metrics"). Applied
live, control planes only:

```bash
talosctl patch machineconfig --patch @metrics-patch.yaml -n <cp-node-ip>
```

followed by a reboot of each control plane (etcd's `listen-metrics-urls` only takes effect after a
restart, unlike the static-pod bind-address changes). Widens `kube-scheduler` and
`kube-controller-manager` to bind `0.0.0.0` instead of loopback-only, and adds etcd's dedicated
unauthenticated metrics listener (safe by design — read-only `/metrics` and `/health`, no access to
etcd's client/peer API). This is what lets `kube-prometheus-stack` scrape control-plane component
metrics.

### `config/current-values.yaml`

**Not actually a Talos machine config** — it doesn't have a `machine:`/`cluster:` top-level key at
all. It's a snapshot of the Cilium Helm values as they were right after the manual bootstrap
install (`helm install cilium ...`, see the root README's Cilium section) — `cgroup`, `hubble`,
`ipam`, `k8sServiceHost`/`k8sServicePort`, `kubeProxyReplacement`, `securityContext`, matching the
early fields of `networking/cilium/helmrelease.yaml` almost verbatim. It's kept here purely as a
reference of what was actually running before Flux took over reconciling Cilium and expanded on
these values (Hubble UI, ServiceMonitors, L2 announcements, etc. were added later, in Flux, not
here). Nothing applies this file — it was briefly deleted as clutter and put back the same evening
(`6fe78a0` → `9857dcb`, both 2026-07-22), so treat it as intentional, historical reference rather
than something to keep in sync going forward.

## Current resolved schematic

Output of the Factory API call described above, for the `schematic.yaml` currently in this folder
(Talos `v1.13.6`, `iscsi-tools` + `util-linux-tools`):

```
https://factory.talos.dev/?arch=amd64&platform=metal&schematic-id=613e1592b2da41ae5e265e8789429f22e121aab91cb4deb6bc3c0b6262961245&target=metal&version=1.13.6

Schema ID: 613e1592b2da41ae5e265e8789429f22e121aab91cb4deb6bc3c0b6262961245

talosctl upgrade --nodes 10.0.20.11 --image factory.talos.dev/installer/613e1592b2da41ae5e265e8789429f22e121aab91cb4deb6bc3c0b6262961245:v1.13.6
talosctl upgrade --nodes 10.0.20.12 --image factory.talos.dev/installer/613e1592b2da41ae5e265e8789429f22e121aab91cb4deb6bc3c0b6262961245:v1.13.6
talosctl upgrade --nodes 10.0.20.13 --image factory.talos.dev/installer/613e1592b2da41ae5e265e8789429f22e121aab91cb4deb6bc3c0b6262961245:v1.13.6
talosctl upgrade --nodes 10.0.20.21 --image factory.talos.dev/installer/613e1592b2da41ae5e265e8789429f22e121aab91cb4deb6bc3c0b6262961245:v1.13.6
```

## Backing up and restoring etcd

Lower priority than the sealed-secrets key or the DNS/NAS items in
[docs/external-dependencies.md](../../../docs/external-dependencies.md) — almost everything etcd
holds (every Deployment/Service/HelmRelease/etc.) is already reproducible by letting Flux
reconcile this repo fresh against a new etcd. Where this actually helps is a *narrower* failure
mode: etcd itself gets corrupted or lost (e.g. a disk issue on the control-plane nodes) while the
nodes, Longhorn volumes, and everything else are still intact — restoring a snapshot there is much
faster than re-provisioning from scratch and waiting for Flux + every Helm chart to reconverge.

**This is now automated** — `backup/cluster-backup`'s `CronJob` takes a snapshot every night at
`01:00` and writes it onto a Longhorn-backed PVC, which then rides Longhorn's own nightly NAS
backup (see that folder's README for the full design). What follows is the manual, one-off version
of the same command, for ad-hoc use between scheduled runs.

**Take a snapshot**, from a client machine, against any healthy control-plane node (all 3 hold
identical etcd data):
```bash
talosctl -n 10.0.20.11 etcd snapshot db.snapshot
```
Store the snapshot file outside the cluster; **do not commit it to git** (it's a raw dump of every
Kubernetes object, including live Secret contents in plaintext — far more sensitive than the
encrypted `SealedSecret`s this repo actually tracks).

**Restore**, only after confirming etcd itself (not just one node) is actually broken —
`talosctl -n <cp-ip> service etcd` and `talosctl -n <cp-ip1>,<cp-ip2>,<cp-ip3> get machinetype`
first:
```bash
# Wipe the ephemeral partition on the control-plane node you're recovering onto:
talosctl -n 10.0.20.11 reset --graceful=false --reboot --system-labels-to-wipe=EPHEMERAL

# Once etcd shows "Preparing" again on that node, bootstrap from the snapshot:
talosctl -n 10.0.20.11 bootstrap --recover-from=./db.snapshot
```
The other control-plane nodes (`10.0.20.12`, `10.0.20.13`) rejoin the recovered etcd
automatically. Add `--recover-skip-hash-check` only if the snapshot was copied directly out of
etcd's data directory (`talosctl cp`) rather than taken via `etcd snapshot` above.

This does **not** cover: Longhorn volume *data* (separate NFS backup job, see
`storage/longhorn/README.md`), the sealed-secrets decryption key (separate, see
`security/sealed-secrets/README.md`), or this cluster's own PKI/machine secrets — as noted above,
`controlplane.yaml`/`worker.yaml`/`talosconfig` are regenerated locally and never committed, so
there's currently no backup of those either if you want to restore the exact same cluster identity
rather than bootstrap a new one.

## Resolved drift

The root README's ["Cluster Deployment"](../../../README.md) section used to show
`-p @disk-patch.yaml` in every `talosctl apply-config` example, left over from before that file was
folded into each `config/cp-0X.yaml` / `config/wrkr-01.yaml` on 2026-07-22. Those commands have
since been updated to drop the stale flag (and a `taloscctl` typo on the CP-03 command was fixed
along the way).
