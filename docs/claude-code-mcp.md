# Claude Code MCP servers

Not cluster state — this documents how Claude Code (on whatever machine you're working from) is
wired up to talk directly to this homelab's surrounding services, and the real gotchas hit getting
there. Kept here for the same reason as [external-dependencies.md](external-dependencies.md): it's
operational knowledge that isn't reproducible from `kubectl`/`flux` alone.

## What's connected, and why

| Server | Purpose | Auth |
|---|---|---|
| **Grafana** | Query dashboards/datasources/alerts directly, no port-forward dance | Service account token (Viewer role) |
| **Cloudflare** | Zero Trust Gateway policies, DNS records, Tunnel config — previously needed slow copy-paste JSON round-trips | OAuth |
| **GitHub** | Repo/PR/Issues/Actions-run inspection — became necessary once the repo went private (unauthenticated API calls stopped working) | Fine-grained PAT |
| **UniFi** | Firewall rules, VLANs, clients — previously needed manual dashboard clicks | API key |
| **Postgres** | Query Authentik's database directly (users, groups, sessions) | Dedicated `mcp_readonly` DB user |
| **MariaDB** | Query WordPress's database directly (posts, users, options) | Dedicated `mcp_readonly` DB user |
| **n8n** | List/manage/trigger workflows via `czlonkowski/n8n-mcp` | API key |

**Considered and dropped:** Authentik (no actively-maintained MCP server exists — the 3 community
attempts found are either >1 year stale or have zero real adoption) and OpenMediaVault/the NAS (same
conclusion, and OMV's own internal API has no version-stability guarantee across releases — it broke
going from OMV 7 to 8). Revisit if either matures; not worth wiring up something unreliable now.

## Prerequisite: the standalone CLI, not just the VS Code extension

**The VS Code extension bundles its own private copy of the CLI for its chat panel — it does not put
a `claude` command on your terminal PATH.** Confirmed live: `claude mcp add` and everything else on
this page requires the separate standalone install, even though the bundled copy is what's running
the actual chat conversation.

```bash
brew install --cask claude-code
```

Open a **new** terminal afterward and confirm with `claude --version`. Also needed: `brew install uv`
(Grafana's and UniFi's MCP servers install via `uv`; Postgres's does too).

## Setup commands

All four use `--scope user` — see [the scope gotcha](#gotcha-scope-is-tied-to-the-exact-directory-you-ran-add-from)
below for why `--scope local` (the default) is the wrong choice here.

```bash
# Grafana - token is a Viewer-role service account, generated once via Grafana's own API
claude mcp add --env GRAFANA_URL=https://grafana.lab.example.com \
  --env GRAFANA_SERVICE_ACCOUNT_TOKEN=<token> \
  --scope user grafana -- uvx mcp-grafana

# Cloudflare - OAuth, no static token
claude mcp add --transport http cloudflare https://mcp.cloudflare.com/mcp --scope user
claude mcp login cloudflare   # or: run `claude`, then `/mcp` inside that session

# GitHub - fine-grained PAT scoped to homelab-gitops + homelab-gitops-public
# (Settings -> Developer settings -> Fine-grained tokens: Contents rw, Actions r, PRs rw, Issues rw)
claude mcp add --transport http github https://api.githubcopilot.com/mcp/ \
  --header "Authorization: Bearer YOUR_GITHUB_PAT" --scope user

# UniFi - API key from unifi.ui.com -> Settings -> Control Plane -> Integrations
uv tool install unifi-mcp-server
claude mcp add --env UNIFI_API_KEY=<key> \
  --env UNIFI_API_TYPE=local --env UNIFI_LOCAL_HOST=10.0.20.1 \
  --scope user unifi -- unifi-mcp-server

# Postgres - dedicated mcp_readonly user, read-only (--access-mode=restricted), via the
# postgres-mcp-loadbalancer.yaml Service (apps/authentik/). Pinned to --python 3.12 - see the
# pglast gotcha below.
claude mcp add postgres -e DATABASE_URI="postgresql://mcp_readonly:<pw>@10.0.40.101:5432/authentik?sslmode=disable" \
  --scope user -- uvx --python 3.12 postgres-mcp --access-mode=restricted

# MariaDB - dedicated mcp_readonly user, read-only by default (no ALLOW_*_OPERATION flags set),
# via the mariadb-mcp-loadbalancer.yaml Service (apps/wordpress/). Needs Node/npx - see the gotcha
# below if this machine doesn't have it yet: brew install node
claude mcp add mariadb -e MYSQL_HOST="10.0.40.102" -e MYSQL_PORT="3306" \
  -e MYSQL_USER="mcp_readonly" -e MYSQL_PASS="<pw>" -e MYSQL_DB="bitnami_wordpress" \
  --scope user -- npx @benborla29/mcp-server-mysql

# n8n - API key from n8n's own UI: Settings -> n8n API -> Create an API key
claude mcp add n8n-mcp -e MCP_MODE=stdio -e LOG_LEVEL=error -e DISABLE_CONSOLE_OUTPUT=true \
  -e N8N_API_URL=https://n8n.lab.example.com -e N8N_API_KEY=<key> \
  --scope user -- npx n8n-mcp
```

Verify: `claude mcp list`.

## Migrating batch-1 servers from `local` to `user` scope

Grafana/Cloudflare/GitHub/UniFi were originally set up with `--scope local` before the scope gotcha
(below) was understood. To bring them in line with everything added since:
```bash
claude mcp remove grafana -s local
claude mcp remove cloudflare -s local
claude mcp remove github -s local
claude mcp remove unifi -s local
```
Then re-run each of their four `add` commands above — Cloudflare and GitHub will need their
OAuth/PAT redone since removing a server drops its stored credential, Grafana and UniFi will just
work again immediately with the same env vars.

## Gotchas hit live, in the order we hit them

### `claude mcp add` doesn't validate credentials at add-time

A bad/placeholder token is accepted immediately and only fails later, silently, when something
tries to actually use it. `claude mcp list` (not `add`) is the source of truth for whether a server
actually works.

### Grafana is behind Authentik's forward-auth — token clients can't reach it directly

Every `*.lab.example.com` app including Grafana sits behind Authentik's cookie-based forward-auth (see
`apps/authentik/README.md`). A token-authenticated API client has no session cookie, so nginx's
`auth_request` redirects it into the login page instead of proxying the request — no API client can
follow that. Fixed with a second Ingress, `grafana-api-bypass-ingress.yaml`
(`monitoring/kube-prometheus-stack/`), for just the `/api` path, no Authentik annotations — same
pattern already used for Hubble UI's streaming API. Grafana's own auth (the service account token)
still gates everything through that path; only the Authentik layer is skipped.

### Grafana and UniFi both need WARP connected (or being physically on the LAN)

Both targets — `grafana.lab.example.com` and the UniFi controller at `10.0.20.1` — are only
reachable via the internal network. If either MCP server (or the health-check script below) starts
failing, check WARP connection status (`warp-cli status`) before assuming something else broke.

**Diagnosing this specifically took a while** because the first version of the health-check script
(below) had no timeout on its `curl` calls — an unreachable host just hung indefinitely instead of
failing fast, which looked identical to "still running" rather than "broken." Every check now uses
`--connect-timeout 5 --max-time 10` and reports a distinct "unreachable / timed out" result.

### `unifi-mcp-server`: plain `pip install` hits `externally-managed-environment`

This Mac's Python is Homebrew-managed (PEP 668) — same error hit earlier in this repo's own work
trying `pip3 install pyyaml`. Use `uv tool install unifi-mcp-server` instead, not `pip install`.

### `uv tool install` binaries need `~/.local/bin` on PATH — and a genuinely new terminal

`uv tool update-shell` writes the PATH change to `~/.zshenv`, but **an already-running shell won't
pick it up** — `.zshenv` is only read when a shell *starts*. Re-running commands in the same terminal
window after `update-shell` will still show `command not found`. Requires actually closing and
reopening the terminal (a new tab in the same window is fine; re-running in the existing prompt is
not).

### MCP servers connect at session start — a running conversation never sees new ones

Registering a server with `claude mcp add` while a Claude Code conversation is already open does
nothing for that conversation, no matter how long you wait or how many times you check. Always
verify from a **fresh** session (`claude mcp list` in a new terminal invocation, or a new
conversation/tab), never the one you used to set it up.

### Scope is tied to the exact directory you ran `add` from

`--scope local` (the default if you don't pass `--scope` at all) stores the config keyed to the
project directory you were in — confirmed live: adding all four while `cwd` was `homelab-gitops`,
then running `claude mcp list` from `~` (home directory) in a fresh terminal showed a completely
different result. Since these four are about managing the whole homelab, not something specific to
being inside this one repo, `--scope user` is the right choice — makes them available regardless of
which directory you're working from.

### The VS Code extension's `/mcp` panel is limited

It can show connection status and toggle enable/disable/reconnect, but hit a live case where it
reported "MCP controls aren't available right now" and couldn't complete Cloudflare's OAuth flow.
The full terminal CLI (`claude`, then `/mcp` inside that session, or `claude mcp login <name>`
directly) doesn't have this limitation.

### GitHub's official command form (not the JSON one)

```bash
claude mcp add --transport http github https://api.githubcopilot.com/mcp/ \
  --header "Authorization: Bearer YOUR_GITHUB_PAT"
```
Note the trailing slash on the URL. An earlier attempt used the `claude mcp add-json` form with an
inline JSON blob — works too, but this is what Anthropic's own docs show, and matches what was
actually used successfully here.

### Postgres/MariaDB are raw TCP, not HTTP — the bypass-ingress trick doesn't apply

Grafana and n8n's Authentik problem was fixable with a second Ingress because both speak HTTP —
nginx can inspect the path and route `/api` around the forward-auth gate. Postgres and MariaDB speak
their own binary wire protocols over raw TCP; an `Ingress` object can't proxy that at all. Fix used
instead: a dedicated `LoadBalancer` Service per database (`postgres-mcp-loadbalancer.yaml` in
`apps/authentik/`, `mariadb-mcp-loadbalancer.yaml` in `apps/wordpress/`), each with its own IP from
the same Cilium LB IPAM pool ingress-nginx already uses (`10.0.40.101`/`.102`, one IP per
Service — confirmed the existing WARP route for the whole `10.0.40.0/24` subnet already covers
new IPs in that pool with zero additional VPN/firewall config).

This does mean each database's real network port is now reachable to anyone who can reach that
subnet (LAN or WARP-connected), with **no Authentik/network-level gate in front of it at all** —
database auth is the only thing protecting it. Mitigated by never using the app's own admin/root
credentials for this: both got a brand new `mcp_readonly` user, `GRANT`ed `SELECT`-only, created via
`kubectl exec` directly against each pod (not stored as a `SealedSecret` — these credentials are
consumed by an external MCP client on this machine, not by anything in-cluster, so there's nothing
in git that needs them). Confirmed live before trusting it: reads succeed, a `DELETE` against either
is rejected with a permission error.

### `mariadb`/`n8n-mcp` failed to connect because Node was never installed on this machine

Both run via `npx`. `claude mcp list` just says "Failed to connect" with no reason — confirmed the
actual cause by running `which node npm npx` (all "not found"), not by anything MCP-specific. Fixed
with `brew install node`; both connected immediately after, no re-add needed.

### `postgres-mcp` failed to connect: `pglast` won't build on Python 3.14

`postgres-mcp` depends on `pglast`, which ships no prebuilt wheel for this machine's Python (3.14,
Homebrew's current default) and falls back to compiling from source — which fails outright against
the current macOS SDK (`strchrnul` gets declared twice, once by `pglast`'s C code and once by the
SDK's own `_string.h`). Confirmed by running `uvx postgres-mcp` directly outside of Claude Code to
see the real build error, since `claude mcp get` only ever reports "Failed to connect" with no
detail. Fixed by pinning the server to a Python version `pglast` does ship wheels for:
`uvx --python 3.12 postgres-mcp` instead of plain `uvx postgres-mcp` — no other change needed.

## Health-check script

`~/.claude/scripts/check-mcp-services.sh` — not in this repo (it's a personal-machine utility, and
credentials are read from environment variables, never hardcoded). Tests the underlying
credential/reachability for each service directly; can't test the MCP protocol layer itself (that
only exists inside a live Claude Code session — see the gotcha above). Usage:

```bash
CLOUDFLARE_API_TOKEN=... GITHUB_PAT=... GRAFANA_SERVICE_ACCOUNT_TOKEN=... \
  UNIFI_API_KEY=... UNIFI_LOCAL_HOST=10.0.20.1 \
  ~/.claude/scripts/check-mcp-services.sh
```

## Common tasks

**Check status:**
```bash
claude mcp list
claude mcp get <server-name>   # more detail on a specific one, including the exact failure reason
```

**Actually test a connection works**, not just that it shows connected — from a fresh session, ask
something concrete: "list open PRs on homelab-gitops", "what dashboards exist in Grafana", "show
Cloudflare DNS records for example.com", "list UniFi clients", "how many users are in Authentik's
Postgres database", "what's the most recent post in WordPress", "list active n8n workflows".

**Reconnect an OAuth-based server** (Cloudflare) after it shows "Needs authentication":
```bash
claude mcp login cloudflare
```

**Remove and re-add** (e.g. to fix scope, or rotate a credential):
```bash
claude mcp remove <name> -s <local|user>
claude mcp add ... --scope user <name> -- ...
```
