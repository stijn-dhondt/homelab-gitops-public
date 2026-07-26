# apps

This folder holds the actual **workloads** running on the cluster — the things a user, not the
cluster itself, cares about. Everything else under `clusters/talos-dev/` (`networking/`,
`storage/`, `monitoring/`, `security/`) exists to make this folder possible: ingress, TLS,
persistent volumes, secrets, observability. `apps/` is where that plumbing gets put to use.

## Apps

| App | README |
|-----|--------|
| [n8n](n8n/README.md) | Self-hosted workflow automation, at `n8n.lab.example.com` |
| [WordPress](wordpress/README.md) | The public `example.com` site, with a bundled MariaDB |
| [Authentik](authentik/README.md) | Identity provider / SSO, at `authentik.lab.example.com` — protects every other `*.lab.example.com` app under one shared login |
| [Forgejo](forgejo/README.md) | Self-hosted Git server, at `forgejo.lab.example.com` — deliberately not behind Authentik (would break `git clone`/`push` over HTTPS), keeps its own built-in auth |

Each app's own README explains its files, how it's wired together, and how to do common
maintenance on it (resize storage, bump versions, debug a failed release, etc.) — this file is
just the index and the shared conventions.

## Why each app gets its own folder

Every app here is a self-contained Flux `Kustomization` target, following the same shape:

- `namespace.yaml` — its own namespace. Flux needs this to exist in the *same* Kustomization as
  anything namespaced inside it (see the root README's Flux gotchas) — a HelmRelease can't create
  its own namespace before Flux tries to place it there.
- `helmrepository.yaml` — where its Helm chart comes from.
- `helmrelease.yaml` — the actual deployment: chart, version, and the values that customize it for
  this cluster (hostname, storage class/size, credentials wiring, etc.).
- `*-sealed.yaml` — any credentials the app needs, encrypted as `SealedSecret`s so they're safe to
  commit (see the root README's "Sealed Secrets" section, and the n8n README's note on why the
  encryption key is injected via `secretKeyRef` instead of the chart's own secret-values mechanism).
  Not every app needs these, and there's no fixed count — n8n needs one, WordPress needs two (app +
  database), Authentik needs three (app secret key, database, API bootstrap token).
  - `kustomization.yaml` — lists all of the above so Flux applies them as one unit.

Each app's `kustomization.yaml` is then referenced directly from
`clusters/talos-dev/kustomization.yaml` (as `apps/<name>`), which is what actually gets it
reconciled by Flux.

## Adding a new app

1. Create `apps/<name>/` with `namespace.yaml`, `helmrepository.yaml` (or reuse an existing one,
   like `bitnami` in `wordpress/helmrepository.yaml`), `helmrelease.yaml`, any sealed secrets it
   needs, and a `kustomization.yaml` listing them all.
2. Add `- apps/<name>` to `clusters/talos-dev/kustomization.yaml`.
3. If it needs a hostname, decide whether it's internal-only (`*.lab.example.com`, split-DNS only —
   see the n8n README) or public (routed through the Cloudflare Tunnel — see the WordPress README
   and the root README's DNS section).
4. Write a README for it following the n8n/WordPress ones as a template, and add it to the table
   above.
