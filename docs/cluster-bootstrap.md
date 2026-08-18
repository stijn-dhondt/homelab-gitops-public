# Cluster Bootstrap

The one-time runbook to go from bare-metal nodes freshly PXE-booted (see
[pxe-boot.md](pxe-boot.md)) into a running cluster with Flux in control. Everything after this
point is managed from git — this is the manual, before-GitOps-exists part.

## Tools

These tools are used on the management Mac:

### Homebrew

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

### Talosctl

Official CLI for Talos Linux management:
```bash
brew install siderolabs/tap/talosctl
```

### Kubectl

```bash
brew install kubectl
```

### Helm

```bash
brew install helm
```

### Cilium CLI

Optional but recommended for CNI management:
```bash
brew install cilium-cli
```

### Kubeseal

CLI for encrypting secrets into `SealedSecret` objects managed by the Sealed Secrets controller:
```bash
brew install kubeseal
```

## Step 1: Create Per-Node Configuration Files

The committed patch files already exist in
[clusters/talos-dev/talos/](../clusters/talos-dev/talos/) — see that folder's README for what each
one is and why. For a from-scratch rebuild, reuse them as-is rather than recreating manually:
`config/cni-patch.yaml`, `config/cp-01.yaml`, `config/cp-02.yaml`, `config/cp-03.yaml`,
`config/wrkr-01.yaml`.

## Step 2: Create Cluster Configs

```bash
talosctl gen config my-cluster https://10.0.20.10:6443 \
  --config-patch @clusters/talos-dev/talos/config/cni-patch.yaml \
  --talos-version v1.13.6 \
  --install-image factory.talos.dev/installer/<schematic-id>:v1.13.6 \
  --force
```

Use the schematic ID from [clusters/talos-dev/talos/README.md](../clusters/talos-dev/talos/README.md)
("Current resolved schematic"), not a placeholder.

This creates `controlplane.yaml`, `worker.yaml`, and `talosconfig` — **none of these are
committed** (see the root `.gitignore`), they're regenerated locally each time and contain cluster
secrets/certs.

Configure context:
```bash
talosctl config merge ./talosconfig
talosctl config context my-cluster
talosctl config info                                                  # verify it exists
talosctl config endpoint 10.0.20.11 10.0.20.12 10.0.20.13
talosctl config node 10.0.20.11
```

## Step 3: Apply Configuration to Each Node

```bash
talosctl apply-config -n 10.0.20.11 --insecure -f controlplane.yaml -p @clusters/talos-dev/talos/config/cp-01.yaml
talosctl apply-config -n 10.0.20.12 --insecure -f controlplane.yaml -p @clusters/talos-dev/talos/config/cp-02.yaml
talosctl apply-config -n 10.0.20.13 --insecure -f controlplane.yaml -p @clusters/talos-dev/talos/config/cp-03.yaml
talosctl bootstrap
talosctl apply-config -n 10.0.20.21 --insecure -f worker.yaml -p @clusters/talos-dev/talos/config/wrkr-01.yaml
```

Fetch a fresh kubeconfig and verify:
```bash
talosctl kubeconfig --nodes 10.0.20.10 --force
kubectl get nodes
```

Expected:
```
NAME      STATUS   ROLES           AGE   VERSION
cp-01     Ready    control-plane   66m   v1.36.0
cp-02     Ready    control-plane   66m   v1.36.0
cp-03     Ready    control-plane   66m   v1.36.0
wrkr-01   Ready    <none>          51m   v1.36.0
```

## Step 4: Bootstrap Cilium (manually, once)

Cilium must be installed manually before Flux bootstraps — chicken-and-egg: no CNI means no pods
can schedule, which means Flux can't run either.

