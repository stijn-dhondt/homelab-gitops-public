# Workstation access (talosctl + kubectl)

How to get a fresh or reinstalled workstation talking to the cluster again: install the two CLIs,
restore the admin talosconfig, pull a kubeconfig, verify. The macOS steps were written after doing
exactly this following a macOS reinstall (2026-10-21), so they reflect what was actually needed, not
what bootstrap generates. The Windows steps are the same workflow translated to PowerShell — **not
yet run end-to-end on a real Windows machine**, so fix this page if something differs when you do.

Unlike [cluster-bootstrap.md](cluster-bootstrap.md), nothing here touches the cluster — it only sets
up client-side credentials for a cluster that's already running.

## What you need

| Item | Where it comes from | macOS location | Windows location |
|---|---|---|---|
| `kubectl` | dl.k8s.io | `~/.local/bin` (on `PATH`) | `%USERPROFILE%\.local\bin` (on user `Path`) |
| `talosctl` | Talos GitHub release, **same version as the cluster** (`clusters/talos-dev/talos-version.yaml`) | `~/.local/bin` | `%USERPROFILE%\.local\bin` |
| **Admin talosconfig** (`os:admin` client cert) | Your backup (password manager) — **it is not in git and cannot be pulled from the cluster** | `~/.talos/config` | `%USERPROFILE%\.talos\config` |
| kubeconfig | Generated from the talosconfig in step 3 | `~/.kube/config` | `%USERPROFILE%\.kube\config` |
| Network reach to `10.0.20.0/24` | LAN, or Cloudflare WARP (see the cloudflare-tunnel README) | — | — |

The talosconfig is the only thing on this list you can't recreate from scratch. Everything else is
either downloadable or derived from it.

Both CLIs look for their config in the user's home folder on both OSes (`$HOME` on macOS,
`%USERPROFILE%` on Windows), so once the files are in place, steps 3 and 4 are the same commands
everywhere.

## 1. Install the CLIs

Package managers work (`brew install kubectl siderolabs/tap/talosctl`, `winget install -e --id Kubernetes.kubectl`),
but they install the *latest* `talosctl`, not the cluster's version. Direct downloads let you pin
`talosctl` exactly and need nothing else installed. Both binaries are checked against the checksums
their projects publish.

### macOS (zsh)

```bash
mkdir -p ~/.local/bin && cd ~/.local/bin

# kubectl - latest stable; anything within one minor version of the cluster (v1.36) is supported
V=$(curl -fsSL https://dl.k8s.io/release/stable.txt)
curl -fsSLo kubectl "https://dl.k8s.io/release/$V/bin/darwin/arm64/kubectl"
echo "$(curl -fsSL "https://dl.k8s.io/release/$V/bin/darwin/arm64/kubectl.sha256")  kubectl" | shasum -a 256 -c

# talosctl - must match talosVersion in clusters/talos-dev/talos-version.yaml
T=v1.14.4
curl -fsSLo talosctl-darwin-arm64 "https://github.com/siderolabs/talos/releases/download/$T/talosctl-darwin-arm64"
curl -fsSL "https://github.com/siderolabs/talos/releases/download/$T/sha256sum.txt" | grep ' talosctl-darwin-arm64$' | shasum -a 256 -c
mv talosctl-darwin-arm64 talosctl

chmod +x kubectl talosctl
grep -q '.local/bin' ~/.zshrc || echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
```

Open a new terminal (or `source ~/.zshrc`). On an Intel Mac, swap `arm64` for `amd64`.

### Windows (PowerShell)

Run in a normal (non-admin) PowerShell window — everything goes into your own profile, so no
elevation is needed. Works in Windows PowerShell 5.1 and PowerShell 7.

