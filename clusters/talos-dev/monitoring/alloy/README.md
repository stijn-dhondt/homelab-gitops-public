# Grafana Alloy (pod logs → Loki)

DaemonSet that tails every container log under `/var/log/pods` on each node (control planes
included) and pushes it to the `loki` release in this namespace. It replaced Promtail, which reached
end of life upstream in early 2026 and no longer gets releases (so Renovate could never bump it).

## Labels

The pipeline in `helmrelease.yaml` is a 1:1 port of the promtail 6.17.1 chart's default
`kubernetes-pods` job, so every stream keeps the labels Grafana queries and dashboards use:

| Label | Value |
|---|---|
| `namespace`, `pod`, `container`, `node_name` | from the pod |
| `app` | `app.kubernetes.io/name` → `app` label → controller name (hash stripped) → pod name |
| `instance` | `app.kubernetes.io/instance` → `instance` label |
| `component` | `app.kubernetes.io/component` → `component` label |
| `job` | `<namespace>/<app>` |
| `filename` | the log file path |
| `stream` | `stdout` / `stderr` (from the CRI line) |

Loki adds `service_name` itself on ingest. If you add a label here, check Loki's stream cardinality —
don't label per-request values.

## Operations

- **Tail positions** are stored on the host at `/var/lib/alloy` (hostPath), so a pod restart resumes
  where it left off.
- **Alloy UI / pipeline debug:** `kubectl -n monitoring port-forward ds/alloy 12345` →
  <http://localhost:12345> shows each component's health and the targets it discovered.
- **Check it's shipping:** in Grafana Explore → Loki, `{namespace="monitoring", app="alloy"}`, or
  `count by (node_name) (rate({job=~".+"}[5m]))` should show all four nodes.

## Promtail cutover notes

On the first rollout Alloy has no positions file, so it reads each existing log file from the start.
Lines Promtail already shipped are either dropped by Loki as exact duplicates (same timestamp, line
and labels) or rejected as "entry too far behind" for streams that moved on more than an hour ago —
expect a burst of those warnings in the Alloy logs right after the switch; they're harmless.
Promtail's old `/run/promtail` positions directory is on tmpfs and disappears on the next node reboot.
