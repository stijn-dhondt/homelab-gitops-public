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

```bash
kubectl get secret -n sealed-secrets -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml > sealed-secrets-key-backup.yaml
```

Store this file outside the cluster (password manager, encrypted USB). **Never commit it to git**
— it's already in this repo's `.gitignore` by name, but double-check before ever adding it anywhere.

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
