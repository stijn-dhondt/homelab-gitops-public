# Authentik

[Authentik](https://goauthentik.io/) — self-hosted identity provider / SSO. Deployed from the
official [goauthentik/helm](https://github.com/goauthentik/helm) chart, managed by Flux like every
other app in this repo.

- **URL:** https://authentik.lab.example.com (internal only — see the "DNS records" section of the [root README](../../../../README.md) for the split-DNS entry)
- **Namespace:** `authentik`
- **Storage:** 5Gi on Longhorn (PostgreSQL only — see [Storage](#storage) below)

## Why this exists

The goal is to put every app in this cluster that serves a web UI behind a single login, instead
of each having its own separate (or no) auth.

- **Protected so far:** every `*.lab.example.com` app — Grafana, Prometheus, Alertmanager, n8n,
  Longhorn UI, Hubble UI. One login (`https://authentik.lab.example.com`) covers all of them, but
  each app has its **own** Group — being logged into Authentik doesn't imply access to every app,
  see [How apps get protected](#how-apps-get-protected).
- **Adding a new one:** the ingress annotations + a small `ConfigMap` (Kubernetes side), plus a
  Group/Provider/Application/binding block in `blueprint-sso-configmap.yaml` (Authentik side) —
  see [How apps get protected](#how-apps-get-protected).
- **WordPress:** the public site (`example.com`) stays open — it's a public blog/site, not something
  to gate behind a login. `wp-admin` specifically is the one part of WordPress worth protecting;
  that's still a candidate, but it's on a different domain (`example.com`, not `*.lab.example.com`) so
  it needs its own thinking about cookie domains rather than just reusing the shared provider as-is.

## How apps get protected

Every `*.lab.example.com` app gets its **own** Group, Provider ("forward auth, single application"
mode — not "domain level"), and Application, all defined in `blueprint-sso-configmap.yaml` (see
[Files in this folder](#files-in-this-folder) below) — **not** manually via the UI — so it's
reproducible from git. All providers share `cookie_domain: lab.example.com`, so the *login itself* is
still single sign-on (one Authentik session covers every app) — it's only the per-app
*authorization* check that's separate. That's the whole point: a user can be a member of the
"Grafana Users" group without that implying access to Longhorn UI or anything else.

**An earlier version of this used one shared "domain level" Provider/Application for every app**
(per Authentik's docs, that mode means "you do not need to configure an application and provider in
authentik for each application domain") — simpler, but with only one Application object, there was
nowhere to bind a per-app Group. Switched to per-app once per-app access control was needed.

**Granting/revoking access:** add or remove the user from that app's Group — either in the
Authentik UI (Directory → Groups → `<App> Users` → Members), or by editing the group's `users` list
in `blueprint-sso-configmap.yaml` and letting it re-apply (see the discovery-schedule note below for
how to force that immediately). **`akadmin` is a member of every group** so the account that set
this up doesn't lose access to anything — remove it from specific groups if you want your daily
account to be scoped down. Confirmed by hand: being a superuser does **not** bypass group
membership checks — `akadmin` failed `check_access` on a test app the moment a group binding
existed, until added to that group.

**"All Apps Users"** is a second group bound to every application alongside its own specific one
(`policy_engine_mode: any` means either grants access) — a quick way to give one user every app at
once (e.g. for testing) without touching the per-app groups that model real access control. Every
application also has `open_in_new_tab: true`, so launching one from Authentik's app list doesn't
navigate away from it.

Protecting a *new* app needs four things — copy an existing app's setup and change the
name/hostname/slug/namespace throughout:

**1. The blueprint** — a new Group/Provider/Application/binding block in
`blueprint-sso-configmap.yaml`, and the new provider's id added to the outpost's `providers` list
at the bottom of the same file.

**2. The app's own ingress annotations** — note `auth-signin` uses **this app's own hostname**,
not `authentik.lab.example.com`:

```yaml
annotations:
  nginx.ingress.kubernetes.io/auth-url: "http://authentik-server.authentik.svc.cluster.local/outpost.goauthentik.io/auth/nginx"
  nginx.ingress.kubernetes.io/auth-signin: "https://<this-app-hostname>/outpost.goauthentik.io/start?rd=$scheme://$http_host$escaped_request_uri"
  nginx.ingress.kubernetes.io/auth-response-headers: "Set-Cookie,X-authentik-username,X-authentik-groups,X-authentik-entitlements,X-authentik-email,X-authentik-name,X-authentik-uid"
  nginx.ingress.kubernetes.io/auth-proxy-set-headers: "<same-namespace-as-this-ingress>/authentik-auth-headers"
```

**3. A small `ConfigMap`, same namespace as the ingress** (the header-forwarding one, unrelated to
the routing piece below):

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: authentik-auth-headers
  namespace: <same-namespace-as-this-ingress>
data:
  X-Forwarded-Host: "$http_host"
  X-Forwarded-Proto: "https"
```

**4. An extra ingress path + `ExternalName` Service routing `/outpost.goauthentik.io` to
Authentik** (see the "OAuth callback" gotcha below for *why*):

```yaml
apiVersion: v1
kind: Service
metadata:
  name: authentik-outpost
  namespace: <same-namespace-as-this-ingress>
spec:
  type: ExternalName
  externalName: authentik-server.authentik.svc.cluster.local
  ports:
    - port: 80
```
Then either add an `extraPaths` entry (if the app's chart supports it, like Grafana/Prometheus/
Alertmanager) pointing at that Service, or — if it doesn't (n8n's chart hardcodes every path's
backend to n8n itself) — a small standalone `Ingress` for the same host/path, which ingress-nginx
merges with the app's main ingress automatically since they share a hostname.

Non-obvious things, all found by testing against the live cluster rather than assumed from docs:

- **`auth-signin` must point at the *protected app's own* hostname, not `authentik.lab.example.com`.**
  This one caused real breakage: the outpost matches which of the 6 per-app Providers applies based
  on the Host header of the request hitting `/outpost.goauthentik.io/start` — pointing every app's
  `auth-signin` at `authentik.lab.example.com` (copied from when there was only one shared
  domain-level provider) meant the Host never matched any of the 6 app-specific providers, so
  *every* app 404'd immediately after a successful Authentik login, for every user including
  `akadmin`. Also can't just self-reference via `$scheme://$http_host` — ingress-nginx validates
  this annotation as a real URL at admission time, *before* nginx variable substitution, and errors
  with `first path segment in URL cannot contain colon` if the scheme itself is a variable. The
  hostname has to be a literal string, hence one hardcoded value per app rather than one shared
  annotation value copy-pasted everywhere.
- **The OAuth-style callback also happens on the protected app's own hostname** (this is *why*
  point 4 above exists) — `forward_single` mode's login flow redirects back to
  `https://<app-hostname>/outpost.goauthentik.io/callback?...`, which needs to actually reach
  Authentik rather than fall through to the app's own backend (which doesn't know that path and
  returns a plain 404). This is the other half of the same breakage as the point above — both had
  to be fixed together.
- **`auth-url` points at the in-cluster Service, not the public hostname.** Authentik's own docs
  call this out explicitly — pointing `auth-url` at an external URL can clobber headers on the
  internal `auth_request` sub-request nginx makes to check auth. `authentik-server.authentik.svc.cluster.local`
  is the same Service the ingress in this folder already uses.
- **An Ingress can only reference Services in its own namespace** — that's why every protected
  namespace needs its own `authentik-outpost` `ExternalName` Service aliasing
  `authentik-server.authentik.svc.cluster.local`, rather than one shared Service referenced from
  everywhere.
- **The outpost matches on `X-Forwarded-Host`/`X-Forwarded-Proto`, not the plain `Host` header** —
  confirmed by hand: hitting the auth endpoint with only `Host` set returned `404`/`500`
  ("configuration error"); adding `X-Forwarded-Host`/`X-Forwarded-Proto` (which nginx's *main*
  proxied request always has, but its internal `auth_request` sub-request does **not**, by
  default) returned a clean `401`.
- **This cluster's ingress-nginx has snippet directives disabled** (`nginx.ingress.kubernetes.io/auth-snippet`
  — the annotation most forward-auth tutorials show for injecting those two headers — is rejected
  outright: *"Snippet directives are disabled by the Ingress administrator"*). `auth-proxy-set-headers`
  is the non-snippet equivalent, and it does support nginx variables like `$http_host` in the
  ConfigMap's values, confirmed live. Its one limitation: ingress-nginx refuses cross-namespace
  ConfigMap references for this annotation (*"cross namespace usage of secrets is not allowed"*,
  also tested), so the tiny two-line ConfigMap has to be copy-pasted into every namespace with a
  protected app rather than defined once and shared.
- **Blueprint discovery for `blueprints.configMaps`-mounted files runs on an hourly schedule**
  (`21 * * * *`, confirmed via `Schedule.objects.filter(actor_name__icontains='blueprint')` in the
  `ak shell`), **not** on every worker pod start — unlike the built-in system blueprints (e.g.
  bootstrap), which apply during startup/migrations. On a fresh install or full rebuild, none of the
  per-app Providers/Applications/Groups will exist until that cron fires, up to an hour later. Force
  it immediately instead:
  ```bash
  kubectl exec -n authentik deploy/authentik-worker -- ak apply_blueprint mounted/cm-authentik-blueprint-sso/sso.yaml
  ```
- **The mounted ConfigMap file can lag behind a `git push` by up to ~60–90s** (kubelet's periodic
  sync of projected ConfigMap volumes) — force-applying immediately after pushing a blueprint change
  can silently apply the *previous* version still cached on disk in the pod. Hit this for real: force
  applied right after switching this blueprint from the old shared domain-wide design to the current
  per-app one, and it recreated the old shared Provider/Application from stale content instead of
  picking up the new one. Confirm the mounted file actually matches before trusting a force-apply:
  ```bash
  kubectl exec -n authentik deploy/authentik-worker -- grep -c 'model:' /blueprints/mounted/cm-authentik-blueprint-sso/sso.yaml
  ```
  (compare against the number of `model:` entries the blueprint file is supposed to have) before running `ak apply_blueprint`.
- **A frontend that streams data via its own API client (WebSocket, gRPC-Web, etc.) may not carry
  the browser's session cookie the way normal page navigation does.** Hit this with Hubble UI: the
  main page loaded fine (gated correctly, cookie sent), but its `/api/control-stream` and
  `/api/service-map-stream` calls came back as `302`s into the login flow instead of reaching Hubble
  UI's backend — the gRPC-Web client making those calls doesn't send cookies, so `auth_request` saw
  every one as unauthenticated. Confirmed via the ingress-nginx access logs (every stream request
  paired with an immediate `GET /outpost.goauthentik.io/start?rd=...api...`). Fixed by carving out
  that path into its own `Ingress` (`networking/cilium/authentik-bypass-api-ingress.yaml`) with no
  auth annotations at all — same "separate merged Ingress for one path" pattern as the
  `/outpost.goauthentik.io` routing above, just without any auth this time. **Deliberate tradeoff:**
  that path becomes reachable without logging in to anyone who can reach the hostname directly (LAN
  only, not internet-exposed) — acceptable for Hubble's flow-observability data, but worth
  re-examining case by case for a different app's streaming API.

## Files in this folder

| File | Purpose |
|------|---------|
| `namespace.yaml` | Creates the `authentik` namespace. Required in the same Kustomization as the HelmRelease — Flux won't create the namespace for a HelmRelease that targets it (see the root README's Flux gotchas). |
| `helmrepository.yaml` | Tells Flux where to pull the chart from: the `authentik` chart from `https://charts.goauthentik.io`. |
| `helmrelease.yaml` | The actual deployment — chart version, ingress hostname, storage, and secret wiring. This is the file you'll edit most. |
| `authentik-secret-key-sealed.yaml` | A `SealedSecret` holding `AUTHENTIK_SECRET_KEY`. See [Secrets](#secrets-important) below — **do not regenerate this casually**. |
| `authentik-postgresql-credentials-sealed.yaml` | A `SealedSecret` holding the password for the bundled PostgreSQL's `authentik` user. |
| `authentik-bootstrap-token-sealed.yaml` | A `SealedSecret` holding a non-expiring API token for `akadmin`. See [API access](#api-access) below. |
| `blueprint-sso-configmap.yaml` | An Authentik ["blueprint"](https://docs.goauthentik.io/docs/customize/blueprints/) — config-as-code for every protected app's Group/Provider/Application/Outpost binding, described in [How apps get protected](#how-apps-get-protected). Mounted into the worker pod and applied automatically by Authentik itself, not by Flux/Kubernetes. |
| `authentik-app-icons-configmap.yaml` | Self-hosted SVG icons for the Authentik app list, mounted into the server pod (see `helmrelease.yaml`). |
| `postgres-mcp-loadbalancer.yaml` | A `LoadBalancer` Service exposing Postgres directly (`10.0.40.101:5432`) via a read-only `mcp_readonly` user, for the `postgres` Claude Code MCP integration — see `docs/claude-code-mcp.md`. |
| `kustomization.yaml` | Lists all the files above so Flux applies them together. Referenced from `clusters/talos-dev/kustomization.yaml`. |

## How it fits together

1. Flux reconciles `clusters/talos-dev/kustomization.yaml`, which includes this folder.
2. The `HelmRepository` (`helmrepository.yaml`) makes the `authentik` chart available to Flux.
3. The `HelmRelease` (`helmrelease.yaml`) installs the chart into the `authentik` namespace with
   our custom `values`, which:
   - Enable the chart's **bundled PostgreSQL** (Bitnami subchart) as the database — Authentik has
     no SQLite option like n8n; Postgres is a hard requirement. This chart version has **no Redis
     dependency** either (older Authentik releases needed one; it's since been dropped).
   - Leave `authentik.secret_key` and `authentik.postgresql.password` unset in `values`, so the
     chart's auto-generated config secret doesn't contain them in plaintext, and instead inject
     both via `global.env` + `secretKeyRef` (applies to both the server and worker pods) — same
     pattern as n8n's `N8N_ENCRYPTION_KEY`.
   - Point `postgresql.auth.existingSecret` at the **same** `authentik-postgresql-credentials`
     secret used above, so there's one source of truth for that password rather than two secrets
     that could drift out of sync. `enablePostgresUser: false` skips creating an unused Postgres
     superuser account, since Authentik only ever connects as its own `authentik` user.
   - Create an `Ingress` for `authentik.lab.example.com` via `nginx` + `letsencrypt-production`, same
     pattern as every other app in this cluster.

No manual Helm install is required — pushing to `prod` is enough. Flux reconciles every 5 minutes
(`spec.interval`), or force it immediately:

```bash
flux reconcile helmrelease authentik -n authentik --with-source
```

## Storage

Unlike n8n or WordPress, **the server and worker pods themselves are stateless** — there's no
separate application-data PVC. The only persistent volume is PostgreSQL's, which holds everything
Authentik knows: users, groups, applications/providers, policies, flows, tokens/sessions, and the
audit/event log.

One thing intentionally *not* persisted: Authentik's media storage (uploaded custom branding,
icons) defaults to the container's local, ephemeral filesystem (`/data`) unless configured
otherwise — it doesn't survive a pod restart. This chart doesn't offer a built-in PVC for it, and
wiring one up would need a `ReadWriteMany` volume (server and worker can land on different nodes
and both touch it) or S3-compatible storage, which is more complexity than a homelab needs just for
custom logos. Left as-is for now; default Authentik branding works fine without it.

## API access

`AUTHENTIK_BOOTSTRAP_TOKEN` (via `authentik-bootstrap-token-sealed.yaml`) makes Authentik's
built-in system bootstrap blueprint attach a non-expiring API token to the `akadmin` user, named
`authentik-bootstrap-token`. This exists for config-as-code automation (verifying the API schema,
scripting Provider/Application setup) — it's not meant for interactive/day-to-day admin login, and
it's tied to `akadmin` specifically, not a separate service account.

```bash
TOKEN=$(kubectl get secret authentik-bootstrap-token -n authentik -o jsonpath='{.data.token}' | base64 -d)
curl -H "Authorization: Bearer $TOKEN" https://authentik.lab.example.com/api/v3/core/users/me/
```

**Gotcha:** Authentik's built-in system blueprints (like the bootstrap one) are only re-applied
when their *file content* changes — since `bootstrap.yaml` is baked into every image identically,
adding `AUTHENTIK_BOOTSTRAP_TOKEN` to an *existing* install (rather than a fresh one) does **not**
get picked up just by restarting the pods. Force it once with:
```bash
kubectl exec -n authentik deploy/authentik-worker -- ak apply_blueprint system/bootstrap.yaml
```
This only matters the first time the token is introduced. Custom blueprints added via
`blueprints.configMaps` (like `blueprint-sso-configmap.yaml`) do get discovered automatically
without this specific "unchanged file content" problem — but they have their own timing gotchas
(hourly discovery schedule, stale mounted volumes) covered in
[How apps get protected](#how-apps-get-protected).

## Secrets (important)

All three `SealedSecret`s were sealed against this cluster's sealed-secrets controller — the actual
values are not recoverable from git, only from the live `Secret` objects in the cluster.
`authentik-bootstrap-token` is covered above in [API access](#api-access); the other two:

- **`authentik-secret-key`** must stay stable for the life of the database. It signs
  cookies/sessions and derives internal IDs — rotating it invalidates every active session, and
  anything it protected becomes unreadable. Never regenerate this unless you're intentionally
  starting fresh (wiping the Postgres volume too).
- **`authentik-postgresql-credentials`** is the password for Postgres's `authentik` user, shared
  between the database and the app itself (see above). Changing it after the database already
  exists won't rotate anything automatically — Postgres keeps the password it was initialized
  with, so you'd need to update it inside Postgres itself (or wipe the PVC) for a rotation to take
  effect, same caveat as WordPress's MariaDB credentials.
- Both decrypt only inside the `authentik` namespace on this cluster's sealed-secrets controller
  (see the "Sealed Secrets — Secret Management" section of the [root README](../../../../README.md)).

## Common tasks

**Check it's running:**
```bash
kubectl get pods -n authentik
kubectl get ingress -n authentik
kubectl get certificate -n authentik
```

**First login:** Authentik has a first-run setup flow at
`https://authentik.lab.example.com/if/flow/initial-setup/` to set the initial `akadmin` password —
same idea as n8n/WordPress's first-run screens.

**Check the SSO blueprint applied correctly:**
```bash
kubectl exec -n authentik deploy/authentik-worker -- ak shell -c "
from authentik.blueprints.models import BlueprintInstance
for b in BlueprintInstance.objects.filter(name__icontains='forward auth'):
    print(b.name, b.status, b.last_applied)
"
```
Should show `successful`. If it doesn't, `kubectl logs -n authentik -l app.kubernetes.io/component=worker`
around the blueprint discovery task will show why (e.g. a typo in a `!Find` lookup).

**Grow the database storage** (Longhorn's `allowVolumeExpansion` is enabled, so this is
online/non-disruptive):
```yaml
# helmrelease.yaml
postgresql:
  primary:
    persistence:
      size: 10Gi  # bump this
```
Push the change; Flux/Helm resizes the PVC in place.

**Change the chart/app version:** chart version and app version move in lock-step for this chart
(maintained by the Authentik team themselves, unlike n8n's community chart) — Renovate's built-in
`flux` manager already tracks `spec.chart.spec.version` automatically, no extra `customManagers`
entry needed.
```yaml
# helmrelease.yaml
spec:
  chart:
    spec:
      version: "2026.8.0"  # bump to a newer chart version
```

**Back up Authentik's config:** the Postgres PVC contains everything — users, groups, flows,
policies, provider/application config. There's no separate backup job configured for this PVC
today (unlike Longhorn's nightly job for other volumes) — if you need backups, either add a
Longhorn `RecurringJob` selector/label to this volume, or use Authentik's own
[blueprint export](https://docs.goauthentik.io/docs/customize/blueprints/) for config-as-code.

**Debug a failed release:**
```bash
flux get helmrelease authentik -n authentik
kubectl describe helmrelease authentik -n authentik
kubectl logs -n authentik -l app.kubernetes.io/component=server
kubectl logs -n authentik -l app.kubernetes.io/component=worker
```
