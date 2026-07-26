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

## Prerequisite: the standalone CLI, not just the VS Code extension

**The VS Code extension bundles its own private copy of the CLI for its chat panel — it does not put
a `claude` command on your terminal PATH.** Confirmed live: `claude mcp add` and everything else on
this page requires the separate standalone install, even though the bundled copy is what's running
the actual chat conversation.

```bash
brew install --cask claude-code
```

Open a **new** terminal afterward and confirm with `claude --version`. Also needed: `brew install uv`
(both Grafana's and UniFi's MCP servers install via `uv`).

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
```

Verify: `claude mcp list`.

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
Cloudflare DNS records for example.com", "list UniFi clients".

**Reconnect an OAuth-based server** (Cloudflare) after it shows "Needs authentication":
```bash
claude mcp login cloudflare
```

**Remove and re-add** (e.g. to fix scope, or rotate a credential):
```bash
claude mcp remove <name> -s <local|user>
claude mcp add ... --scope user <name> -- ...
```
