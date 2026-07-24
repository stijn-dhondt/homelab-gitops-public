# Forgejo

[Forgejo](https://forgejo.org/) — self-hosted Git server. Deployed from the official
[forgejo-helm](https://code.forgejo.org/forgejo-helm/forgejo-helm) chart, managed by Flux like every
other app in this repo.

- **URL:** https://forgeo.lab.example.com (internal only — see the "DNS records" section of the [root README](../../../../README.md) for the split-DNS entry)
- **Namespace:** `forgejo`
- **Storage:** 10Gi on Longhorn

## Why no SSO

Every other `*.lab.example.com` app in this cluster sits behind Authentik's forward-auth gate (see
`apps/authentik/README.md`). Forgejo deliberately does **not** — that gate checks for a browser
session cookie on every request to the hostname, but `git clone`/`git push` over HTTPS (and any
other Git client) have no cookie at all. Gating the whole hostname would return every git operation
a 401/redirect-to-login instead of the actual git protocol response, breaking command-line access
entirely.

Forgejo keeps its own built-in authentication instead — users, access tokens, SSH keys — the same
way most self-hosted git servers are run in practice. If browser SSO convenience is wanted later,
the correct mechanism is Forgejo's own **OAuth2/OpenID Connect login source** (Site Administration →
Authentication Sources), pointing at a new Authentik **OAuth2 Provider** (a different provider type
than the `proxyprovider` used for every other app) — that adds a "sign in via Authentik" button on
Forgejo's own login page without touching how git-over-HTTPS/SSH authenticates. Not set up yet.

No git-over-SSH exposure either for now — only the web UI + git-over-HTTPS through the ingress.
Adding SSH later needs a new `LoadBalancer` Service (ingress-nginx can't proxy raw SSH), not just an
Ingress change.

## Files in this folder

| File | Purpose |
|------|---------|
| `namespace.yaml` | Creates the `forgejo` namespace. Required in the same Kustomization as the HelmRelease — Flux won't create the namespace for a HelmRelease that targets it (see the root README's Flux gotchas). |
| `helmrepository.yaml` | Tells Flux where to pull the chart from: the `forgejo` chart from `oci://code.forgejo.org/forgejo-helm/forgejo`. |
| `forgejo-admin-credentials-sealed.yaml` | A `SealedSecret` holding the initial admin user's `username`/`password`/`email`, consumed via `gitea.admin.existingSecret` in `helmrelease.yaml`. See [Admin credentials](#admin-credentials) below. |
| `helmrelease.yaml` | The actual deployment — chart version, ingress hostname, storage, and admin bootstrap wiring. This is the file you'll edit most. |
| `kustomization.yaml` | Lists all of the above so Flux applies them together. Referenced from `clusters/talos-dev/kustomization.yaml`. |

## How it fits together

1. Flux reconciles `clusters/talos-dev/kustomization.yaml`, which includes this folder.
2. The `HelmRepository` (`helmrepository.yaml`) makes the `forgejo` chart available to Flux.
3. The `HelmRelease` (`helmrelease.yaml`) installs the chart into the `forgejo` namespace with our
   custom `values`, which:
   - Mount a `longhorn` PersistentVolumeClaim (10Gi) for repo data, attachments, and the embedded
     SQLite database — no separate database subchart, same reasoning as n8n.
   - Set `gitea.config.server.DOMAIN`/`ROOT_URL` so Forgejo generates correct external links and
     clone URLs for `https://forgeo.lab.example.com`.
   - Create the initial admin user from `forgejo-admin-credentials` via `gitea.admin.existingSecret`,
     instead of plaintext values in this file.
   - Create an `Ingress` for `forgeo.lab.example.com` via `nginx` + `letsencrypt-production` — no
     Authentik forward-auth annotations, see [Why no SSO](#why-no-sso) above.

No manual Helm install is required — pushing to `prod` is enough. Flux reconciles every 5 minutes
(`spec.interval`), or force it immediately:

```bash
flux reconcile helmrelease forgejo -n forgejo --with-source
```

## Admin credentials

`forgejo-admin-credentials` was sealed against this cluster's sealed-secrets controller — the
actual username/password/email are not recoverable from git, only from the live `Secret` object (or
whoever was given the generated password at creation time).

**Log in and change the password immediately** if you haven't already — Site Administration → User
Accounts, or your own profile settings once logged in as `admin`.

**Retrieve the current sealed value** (only works if it hasn't been rotated since):
```bash
kubectl get secret forgejo-admin-credentials -n forgejo -o jsonpath='{.data.username}' | base64 -d; echo
kubectl get secret forgejo-admin-credentials -n forgejo -o jsonpath='{.data.password}' | base64 -d; echo
```

**Rotate it:** reseal a new `SealedSecret` following `security/sealed-secrets/README.md`'s workflow,
replace `forgejo-admin-credentials-sealed.yaml`, push. Note this only re-provisions the *initial*
admin user at first install — changing this file after the admin user already exists won't rotate
its password automatically (the bootstrap Job only runs once); change the password from inside
Forgejo itself instead, and treat this SealedSecret as historical/first-boot-only after that.

## Common tasks

**Check it's running:**
```bash
kubectl get pods -n forgejo
kubectl get ingress -n forgejo
kubectl get certificate -n forgejo
```

**Grow the storage** (Longhorn's `allowVolumeExpansion` is enabled, so this is online/non-disruptive):
```yaml
# helmrelease.yaml
persistence:
  size: 20Gi  # bump this
```
Push the change; Flux/Helm resizes the PVC in place.

**Change the chart version:** chart and app version move in lock-step for this chart (maintained by
the Forgejo project itself, like Authentik's chart) — Renovate's built-in `flux` manager already
tracks `spec.chart.spec.version` automatically, no extra `customManagers` entry needed.
```yaml
# helmrelease.yaml
spec:
  chart:
    spec:
      version: "17.1.3"  # bump to a newer chart version
```
Check the [chart's releases](https://code.forgejo.org/forgejo-helm/forgejo-helm/releases) first.

**Back up repos/data:** the PVC contains everything — repo data, attachments, and the SQLite
database. There's no separate backup job configured for this PVC today (unlike Longhorn's nightly
job for other volumes) — if you need backups, either add a Longhorn `RecurringJob` selector/label to
this volume, or use Forgejo's own repo/database export tooling.

**Debug a failed release:**
```bash
flux get helmrelease forgejo -n forgejo
kubectl describe helmrelease forgejo -n forgejo
kubectl logs -n forgejo -l app=forgejo
```
