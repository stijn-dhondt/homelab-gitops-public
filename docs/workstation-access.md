# Workstation access (talosctl + kubectl)

How to get a fresh or reinstalled Mac talking to the cluster again: install the two CLIs, restore
the admin talosconfig, pull a kubeconfig, verify. Written after doing exactly this following a macOS
reinstall (2026-10-21), so it reflects what was actually needed, not what bootstrap generates.

Unlike [cluster-bootstrap.md](cluster-bootstrap.md), nothing here touches the cluster — it only sets
up client-side credentials for a cluster that's already running.

## What you need

| Item | Where it comes from | Where it goes |
|---|---|---|
| `kubectl` | dl.k8s.io (or Homebrew) | on `PATH` |
| `talosctl` | Talos GitHub release, **same version as the cluster** (`clusters/talos-dev/talos-version.yaml`) | on `PATH` |
| **Admin talosconfig** (`os:admin` client cert) | Your backup (password manager) — **it is not in git and cannot be pulled from the cluster** | `~/.talos/config` |
| kubeconfig | Generated from the talosconfig in step 3 | `~/.kube/config` |
| Network reach to `10.0.20.0/24` | LAN, or Cloudflare WARP (see the cloudflare-tunnel README) | — |

The talosconfig is the only thing on this list you can't recreate from scratch. Everything else is
either downloadable or derived from it.

## 1. Install the CLIs

Homebrew (`brew install kubectl siderolabs/tap/talosctl`) works if it's installed, but brew's
`talosctl` tracks the latest release, not the cluster's version. Direct downloads into `~/.local/bin`
need no Homebrew and let you pin `talosctl` exactly. Both binaries are checked against the
checksums their projects publish:

```bash
mkdir -p ~/.local/bin && cd ~/.local/bin

# kubectl - latest stable; anything within one minor version of the cluster (v1.36) is supported
V=$(curl -fsSL https://dl.k8s.io/release/stable.txt)
curl -fsSLo kubectl "https://dl.k8s.io/release/$V/bin/darwin/arm64/kubectl"
echo "$(curl -fsSL "https://dl.k8s.io/release/$V/bin/darwin/arm64/kubectl.sha256")  kubectl" | shasum -a 256 -c

# talosctl - must match talosVersion in clusters/talos-dev/talos-version.yaml
T=v1.13.6
curl -fsSLo talosctl-darwin-arm64 "https://github.com/siderolabs/talos/releases/download/$T/talosctl-darwin-arm64"
curl -fsSL "https://github.com/siderolabs/talos/releases/download/$T/sha256sum.txt" | grep ' talosctl-darwin-arm64$' | shasum -a 256 -c
mv talosctl-darwin-arm64 talosctl

chmod +x kubectl talosctl
grep -q '.local/bin' ~/.zshrc || echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
```

Open a new terminal (or `source ~/.zshrc`), then `kubectl version --client` and
`talosctl version --client` should both answer. On an Intel Mac, swap `arm64` for `amd64`.

## 2. Restore the admin talosconfig

Copy your backed-up talosconfig to `~/.talos/config` — **not** into this repo:

```bash
mkdir -p ~/.talos && chmod 700 ~/.talos
cp /path/to/backup/talosconfig ~/.talos/config
chmod 600 ~/.talos/config

talosctl config endpoint 10.0.20.11 10.0.20.12 10.0.20.13
talosctl config node 10.0.20.11
talosctl config contexts          # my-cluster, current, with the endpoints above
talosctl version --short          # must show a Server section, not just Client
```

A valid file has one context (`my-cluster`) with `ca`, `crt` and `key` fields. The `endpoints` list
in the backup may be empty — that's what the two `config` commands above fix.

## 3. Pull a kubeconfig

```bash
talosctl kubeconfig --nodes 10.0.20.11 --force
kubectl get nodes                 # 4 nodes, Ready
```

This writes `~/.kube/config` pointing at the control-plane VIP `https://10.0.20.10:6443` with a
freshly minted admin client cert. Re-running it later is harmless — it just mints a new cert.

## 4. Verify

```bash
kubectl get nodes -o wide                                   # Talos + k8s versions match the repo
kubectl get gitrepository,kustomizations -n flux-system    # Flux on the latest prod commit, Ready
kubectl get helmreleases -A                                 # all Ready
```

## Credential lifetimes

| Credential | Expires | Renew with |
|---|---|---|
| Admin talosconfig client cert (`O=os:admin`) | **2027-06-09** | `talosctl config new <file> --roles os:admin` *while the current one still works*, then replace `~/.talos/config` **and the backup** |
| kubeconfig client cert (`O=system:masters`) | 1 year after it was generated (current one: 2027-10-21) | Re-run step 3 |

Check any time without printing secrets:

```bash
ruby -ryaml -rbase64 -e 'c=YAML.load_file(File.expand_path("~/.talos/config"))["contexts"].values.first; print Base64.decode64(c["crt"])' | openssl x509 -noout -subject -enddate
```

If the talosconfig expires, `talosctl` fails with a TLS/certificate error and step 3 is impossible.
The way back is regenerating it from the cluster's `secrets.yaml` (from `talosctl gen secrets` at
bootstrap, if you kept it): `talosctl gen config my-cluster https://10.0.20.10:6443 --with-secrets secrets.yaml --output-types talosconfig`.
Without `secrets.yaml` and without a working talosconfig there is no supported way back in short of
rebuilding the control plane — so renew early and keep the backup current.

## Gotchas

- **The talosconfig does not belong in the repo.** On 2026-10-21 it turned up as
  `clusters/talos-dev/talos/config/config.yaml`, untracked and *not* ignored — one `git add -A` away
  from pushing full cluster-admin credentials (and the public mirror sync would then have published
  them). The root `.gitignore` now blocks the usual names (`talosconfig`, `config.yaml` in that
  folder, `controlplane.yaml`, `worker.yaml`, `secrets.yaml`, `kubeconfig`), but `~/.talos/config`
  is the only place it should live.
- **`talosctl` creates an empty `~/.talos/config` on first run** (`context: ""`, ~25 bytes). Its
  existence doesn't mean you're configured — `talosctl config contexts` showing no rows means it's
  still the empty stub.
- **No server answer ≠ no credentials.** Check reachability first:
  `nc -z -G 3 10.0.20.11 50000` (Talos API) and `nc -z -G 3 10.0.20.10 6443` (k8s API). Both
  open but commands fail → credential problem. Either closed → network/VPN problem.
- **`talosctl` version skew**: a much newer client can refuse or misbehave against an older cluster.
  Keep it pinned to `talosVersion` and bump it together with the cluster.
- **Git in `~/Documents` can be slow** (Spotlight/iCloud indexing): `git status` on this repo has
  taken >2 minutes. `git status -uno` or a narrower path is a quick workaround.
