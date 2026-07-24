# Sealed Secrets

Replaces manually created Secrets with encrypted `SealedSecret` objects that are safe to commit —
every `*-sealed.yaml` file anywhere in this repo depends on this controller existing. The
controller decrypts them inside the cluster using a key pair it generates and stores in the
cluster (not in git).

The controller runs as a single replica — it's not on the critical path day-to-day. Existing
Secrets survive a controller restart; only applying *new* or *updated* SealedSecrets requires the
controller to be available.

## Files in this folder

| File | Purpose |
|------|---------|
| `namespace.yaml` | Creates the `sealed-secrets` namespace. |
| `helmrepository.yaml` | The `sealed-secrets` chart. |
| `helmrelease.yaml` | The controller itself. |

## Back up the sealing key immediately after first install

If the cluster is ever wiped and this key is lost, every `SealedSecret` already committed to git
becomes permanently undecryptable — there's no recovery path.

**This is now automated** — `backup/cluster-backup`'s `CronJob` exports every current key (same
label selector as below) every night at `01:00`, onto a Longhorn-backed PVC that rides Longhorn's
own nightly NAS backup, so it's refreshed automatically without relying on remembering to re-run a
command by hand. See that folder's README for the full design and how to retrieve a copy. What
follows is the manual, one-off version, for ad-hoc use or if you want a copy somewhere other than
the automated path:

```bash
kubectl get secret -n sealed-secrets -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml > sealed-secrets-key-backup.yaml
```

Store this file outside the cluster (password manager, encrypted USB). **Never commit it to git**
— it's already in this repo's `.gitignore` by name, but double-check before ever adding it anywhere.

**If you do rely on manual copies instead of (or alongside) the automated one, repeat it
periodically** — the controller rotates in a new active key on its own schedule (confirmed live:
two keys currently exist, about a month apart), and every key is kept forever so secrets sealed
under an older key stay decryptable. The `-l` selector above already grabs *all* keys that exist at
backup time, but a backup taken before a rotation won't contain a key created after it. The
automated nightly job doesn't have this problem — it's simply re-run every night.

## Restoring onto a new cluster

This is what actually makes the backup useful — without it, every `*-sealed.yaml` already in this
repo (n8n's encryption key, Authentik's secret key/DB password/bootstrap token, WordPress's
credentials, Forgejo's admin credentials, the Cloudflare Tunnel credentials, everything) is
permanently unrecoverable, since none of their plaintext values live in git.

1. Let Flux bootstrap the new cluster normally, including this `sealed-secrets` HelmRelease — the
   controller will auto-generate a **fresh** key pair on first start, same as any new install.
2. Restore the backed-up key(s) on top of it:
   ```bash
   kubectl apply -f sealed-secrets-key-backup.yaml
   kubectl delete pod -n sealed-secrets -l app.kubernetes.io/name=sealed-secrets
   ```
   The `apply` recreates the old key `Secret`(s) alongside the freshly auto-generated one; deleting
   the pod restarts the controller so it re-reads every key currently in the namespace, not just the
   one it generated at startup.
3. Confirm it worked — force any single `SealedSecret` to re-decrypt and check the resulting
   `Secret` has real content, not empty:
   ```bash
   kubectl annotate sealedsecrets n8n-encryption-key -n n8n \
     sealedsecrets.bitnami.com/trigger-reconcile="$(date +%s)" --overwrite
   kubectl get secret n8n-encryption-key -n n8n -o jsonpath='{.data.encryptionKey}' | base64 -d; echo
   ```
   If that prints the real key instead of erroring, every other `SealedSecret` in the repo will
   decrypt too — they all depend on the exact same restored keypair(s).
4. The controller now has both the restored (old) key(s) and the extra freshly-generated one from
   step 1 — harmless. It'll use whichever is newest for sealing anything new going forward, and can
   still decrypt anything sealed under an older one.

The commands above match this cluster's actual setup (Helm-deployed, `sealed-secrets` namespace,
`app.kubernetes.io/name=sealed-secrets` pod label) — confirmed live rather than copied blind from
[upstream's generic backup/restore docs](https://github.com/bitnami-labs/sealed-secrets#how-can-i-do-a-backup-of-my-sealedsecrets-encryption-keys),
which default to `kube-system` and a different label.

## Sealing a secret

The general workflow — pipe a dry-run Secret through `kubeseal` to produce a `SealedSecret` YAML:
```bash
kubectl create secret generic <secret-name> \
  --namespace <namespace> \
  --from-literal=<key>=<value> \
  --dry-run=client -o yaml | \
kubeseal \
  --controller-namespace sealed-secrets \
  --controller-name sealed-secrets-controller \
  --format yaml > clusters/talos-dev/<path>/<secret-name>-sealed.yaml
```

Then add the file to the relevant `kustomization.yaml` and commit. Delete the old manually created
secret — Flux will recreate it from the `SealedSecret`:
```bash
kubectl delete secret <secret-name> -n <namespace>
```

Every `SealedSecret` in this repo is scoped to its exact namespace + name at seal time — a sealed
file can't be copy-pasted into a different namespace or cluster and decrypted there. See the
`apps/*/README.md` files for real, worked examples of this pattern.

## Common tasks

**Verify the controller is running:**
```bash
kubectl get pods -n sealed-secrets
```

**Verify a SealedSecret was decrypted correctly:**
```bash
kubectl get secret <secret-name> -n <namespace>
```

**Re-trigger a reconcile** (e.g. after rotating a value):
```bash
kubectl annotate sealedsecrets <secret-name> -n <namespace> \
  sealedsecrets.bitnami.com/trigger-reconcile="$(date +%s)" --overwrite
```