```powershell
$ProgressPreference = 'SilentlyContinue'   # Invoke-WebRequest is very slow with the progress bar on
$bin  = "$env:USERPROFILE\.local\bin"
$arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'amd64' }
New-Item -ItemType Directory -Force $bin | Out-Null

# kubectl - latest stable; anything within one minor version of the cluster (v1.36) is supported
Invoke-WebRequest https://dl.k8s.io/release/stable.txt -OutFile "$env:TEMP\k8s-stable.txt"
$V = (Get-Content "$env:TEMP\k8s-stable.txt" -Raw).Trim()
Invoke-WebRequest "https://dl.k8s.io/release/$V/bin/windows/$arch/kubectl.exe" -OutFile "$bin\kubectl.exe"
Invoke-WebRequest "https://dl.k8s.io/release/$V/bin/windows/$arch/kubectl.exe.sha256" -OutFile "$env:TEMP\kubectl.sha256"
$want = (Get-Content "$env:TEMP\kubectl.sha256" -Raw).Trim()
if ((Get-FileHash "$bin\kubectl.exe" -Algorithm SHA256).Hash -ne $want) { Remove-Item "$bin\kubectl.exe"; throw 'kubectl checksum mismatch' }

# talosctl - must match talosVersion in clusters/talos-dev/talos-version.yaml
$T = 'v1.14.4'
$asset = "talosctl-windows-$arch.exe"
Invoke-WebRequest "https://github.com/siderolabs/talos/releases/download/$T/$asset" -OutFile "$bin\talosctl.exe"
Invoke-WebRequest "https://github.com/siderolabs/talos/releases/download/$T/sha256sum.txt" -OutFile "$env:TEMP\talos-sha256sum.txt"
$want = ((Select-String -Path "$env:TEMP\talos-sha256sum.txt" -Pattern " $asset$").Line -split '\s+')[0]
if (-not $want -or (Get-FileHash "$bin\talosctl.exe" -Algorithm SHA256).Hash -ne $want) { Remove-Item "$bin\talosctl.exe"; throw 'talosctl checksum mismatch' }

# Add to the *user* Path (persists; no admin needed)
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if ($userPath -notlike "*$bin*") { [Environment]::SetEnvironmentVariable('Path', "$userPath;$bin", 'User') }
```

Close and reopen PowerShell (and Windows Terminal/VS Code, which only read `Path` at startup).

### Both

`kubectl version --client` and `talosctl version --client` should both answer, with `talosctl`
showing the cluster's Talos version.

## 2. Restore the admin talosconfig

Copy your backed-up talosconfig into your home folder — **not** into this repo — and make it
readable only by you.

### macOS

```bash
mkdir -p ~/.talos && chmod 700 ~/.talos
cp /path/to/backup/talosconfig ~/.talos/config
chmod 600 ~/.talos/config
```

### Windows

```powershell
New-Item -ItemType Directory -Force "$env:USERPROFILE\.talos" | Out-Null
Copy-Item C:\path\to\backup\talosconfig "$env:USERPROFILE\.talos\config"
# Drop inherited permissions and grant only yourself access (the chmod 600 equivalent)
icacls "$env:USERPROFILE\.talos\config" /inheritance:r /grant:r "$($env:USERDOMAIN)\$($env:USERNAME):F"
```

The file must be named exactly `config`, with no extension. Watch out for Explorer hiding a `.txt`
or `.yaml` suffix.

### Both

```bash
talosctl config endpoint 10.0.20.11 10.0.20.12 10.0.20.13
talosctl config node 10.0.20.11
talosctl config contexts          # my-cluster, current, with the endpoints above
talosctl version --short          # must show a Server section, not just Client
```

A valid file has one context (`my-cluster`) with `ca`, `crt` and `key` fields. The `endpoints` list
in the backup may be empty — that's what the two `config` commands above fix.

## 3. Pull a kubeconfig

Same on both OSes:

```bash
talosctl kubeconfig --nodes 10.0.20.11 --force
kubectl get nodes                 # 4 nodes, Ready
```

This writes `~/.kube/config` (`%USERPROFILE%\.kube\config` on Windows) pointing at the control-plane
VIP `https://10.0.20.10:6443`, with a freshly minted admin client cert. Re-running it later is
harmless — it just mints a new cert. Unix-style file permissions don't apply on Windows, so the
file inherits your profile folder's access rules. Give it the same `icacls` treatment as the
talosconfig.

## 4. Verify

Same on both OSes:

```bash
kubectl get nodes -o wide                                   # Talos + k8s versions match the repo
kubectl get gitrepository,kustomizations -n flux-system    # Flux on the latest prod commit, Ready
kubectl get helmreleases -A                                 # all Ready
```

