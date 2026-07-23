# Jumphost

A browser-accessible Ubuntu desktop ([linuxserver/webtop](https://docs.linuxserver.io/images/docker-webtop/),
Xfce + Firefox over a web VNC client) — the one deliberate way in from the public internet to
everything else in this cluster, instead of exposing six separate admin UIs directly.

- **URL:** https://jump.example.com (public, via the Cloudflare Tunnel — see
  [How it's exposed](#how-its-exposed) below)
- **Namespace:** `jumphost`
- **Storage:** 4Gi on Longhorn (browser profile/config only)
- **Resources:** 768Mi/3Gi memory (request/limit), 250m/2 CPU — see
  [Common tasks](#common-tasks) for why the memory limit is as high as it is

## Why this exists

We'd built forward-auth + per-app groups for six internal `*.lab.example.com` admin UIs (Grafana,
Prometheus, Alertmanager, n8n, Longhorn UI, Hubble UI) and then asked: is it wise to publish all six
directly? No — concretely: no MFA was enforced anywhere (single admin account, password-only, `skip`
if no device enrolled), there was no brute-force/rate-limit protection at all, and Hubble UI's own
ingress has a deliberate unauthenticated bypass for its streaming API (fine for LAN-only, not for
the public internet). Rather than harden and re-examine all six individually, this publishes **one**
thing — a desktop you log into, and from *inside* it, everything else is reached exactly like being
on the LAN (same hostnames, same certs, nothing else re-exposed).

The alternative to this is a VPN (Tailscale/WireGuard) — arguably simpler, since nothing would be
public-facing at all. This was chosen instead specifically for its one real advantage: access from
any device via just a browser, no VPN client to install.

## Since this is the one thing meant to be attacked, it's hardened harder than the rest

- **A dedicated, stricter Authentik login flow** (`jumphost-authentication-flow`) requiring MFA —
  `not_configured_action: configure`, meaning a user with no TOTP/WebAuthn/static device enrolled is
  walked through enrolling one instead of being let through. The other 6 apps intentionally keep
  the lenient shared default flow (`skip` if not configured), since they're LAN-only.
- **A second, independent credential** on the container itself (`CUSTOM_USER`/`PASSWORD`, sealed in
  `webtop-credentials-sealed.yaml`) — basic-auth in front of the desktop, so a single
  compromised/misconfigured layer (Authentik) isn't the only thing standing between the internet
  and a shell.
- **A `NetworkPolicy`** (`networkpolicy.yaml`) restricting the pod's egress so a compromised
  container can't pivot into the rest of the cluster — it can reach the internet and the
  `10.0.40.0/24` ingress VIP range (i.e. the same `*.lab.example.com` apps a real LAN browser
  reaches), but not the cluster's pod network or Service network (`10.244.0.0/16` /
  `10.96.0.0/12`), which includes the Kubernetes API server and every other pod/database directly.
- **DNS pointed at the LAN's Pi-hole**, not cluster CoreDNS (`deployment.yaml`'s `dnsConfig`) — so
  the browser *inside* webtop resolves `*.lab.example.com` exactly the way a real LAN client does
  (Pi-hole's split-DNS), rather than needing cluster-internal service discovery wired up for it.
- **Its own `cookie_domain`** (`jump.example.com`), deliberately *not* `lab.example.com` — this app
  isn't part of the internal apps' shared SSO domain; it's reached separately from the internet.

## How it's exposed

Unlike the 6 internal apps (`*.lab.example.com`, split-DNS only), this one is routed through the
existing Cloudflare Tunnel — see `networking/cloudflare-tunnel/cloudflared-configmap.yaml`'s
`jump.example.com` entry. **Two things outside this repo, matching the pattern in the root README's
"External Dependencies" section:**
- A Cloudflare DNS record: `jump.example.com` → the tunnel (same `<tunnel-id>.cfargotunnel.com` CNAME
  target as `example.com`/`www.example.com`).
- Nothing needed for internal split-DNS — this hostname isn't meant to resolve specially on the
  LAN; the public record works from inside the network too.

## Files in this folder

| File | Purpose |
|------|---------|
| `namespace.yaml` | Creates the `jumphost` namespace. |
| `webtop-credentials-sealed.yaml` | A `SealedSecret` holding the container's own basic-auth username/password — see [hardening](#since-this-is-the-one-thing-meant-to-be-attacked-its-hardened-harder-than-the-rest) above. |
| `pvc.yaml` | 4Gi Longhorn volume for `/config` — the desktop's home directory (browser profile, bookmarks, downloads). Not critical data; this is a workspace, not a database. |
| `deployment.yaml` | The webtop container itself — image, resources, the Pi-hole `dnsConfig`, and the two credential env vars sourced from the sealed secret. |
| `service.yaml` | ClusterIP, port 80 → the container's port 3000 (HTTP; TLS is terminated at the ingress like every other app here). |
| `authentik-auth-headers-configmap.yaml`, `authentik-outpost-service.yaml` | Same forward-auth plumbing as every other protected app — see the authentik README's "How apps get protected". |
| `networkpolicy.yaml` | Egress lockdown — see [hardening](#since-this-is-the-one-thing-meant-to-be-attacked-its-hardened-harder-than-the-rest) above. |
| `ingress.yaml` | The `jump.example.com` ingress — forward-auth annotations (pointing at this app's own MFA-required flow via Authentik, not the shared lenient one) plus the long-timeout/no-buffering settings the web VNC connection needs, same reasoning as Hubble UI's ingress. |
| `kustomization.yaml` | Lists all of the above so Flux applies them together. Referenced from `clusters/talos-dev/kustomization.yaml`. |

The Authentik-side config (Group, stricter MFA flow, Provider, Application, policy binding) lives in
`clusters/talos-dev/apps/authentik/blueprint-sso-configmap.yaml` alongside the 6 internal apps' —
see that file and the authentik README, not a separate file here.

## Common tasks

**Check it's running:**
```bash
kubectl get pods -n jumphost
kubectl get ingress -n jumphost
kubectl get certificate -n jumphost
```

**First login:** `https://jump.example.com` → Authentik login (username/password) → since no MFA
device exists yet the first time, you'll be walked through enrolling a TOTP device (any
authenticator app) → then the container's own basic-auth prompt (`CUSTOM_USER`/`PASSWORD` from the
sealed secret) → the desktop itself.

**Retrieve the container's own basic-auth credentials:**
```bash
kubectl get secret webtop-credentials -n jumphost -o jsonpath='{.data.username}' | base64 -d; echo
kubectl get secret webtop-credentials -n jumphost -o jsonpath='{.data.password}' | base64 -d; echo
```

**Grant/revoke jumphost access:** add or remove the user from the "Jumphost Users" group in
Authentik (Directory → Groups) — same as the 6 internal apps, see the authentik README.

**Debug a failed deployment:**
```bash
kubectl describe pod -n jumphost -l app=webtop
kubectl logs -n jumphost -l app=webtop
```
If the pod shows `OOMKilled` in `kubectl get pods -n jumphost`, it's likely the memory limit again —
this happened for real once already: the original `1500Mi` limit looked reasonable on paper but
OOMKilled the container dozens of times under actual use (Xfce + Firefox genuinely running, not just
idle at startup). Bumped to `3Gi` in `deployment.yaml`, confirmed stable afterward. If it recurs,
check `kubectl top pod -n jumphost` while actively using the desktop before assuming `3Gi` is
still enough, rather than guessing at a new number.

**If DNS inside the desktop seems wrong** (can't reach `*.lab.example.com` or the general internet):
check the Pi-hole (`10.0.10.12`) is actually reachable from the pod — `deployment.yaml`'s
`dnsPolicy: "None"` means there's no cluster-DNS fallback if it isn't.
