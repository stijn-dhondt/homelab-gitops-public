# WordPress

The public [example.com](https://example.com) site — [WordPress](https://wordpress.org/) with a
dedicated MariaDB database, deployed from the [Bitnami](https://github.com/bitnami/charts) Helm
chart, managed by Flux like every other app in this repo.

- **URL:** https://example.com (public, via the Cloudflare Tunnel — see the root README's
  ["External Dependencies"](../../../../README.md) section for the tunnel/DNS setup)
- **Redirect:** https://www.example.com → 301s to `https://example.com`
- **Namespace:** `wordpress`
- **Storage:** 4Gi (WordPress files) + 4Gi (MariaDB data), both on Longhorn

## Files in this folder

| File | Purpose |
|------|---------|
| `namespace.yaml` | Creates the `wordpress` namespace. Required in the same Kustomization as the HelmRelease — Flux won't create the namespace for a HelmRelease that targets it (see the root README's Flux gotchas). |
| `helmrepository.yaml` | Tells Flux where to pull the chart from: the `wordpress` chart from Bitnami's OCI registry (`oci://registry-1.docker.io/bitnamicharts`). This same `HelmRepository` is reused by any other Bitnami chart in the cluster. |
| `helmrelease.yaml` | The actual deployment — chart version, ingress hostname, storage, and the bundled MariaDB. This is the file you'll edit most. |
| `wordpress-credentials-sealed.yaml` | A `SealedSecret` holding the WordPress admin password. |
| `wordpress-mariadb-credentials-sealed.yaml` | A `SealedSecret` holding the MariaDB `root`, application, replication, and metrics-exporter passwords. |
| `ingress-www-redirect.yaml` | A second, standalone `Ingress` for `www.example.com` that just 301-redirects to `https://example.com`. It's separate from the chart's own ingress because the chart only manages one hostname. |
| `grafana-dashboard-configmap.yaml` | MariaDB connections/query rate/slow queries ([grafana.com #7362](https://grafana.com/grafana/dashboards/7362-mysql-overview/), Percona's popular `mysqld_exporter`-format dashboard — matches the metrics the chart's bundled exporter already produces). Auto-loaded by Grafana's sidecar, see `monitoring/kube-prometheus-stack/README.md`. |
| `mariadb-mcp-loadbalancer.yaml` | A `LoadBalancer` Service exposing MariaDB directly (`10.0.40.102:3306`) via a read-only `mcp_readonly` user, for the `mariadb` Claude Code MCP integration — see `docs/claude-code-mcp.md`. |
| `kustomization.yaml` | Lists all the files above so Flux applies them together. Referenced from `clusters/talos-dev/kustomization.yaml`. |

## How it fits together

1. Flux reconciles `clusters/talos-dev/kustomization.yaml`, which includes this folder.
2. The `HelmRepository` (`helmrepository.yaml`) makes the `wordpress` chart available to Flux.
3. The `HelmRelease` (`helmrelease.yaml`) installs the chart into the `wordpress` namespace with our custom `values`, which:
   - Point WordPress at `existingSecret: wordpress-credentials` for the admin password, instead of letting the chart generate/store one in a `values`-derived Secret — keeps the actual password out of git, only the sealed (encrypted) form is committed.
   - Mount a `longhorn` PersistentVolumeClaim (4Gi) for the WordPress files (`wp-content`, uploads, etc.).
   - Enable the chart's **bundled MariaDB** (`mariadb.enabled: true`) as the database, itself backed by a separate 4Gi `longhorn` PVC, with its passwords pulled from `existingSecret: wordpress-mariadb-credentials` for the same reason as above.
   - Turn on MariaDB's Prometheus metrics exporter and `ServiceMonitor`, so it shows up in Grafana/Prometheus alongside everything else in the cluster.
   - Create an `Ingress` for `example.com` via `nginx` + `letsencrypt-production`, same pattern as every other app in this cluster.
4. `ingress-www-redirect.yaml` creates a second `Ingress` for `www.example.com` with an `nginx.ingress.kubernetes.io/permanent-redirect` annotation, so visitors to the `www` host get redirected to the bare domain instead of serving WordPress twice under two hostnames.

No manual Helm install is required — pushing to `prod` is enough. Flux reconciles every 5 minutes (`spec.interval`), or force it immediately:

```bash
flux reconcile helmrelease wordpress -n wordpress --with-source
```

## Credentials

Both `SealedSecret`s were sealed against this cluster's sealed-secrets controller — the actual
passwords are not recoverable from git, only from the live `Secret` objects in the cluster (or
wherever you originally generated/saved them).

- **Never regenerate these sealed secrets** unless you're intentionally rotating a password. Since
  MariaDB stores its own copy of these passwords at first boot, changing `wordpress-mariadb-credentials`
  after the database already exists won't actually change anything in the database — you'd need to
  update the password inside MariaDB itself (or wipe the PVC) for a rotation to take effect.
- If you ever need to check a live value (e.g. to log into `wp-admin` or connect to MariaDB directly):
  ```bash
  kubectl get secret wordpress-credentials -n wordpress -o jsonpath='{.data.wordpress-password}' | base64 -d
  kubectl get secret wordpress-mariadb-credentials -n wordpress -o jsonpath='{.data.mariadb-root-password}' | base64 -d
  ```
- The admin username is WordPress's chart default (`user`) unless overridden in `helmrelease.yaml` — check `kubectl get secret wordpress-credentials -n wordpress -o yaml` for exactly which keys are set if unsure.

## Common tasks

**Check it's running:**
```bash
kubectl get pods -n wordpress
kubectl get ingress -n wordpress
kubectl get certificate -n wordpress
```

**Grow the storage** (Longhorn's `allowVolumeExpansion` is enabled, so this is online/non-disruptive):
```yaml
# helmrelease.yaml
persistence:
  size: 8Gi          # WordPress files
mariadb:
  primary:
    persistence:
      size: 8Gi      # database
```
Push the change; Flux/Helm resizes the PVCs in place.

**Change the chart version:**
```yaml
# helmrelease.yaml
spec:
  chart:
    spec:
      version: "33.0.4"  # bump to a newer chart version
```
Check the [chart's changelog](https://github.com/bitnami/charts/tree/main/bitnami/wordpress) before bumping — a chart version bump can pull in a newer WordPress (and MariaDB) release too.

**Back up the site:** the two PVCs (`wordpress` and `data-wordpress-mariadb-0`) hold everything —
uploads/theme/plugin files and the full database. There's no separate backup job configured for
either volume today (unlike Longhorn's nightly job for other volumes) — if you need backups, either
add a Longhorn `RecurringJob` selector/label to these volumes, or use a WordPress export/plugin-based
backup.

**Debug a failed release:**
```bash
flux get helmrelease wordpress -n wordpress
kubectl describe helmrelease wordpress -n wordpress
kubectl logs -n wordpress -l app.kubernetes.io/name=wordpress
kubectl logs -n wordpress wordpress-mariadb-0 -c mariadb
```