```bash
helm install cilium cilium/cilium \
  --version 1.20.0 \
  --namespace kube-system \
  --set kubeProxyReplacement=true \
  --set k8sServiceHost=localhost \
  --set k8sServicePort=7445 \
  --set cgroup.autoMount.enabled=false \
  --set cgroup.hostRoot=/sys/fs/cgroup \
  --set securityContext.capabilities.ciliumAgent="{CHOWN,KILL,NET_ADMIN,NET_RAW,IPC_LOCK,SYS_ADMIN,SYS_RESOURCE,DAC_OVERRIDE,FOWNER,SETGID,SETUID}" \
  --set securityContext.capabilities.cleanCiliumState="{NET_ADMIN,SYS_ADMIN,SYS_RESOURCE}"
```

This is deliberately minimal — just enough for CNI + pod networking to come up. Hubble, LB IPAM,
L2 announcements, ServiceMonitors etc. are **not** set here; they're configured by the committed
`HelmRelease` (`clusters/talos-dev/networking/cilium/helmrelease.yaml`) that Flux applies right
after this bootstrap step takes over. See
[clusters/talos-dev/networking/cilium/README.md](../clusters/talos-dev/networking/cilium/README.md)
for that ongoing config.

> **Note:** `k8sServiceHost` must be `localhost` and port `7445` for Talos. Using the VIP
> (`10.0.20.10:6443`) breaks Cilium bootstrap.

Check the status:
```bash
cilium status --wait
```

Expected:
```
    /¯¯\
 /¯¯\__/¯¯\    Cilium:             OK
 \__/¯¯\__/    Operator:           OK
 /¯¯\__/¯¯\    Envoy DaemonSet:    OK
 \__/¯¯\__/    Hubble Relay:       OK
    \__/       ClusterMesh:        disabled

DaemonSet              cilium                   Desired: 4, Ready: 4/4, Available: 4/4
DaemonSet              cilium-envoy             Desired: 4, Ready: 4/4, Available: 4/4
Deployment             cilium-operator          Desired: 2, Ready: 2/2, Available: 2/2
Cluster Pods:          4/4 managed by Cilium
```

## Step 5: Bootstrap Flux

Bootstrapped with HTTPS (PAT-based) to avoid port 22 outbound restrictions:

```bash
flux bootstrap github \
  --owner=stijn-dhondt \
  --repository=homelab-gitops \
  --branch=prod \
  --path=clusters/talos-dev \
  --personal \
  --token-auth \
  --components-extra=image-reflector-controller,image-automation-controller
```

> **Gotcha:** `flux bootstrap github` without `--token-auth` creates an SSH-based `GitRepository`
> (`ssh://`). The cluster cannot reach GitHub on port 22, causing `context deadline exceeded` on
> reconciliation. Always use `--token-auth`.

> **Gotcha:** Every `HelmRelease` that lives in its own namespace requires a `namespace.yaml` in
> the same Kustomization. Flux cannot place a namespaced resource if the namespace doesn't exist
> yet. `createNamespace: true` in the `HelmRelease` only works during Helm install, not when Flux
> applies the `HelmRelease` resource itself.

After this, Flux owns every subsequent config change and upgrade — everything in
`clusters/talos-dev/` reconciles automatically on push to `prod`.

## Post-Deployment Validation

```bash
# Reboot cluster
talosctl reboot -n 10.0.20.11,10.0.20.12,10.0.20.13,10.0.20.21
# Wait for nodes to come online (~2-3 minutes)

talosctl status
talosctl nodes
cilium status --wait

# Clean up any failed pods
kubectl delete pods -n kube-system --field-selector status.phase=Failed
```

## Deployment Checklist

- [ ] Unifi VLANs configured (10, 20, 30, 40, 50)
- [ ] Firewall rules applied
- [ ] PXE boot server running on NAS
- [ ] Test VLAN connectivity
- [ ] Verify cluster connectivity: `talosctl status`
- [ ] Check Talos nodes: `talosctl nodes`
- [ ] Verify all 3 control planes online
- [ ] Verify Cilium pod network: `cilium status`
- [ ] Verify CNI pods: `kubectl get pods -n kube-system`
- [ ] Bootstrap Flux (Step 5 above)
- [ ] Deploy sample workload to test cluster
- [ ] Configure ingress for external access (VLAN 40)
- [ ] Stop PXE boot server once Talos is deployed
