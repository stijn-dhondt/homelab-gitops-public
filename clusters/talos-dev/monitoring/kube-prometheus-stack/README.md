# kube-prometheus-stack

Prometheus, Grafana, Alertmanager, and the standard Kubernetes metrics/rules bundle, deployed from
the [prometheus-community](https://github.com/prometheus-community/helm-charts) chart. See
`helmrelease.yaml`'s comments for the ingress/auth/storage details of each component — this file
covers two reused-elsewhere mechanisms: how Grafana dashboards get into this cluster, and how
API clients reach Grafana without going through Authentik.

## Grafana's API bypass ingress

`grafana-api-bypass-ingress.yaml` — same pattern and reasoning as
`networking/cilium/authentik-bypass-api-ingress.yaml` (Hubble UI's streaming API): a second
`Ingress` on `grafana.lab.example.com`, just the `/api` path, with no Authentik forward-auth
annotations. Needed because token-authenticated API clients (e.g. a Grafana MCP server using a
service account token) can't complete Authentik's cookie-based login flow — nginx's `auth_request`
sees no session cookie and redirects into the login page instead of proxying the request, which no
API client can follow. Narrower than Hubble's bypass, though: this only removes the *Authentik*
layer, Grafana's own auth (service account token, basic auth) still gates every request that
reaches `/api` here.

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
datasource as a template variable — `${DS_PROMETHEUS}`, `${datasource}`, or **a dashboard-specific
name** like the Longhorn dashboard's `${DS_PROMETHEUS-LONGHORN}` — meant to be resolved by Grafana's
*manual import* wizard (which asks "which datasource should this use?"). The sidecar loading
mechanism used here has no such wizard, so an unresolved template variable renders every panel with
no data at all (not an error, just silently empty) instead of the real numbers.

**Caught this for real:** the Longhorn dashboard shipped exactly like this — every panel silently
empty despite the underlying `longhorn_*` metrics being live in Prometheus the whole time (verified
directly against the Prometheus API before suspecting the dashboard itself). The other four
dashboards added at the same time all happened to use the two common placeholder names; Longhorn's
didn't, so a substitution script only checking for those two missed it. **Don't assume the
placeholder name — grep the actual downloaded JSON for `${` before deciding it's clean:**
```bash
grep -o '"\${[^}]*}"' dashboard.json | sort -u
```

Fix: this cluster's Prometheus datasource has a **fixed, non-random UID** — literally the string
`prometheus` (confirmed via `kubectl get configmap kube-prometheus-stack-grafana-datasource -n monitoring -o yaml`,
also `isDefault: true`). Every dashboard `ConfigMap` in this repo has had every such placeholder
replaced with the literal string `prometheus` throughout, and any now-unused `datasource`-type
`templating.list` entries stripped, before being committed — so panels render immediately with no
manual datasource selection.

## Adding a Grafana dashboard

1. Get the dashboard JSON — prefer the project's own repo over a random grafana.com upload if one
   exists (e.g. `kubernetes/ingress-nginx`'s own `deploy/grafana/dashboards/nginx.json`), otherwise
   `curl -sL -o dashboard.json "https://grafana.com/api/dashboards/<id>/revisions/latest/download"`.
2. **First, check what the placeholder is actually called** — don't assume it's one of the two
   common names:
   ```bash
   grep -o '"\${[^}]*}"' dashboard.json | sort -u
   ```
   Then patch every name it finds (a one-off Python snippet is more reliable than `sed` for this):
   ```python
   import json, re
   with open("dashboard.json") as f:
       text = f.read()
   # Replace every ${...} placeholder found above, not just the common ${DS_PROMETHEUS}/${datasource} ones -
   # confirm with the grep command first, add any others this dashboard uses.
   text = re.sub(r'\$\{DS_PROMETHEUS[^}]*\}', 'prometheus', text)
   text = text.replace("${datasource}", "prometheus")
   data = json.loads(text)
   if "templating" in data:
       data["templating"]["list"] = [v for v in data["templating"]["list"] if v.get("type") != "datasource"]
   data.pop("id", None)  # avoid colliding with an existing dashboard's numeric ID
   with open("dashboard.json", "w") as f:
       json.dump(data, f)
   ```
   **Verify it actually worked before wrapping it as a ConfigMap** — re-run the grep from step 2;
   zero output means clean:
   ```bash
   grep -o '"\${[^}]*}"' dashboard.json | sort -u   # should print nothing
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

**Check Prometheus's actual disk usage** — don't rely on the Longhorn dashboard's "Volume Capacity"
panel for this; its accounting hasn't been verified against real per-PVC used/total bytes. Use
kubelet's own volume stats instead, the same source `df` would show:
```promql
kubelet_volume_stats_used_bytes{persistentvolumeclaim=~"prometheus-.*"}
kubelet_volume_stats_capacity_bytes{persistentvolumeclaim=~"prometheus-.*"}
```

**Grow Prometheus's storage** (Longhorn's `allowVolumeExpansion` is enabled, so this is
online/non-disruptive) — grown from 5Gi to 10Gi on 2026-07-25, then 10Gi to 20Gi on 2026-08-08,
both times after kubelet reported usage climbing past ~70%:
```yaml
# helmrelease.yaml, under prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.resources.requests
storage: 20Gi  # bump this
```
Push the change; Flux/Helm resizes the PVC in place. Worth revisiting if usage keeps climbing —
`retention: 31d` means it grows continuously with scrape target count/cardinality, not something
that plateaus on its own. This isn't a one-off — Longhorn has no auto-grow feature at all, this
volume will need manual growth again; see `storage/longhorn/README.md`'s "Longhorn doesn't
auto-grow volumes" (issue #44) for why, and why no alert warns about it yet either (issue #45 —
Alertmanager's only receiver is `"null"`).