## Credential lifetimes

| Credential | Expires | Renew with |
|---|---|---|
| Admin talosconfig client cert (`O=os:admin`) | **2027-06-09** | `talosctl config new <file> --roles os:admin` *while the current one still works*, then replace the talosconfig on every workstation **and the backup** |
| kubeconfig client cert (`O=system:masters`) | 1 year after it was generated (each workstation mints its own in step 3) | Re-run step 3 |

To check the talosconfig's expiry without printing any secrets:

**macOS:**

```bash
ruby -ryaml -rbase64 -e 'c=YAML.load_file(File.expand_path("~/.talos/config"))["contexts"].values.first; print Base64.decode64(c["crt"])' | openssl x509 -noout -subject -enddate
```

**Windows:**

```powershell
# crt holds a base64-encoded PEM; decode it twice to get the certificate itself
$crt = (Select-String -Path "$env:USERPROFILE\.talos\config" -Pattern '^\s+crt:\s*(\S+)').Matches[0].Groups[1].Value
$pem = [Text.Encoding]::ASCII.GetString([Convert]::FromBase64String($crt))
$der = [Convert]::FromBase64String(($pem -replace '-----[^-]+-----', '' -replace '\s', ''))
$c = New-Object Security.Cryptography.X509Certificates.X509Certificate2 (, $der)
"$($c.Subject)  expires $($c.NotAfter)"
```

If the talosconfig expires, `talosctl` fails with a TLS/certificate error and step 3 is impossible.
The way back is regenerating it from the cluster's `secrets.yaml` (from `talosctl gen secrets` at
bootstrap, if you kept it): `talosctl gen config my-cluster https://10.0.20.10:6443 --with-secrets secrets.yaml --output-types talosconfig`.
Without `secrets.yaml` and without a working talosconfig there is no supported way back in short of
rebuilding the control plane — so renew early and keep the backup current.

## Gotchas

### Both

- **The talosconfig does not belong in the repo.** On 2026-10-21 it turned up as
  `clusters/talos-dev/talos/config/config.yaml`, untracked and *not* ignored — one `git add -A` away
  from pushing full cluster-admin credentials (and the public mirror sync would then have published
  them). The root `.gitignore` now blocks the usual names (`talosconfig`, `config.yaml` in that
  folder, `controlplane.yaml`, `worker.yaml`, `secrets.yaml`, `kubeconfig`), but your home folder's
  `.talos\config` / `.talos/config` is the only place it should live.
- **`talosctl` creates an empty config on first run** (`context: ""`, ~25 bytes). The file existing
  doesn't mean you're configured — `talosctl config contexts` showing no rows means it's still the
  empty stub.
- **No server answer ≠ no credentials.** Check reachability first (commands below). Both ports
  open but commands fail → credential problem. Either one closed → network/VPN problem.
- **`talosctl` version skew**: a much newer client can refuse or misbehave against an older cluster.
  Keep it pinned to `talosVersion` and bump it together with the cluster.

### macOS

- Reachability: `nc -z -G 3 10.0.20.11 50000` (Talos API) and `nc -z -G 3 10.0.20.10 6443`
  (k8s API).
- **Git in `~/Documents` can be slow** (Spotlight/iCloud indexing): `git status` on this repo has
  taken >2 minutes. `git status -uno` or a narrower path is a quick workaround.

### Windows

- Reachability: `Test-NetConnection 10.0.20.11 -Port 50000` and
  `Test-NetConnection 10.0.20.10 -Port 6443` (look for `TcpTestSucceeded : True`).
- **WSL is a separate machine for this purpose.** Inside WSL, `~` is the Linux home, not
  `%USERPROFILE%`: follow the macOS steps there with the `linux` downloads (`linux/amd64/kubectl`,
  `talosctl-linux-amd64`) and copy the talosconfig into WSL too. A Windows-side setup isn't visible
  from WSL, and the other way round.
- **Don't run the PowerShell steps from `cmd.exe`**, and run them in a *new* window afterwards —
  already-open terminals keep the old `Path`.
- **Synced folders**: keep the backup talosconfig out of OneDrive-synced folders (Desktop,
  Documents and Pictures often are) unless that's deliberately where you keep secrets.
