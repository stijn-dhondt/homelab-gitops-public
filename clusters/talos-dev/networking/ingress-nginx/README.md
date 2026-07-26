# ingress-nginx

The Ingress controller every app in this cluster routes through — `*.lab.example.com`, and
`example.com`/`www.example.com` (via the Cloudflare Tunnel).

## Files in this folder

| File | Purpose |
|------|---------|
| `namespace.yaml` | Creates the `ingress-nginx` namespace. |
| `helmrepository.yaml` | The `ingress-nginx` chart from the project's own repo. |
| `helmrelease.yaml` | 2 replicas, a `LoadBalancer` Service pinned to `10.0.40.100` (the first IP in Cilium's LB IPAM pool — see `networking/cilium/README.md`), Prometheus metrics/ServiceMonitor, and pod anti-affinity so both replicas don't land on the same node. |
| `grafana-dashboard-configmap.yaml` | The official [kubernetes/ingress-nginx Grafana dashboard](https://github.com/kubernetes/ingress-nginx/blob/main/deploy/grafana/dashboards/nginx.json), request rate/latency/error-rate per ingress. See [Grafana dashboard](#grafana-dashboard) below. |

## Grafana dashboard

`grafana-dashboard-configmap.yaml` is the official
[kubernetes/ingress-nginx dashboard](https://github.com/kubernetes/ingress-nginx/blob/main/deploy/grafana/dashboards/nginx.json)
— request rate/latency/error-rate per ingress. Auto-loaded by Grafana's sidecar; see
`monitoring/kube-prometheus-stack/README.md`'s "Adding a Grafana dashboard" for how this mechanism
works in general and the exact steps to update this one.

## Common tasks

**Verify the LoadBalancer got its pinned IP:**
```bash
kubectl get svc -n ingress-nginx
```
Expected: `EXTERNAL-IP: 10.0.40.100`.

**Snippet directives are disabled on this controller** (this chart version's default, not
something explicitly set here) — `nginx.ingress.kubernetes.io/auth-snippet` and similar
annotations are rejected outright by the admission webhook:
*"Snippet directives are disabled by the Ingress administrator"*. Hit this for real while wiring
up Authentik's forward-auth — the non-snippet equivalent
(`nginx.ingress.kubernetes.io/auth-proxy-set-headers` + a small `ConfigMap`) is what every
protected app in this cluster uses instead. See `apps/authentik/README.md`'s "How apps get
protected" for the full story, including why that came with its own limitation (no
cross-namespace `ConfigMap` references).

**Debug a routing issue:**
```bash
kubectl logs -n ingress-nginx -l app.kubernetes.io/component=controller --tail=100
kubectl get ingress -A
```
