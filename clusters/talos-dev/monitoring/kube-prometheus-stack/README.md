# kube-prometheus-stack

Prometheus, Grafana, Alertmanager, and the standard Kubernetes metrics/rules bundle, deployed from
the [prometheus-community](https://github.com/prometheus-community/helm-charts) chart. See
`helmrelease.yaml`'s comments for the ingress/auth/storage details of each component — this file
covers one specific, reused-elsewhere mechanism: how Grafana dashboards get into this cluster.

## How dashboards get loaded

This chart runs a sidecar container (`grafana-sc-dashboard`) alongside Grafana that watches for
`ConfigMap`s labeled `grafana_dashboard: "1"` **in any namespace** (`NAMESPACE=ALL`, confirmed via
`kubectl get deploy kube-prometheus-stack-grafana -o json` — not restricted to `monitoring`) and
loads their content straight into Grafana. No Grafana UI import, no separate dashboard-provisioning
step — a dashboard is just a git-committed `ConfigMap`, same "everything reproducible from git"
principle as every other resource in this repo.

**Convention used throughout this repo:** each dashboard `ConfigMap` lives in the folder of the
component it visualizes, not dumped into this one — `networking/ingress-nginx/`,
`networking/cert-manager/`, `networking/cilium/` (Cilium + Hubble), `storage/longhorn/`, and
`apps/wordpress/` (its bundled MariaDB) each carry their own `grafana-dashboard*-configmap.yaml`.
That keeps a dashboard's lifecycle tied to the thing it monitors — deleting an app's folder deletes
its dashboard too, instead of leaving an orphaned entry in a central `monitoring/dashboards/` pile.

## The datasource-UID gotcha

Dashboards downloaded from grafana.com or a project's own repo almost always reference their
datasource as a template variable — `${DS_PROMETHEUS}` or `${datasource}` — meant to be resolved by
Grafana's *manual import* wizard (which asks "which datasource should this use?"). The sidecar
loading mechanism used here has no such wizard, so an unresolved template variable shows every
panel as "Datasource not found" instead of actual data.

Fix: this cluster's Prometheus datasource has a **fixed, non-random UID** — literally the string
`prometheus` (confirmed via `kubectl get configmap kube-prometheus-stack-grafana-datasource -n monitoring -o yaml`,
also `isDefault: true`). Every dashboard `ConfigMap` in this repo has had `${DS_PROMETHEUS}` /
`${datasource}` replaced with the literal string `prometheus` throughout, and any now-unused
`datasource`-type `templating.list` entries stripped, before being committed — so panels render
immediately with no manual datasource selection.

## Adding a Grafana dashboard

1. Get the dashboard JSON — prefer the project's own repo over a random grafana.com upload if one
   exists (e.g. `kubernetes/ingress-nginx`'s own `deploy/grafana/dashboards/nginx.json`), otherwise
   `curl -sL -o dashboard.json "https://grafana.com/api/dashboards/<id>/revisions/latest/download"`.
2. Patch the datasource references — a one-off Python snippet is more reliable than `sed` for this
   (handles both `${DS_PROMETHEUS}` and `${datasource}`, and strips the now-dead template variable):
   ```python
   import json
   with open("dashboard.json") as f:
       text = f.read()
   text = text.replace("${DS_PROMETHEUS}", "prometheus").replace("${datasource}", "prometheus")
   data = json.loads(text)
   if "templating" in data:
       data["templating"]["list"] = [v for v in data["templating"]["list"] if v.get("type") != "datasource"]
   data.pop("id", None)  # avoid colliding with an existing dashboard's numeric ID
   with open("dashboard.json", "w") as f:
       json.dump(data, f)
   ```
3. Wrap it as a labeled `ConfigMap`, in the owning component's namespace and folder:
   ```bash
   kubectl create configmap grafana-dashboard-<name> \
     --namespace <component-namespace> \
     --from-file=dashboard.json \
     --dry-run=client -o yaml > clusters/talos-dev/<component-folder>/grafana-dashboard-configmap.yaml
   ```
   Then add `labels: {grafana_dashboard: "1"}` under `metadata` by hand (`kubectl create configmap`
   doesn't have a flag for labels) — copy the exact placement from any existing
   `grafana-dashboard*-configmap.yaml` in this repo.
4. Add the new file to that folder's `kustomization.yaml`, push.

## Common tasks

**Check the dashboard sidecar picked up a new/changed ConfigMap:**
```bash
kubectl logs -n monitoring -l app.kubernetes.io/name=grafana -c grafana-sc-dashboard --tail=50
```

**List every dashboard ConfigMap currently in the cluster:**
```bash
kubectl get configmap -A -l grafana_dashboard=1
```
