# n8n

[n8n](https://n8n.io/) — self-hosted workflow automation. Deployed via the community
[8gears/n8n-helm-chart](https://github.com/8gears/n8n-helm-chart), managed by Flux like
every other app in this repo.

- **URL:** https://n8n.lab.example.com (internal only — see the "DNS records" section of the [root README](../../../../README.md) for the split-DNS entry)
- **Namespace:** `n8n`
- **Storage:** 5Gi on Longhorn

## Files in this folder

| File | Purpose |
|------|---------|
| `namespace.yaml` | Creates the `n8n` namespace. Required in the same Kustomization as the HelmRelease — Flux won't create the namespace for a HelmRelease that targets it (see the root README's Flux gotchas). |
| `helmrepository.yaml` | Tells Flux where to pull the chart from: the `n8n` chart from `oci://8gears.container-registry.com/library`. |
| `helmrelease.yaml` | The actual deployment — chart version, ingress hostname, storage, and app config. This is the file you'll edit most. |
| `n8n-encryption-key-sealed.yaml` | A `SealedSecret` holding `N8N_ENCRYPTION_KEY`. See [Encryption key](#encryption-key-important) below — **do not delete or regenerate this casually**. |
| `authentik-auth-headers-configmap.yaml`, `authentik-outpost-service.yaml`, `authentik-outpost-ingress.yaml` | Forward-auth plumbing shared with every protected app — see `apps/authentik/README.md`'s "How apps get protected". |
| `n8n-api-bypass-ingress.yaml` | A deliberate, documented exception: n8n's `/api` path bypasses Authentik's forward-auth gate so token-based API clients (e.g. the `n8n-mcp` Claude Code integration) can authenticate with n8n's own API key instead of a browser session cookie. See [docs/claude-code-mcp.md](../../../../docs/claude-code-mcp.md). |
| `kustomization.yaml` | Lists all the files above so Flux applies them together. Referenced from `clusters/talos-dev/kustomization.yaml`. |

## How it fits together

1. Flux reconciles `clusters/talos-dev/kustomization.yaml`, which includes this folder.
2. The `HelmRepository` (`helmrepository.yaml`) makes the `n8n` chart available to Flux.
3. The `HelmRelease` (`helmrelease.yaml`) installs the chart into the `n8n` namespace with our custom `values`, which:
   - Set `N8N_HOST` / `N8N_PROTOCOL` (via `main.config.n8n`) so n8n generates correct external URLs (webhooks, OAuth callbacks) for `https://n8n.lab.example.com`, even though the container itself only ever speaks plain HTTP on port `5678` — TLS is terminated at the ingress-nginx controller.
   - Set `GENERIC_TIMEZONE` so cron/schedule-trigger nodes fire at the expected local time.
   - Mount a `longhorn` PersistentVolumeClaim at `/home/node/.n8n`, which holds the SQLite database (workflows, credentials, execution history) and any binary data written to disk.
   - Inject `N8N_ENCRYPTION_KEY` from the `SealedSecret` as an environment variable, instead of using the chart's built-in `main.secret` (which would store the value in this file, in plaintext, in git).
4. The chart's `ingress.yaml` template creates an `Ingress` for `n8n.lab.example.com`, annotated so `cert-manager` requests a Let's Encrypt certificate via `letsencrypt-production`, gated behind Authentik's forward-auth (same `auth-url`/`auth-signin` pattern as every other app — see `apps/authentik/README.md`'s "How apps get protected"), and stores the cert in the `n8n-tls` secret.
5. `n8n-api-bypass-ingress.yaml` creates a second `Ingress`, same host, just the `/api` path, with no Authentik annotations — so the `n8n-mcp` Claude Code integration can reach n8n's API using its own API key, without needing to complete Authentik's cookie-based login flow.

No manual Helm install is required — pushing to `prod` is enough. Flux reconciles every 5 minutes (`spec.interval`), or force it immediately:

```bash
flux reconcile helmrelease n8n -n n8n --with-source
```

## Keeping n8n up to date

There are **two independent version numbers** in play here, and Renovate has to track them
separately:

- `spec.chart.spec.version` in `helmrelease.yaml` — the **Helm chart** version, published by the
  8gears chart maintainers. Renovate's built-in `flux` manager (configured in the root
  `renovate.json`) already watches this automatically, same as every other HelmRelease in this repo.
