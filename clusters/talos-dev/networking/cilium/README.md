# Cilium

CNI + kube-proxy replacement + LoadBalancer IPAM + Hubble observability, all in one chart. Every
pod's networking depends on this, and every `LoadBalancer` Service (most importantly
ingress-nginx) gets its IP from here.

## Why this is bootstrapped manually, then handed to Flux

Cilium can't be installed by Flux itself — no CNI means no pods can schedule, which means Flux
can't run either (chicken-and-egg). It's installed once by hand
(see [docs/cluster-bootstrap.md](../../../../docs/cluster-bootstrap.md)) with a deliberately
minimal set of values, then this folder's `HelmRelease` takes over every subsequent change —
that's where Hubble, LB IPAM interaction, ServiceMonitors, and L2 announcements are actually
configured, not in the one-time bootstrap command.

> **Gotcha:** `k8sServiceHost` must be `localhost` and port `7445` for Talos. Using the control
> plane VIP (`10.0.20.10:6443`) breaks Cilium bootstrap entirely.

## Files in this folder

| File | Purpose |
|------|---------|
| `helmrepository.yaml` | The `cilium` chart from `https://helm.cilium.io`. |
| `helmrelease.yaml` | The full ongoing config — kube-proxy replacement, IPAM mode, Hubble (UI + Relay, with metrics and ServiceMonitors), L2 announcements, Prometheus/operator metrics. |
| `ippool.yaml` | `CiliumLoadBalancerIPPool` — hands out `10.0.40.100`-`10.0.40.200` to `LoadBalancer` Services. |
| `l2announcement.yaml` | `CiliumL2AnnouncementPolicy` — announces those IPs via ARP on `enp1s0.40` (the VLAN 40 sub-interface), so they're actually reachable on the LAN. |
| `ingress.yaml` | Hubble UI's own `Ingress` (`hubble.lab.example.com`) — see the authentik README for why it also has forward-auth annotations. |
| `authentik-auth-headers-configmap.yaml`, `authentik-outpost-service.yaml` | Forward-auth plumbing shared with every protected app — see `apps/authentik/README.md`'s "How apps get protected". |
| `authentik-bypass-api-ingress.yaml` | A deliberate, documented exception: Hubble UI's own streaming API (`/api/control-stream`, `/api/service-map-stream`) bypasses the auth gate, because its gRPC-Web client doesn't send the session cookie the way normal page loads do. See the authentik README for the full story. |
| `grafana-dashboard-cilium-agent-configmap.yaml` | Cilium's own data-plane/control-plane dashboard ([grafana.com #21431](https://grafana.com/grafana/dashboards/21431-cilium-metrics/), sourced from the `cilium/cilium` repo's `v1.19` branch to match this cluster's chart version). |
| `grafana-dashboard-hubble-configmap.yaml` | Hubble flow-observability dashboard (same repo/branch, `hubble-dashboard.json`) — complements the live Hubble UI with historical trends. |

Both auto-loaded by Grafana's sidecar — see `monitoring/kube-prometheus-stack/README.md` for how
that mechanism works and how to update either.

## Common tasks

**Check IPAM/L2 announcements are working:**
```bash
kubectl get ciliumloadbalancerippool
kubectl get ciliuml2announcementpolicy
kubectl get svc -n ingress-nginx   # should show EXTERNAL-IP: 10.0.40.100
```

**Verify Cilium/Hubble health:**
```bash
cilium status --wait
cilium connectivity test
```

**Change the bootstrap-vs-Flux-managed split:** if a value needs to move from the manual
`helm install` into the committed chart (or vice versa), remember the manual command only needs to
cover the bare minimum to get pods scheduling — everything else belongs in `helmrelease.yaml` so a
rebuild reproduces it without hand-typing flags.