- `values.image.tag` — the **n8n application** version itself. The chart bundles a default via its
  own `appVersion`, but that default lags badly: chart `2.0.1` (published Dec 2025) still points at
  n8n `1.122.4`, while upstream n8n had already shipped past `2.x` seven months later. Renovate has
  no visibility into a chart's internal `appVersion` — it only ever tracks the chart version field —
  so without an explicit override, n8n would stay frozen at whatever the chart last happened to
  bundle, indefinitely.

The fix: `values.image.tag` is pinned explicitly in `helmrelease.yaml`, with a
`# renovate:` comment above it (same pattern as `clusters/talos-dev/talos-version.yaml`) that a
matching `customManagers` entry in the root `renovate.json` picks up. That entry tells Renovate to
check `n8nio/n8n` on Docker Hub directly, using `semver-coerced` versioning so it ranks clean
release tags (`2.31.5`) above architecture-suffixed (`2.31.5-arm64`) or commit-suffixed
(`2.31.5-aa3d214`) variants of the same release, and ignores non-version channel tags (`latest`,
`next`, `beta`, `nightly`) entirely.

**Known trade-off:** n8n publishes plain numeric Docker tags (e.g. `2.32.0`, `2.32.1`, `2.32.2`)
somewhat ahead of when that same version gets promoted to the `latest`/`stable` tags and an official
GitHub release. `semver-coerced` versioning can't tell "published" apart from "officially
promoted" — so a Renovate PR might occasionally propose a version slightly ahead of what n8n itself
calls current-stable. Check https://github.com/n8n-io/n8n/releases (non-prerelease, tagged `n8n@x.y.z`)
if a PR looks newer than expected before merging.

## Encryption key (important)

n8n uses `N8N_ENCRYPTION_KEY` to encrypt credentials (API keys, passwords, etc.) stored in its database. It was generated once and sealed against this cluster's sealed-secrets controller — it is **not** derivable from git, only from the live `SealedSecret` object.

- If you lose the volume **and** this key together, any saved credentials in a database backup become unreadable — you'd have to re-enter them by hand. The workflows themselves are unaffected.
- **Never regenerate `n8n-encryption-key-sealed.yaml`** unless you're intentionally starting fresh (e.g. wiping the PVC too). Changing the key while the old volume still exists will make n8n unable to decrypt existing stored credentials on next start.
- The key only decrypts inside the `n8n` namespace on this cluster's sealed-secrets controller (same scoping as every other `SealedSecret` in this repo — see the "Sealed Secrets — Secret Management" section of the [root README](../../../../README.md)).

## Common tasks

**Check it's running:**
```bash
kubectl get pods -n n8n
kubectl get ingress -n n8n
kubectl get certificate -n n8n
```

**Grow the storage** (Longhorn's `allowVolumeExpansion` is enabled, so this is online/non-disruptive):
```yaml
# helmrelease.yaml
main:
  persistence:
    size: 10Gi  # bump this
```
Push the change; Flux/Helm resizes the PVC in place.

**Change the chart version:**
```yaml
# helmrelease.yaml
spec:
  chart:
    spec:
      version: "2.1.1"  # bump to a newer chart version
```
Check the [chart's changelog](https://github.com/8gears/n8n-helm-chart/releases) first — this is a
separate version from n8n itself (see below), and Renovate already opens a PR for this
automatically via the built-in `flux` manager.

**Change the n8n version:**
```yaml
# helmrelease.yaml (under values:)
image:
  # renovate: datasource=docker depName=n8nio/n8n versioning=semver-coerced
  tag: "2.37.6"
```
Renovate opens a PR for this one too — see [Keeping n8n up to date](#keeping-n8n-up-to-date) above for why it needs its own tracking.

**Back up workflows:** the PVC (`/home/node/.n8n`) contains the SQLite DB with everything — workflows, credentials, execution history. There's no separate backup job configured for this PVC today (unlike Longhorn's nightly job for other volumes) — if you need backups, either add a Longhorn `RecurringJob` selector/label to this volume, or use n8n's own workflow export.

**Debug a failed release:**
```bash
flux get helmrelease n8n -n n8n
kubectl describe helmrelease n8n -n n8n
kubectl logs -n n8n -l app.kubernetes.io/name=n8n
```
