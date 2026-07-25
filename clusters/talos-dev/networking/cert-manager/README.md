# cert-manager

Automatic TLS certificates via Let's Encrypt, using Cloudflare DNS-01 challenges — every
`Ingress` in this cluster with a `cert-manager.io/cluster-issuer` annotation gets a cert issued and
renewed automatically, with zero manual `Certificate` objects needed.

DNS-01 (not HTTP-01) means cert-manager proves domain ownership by creating a TXT record in
Cloudflare, not by serving a challenge over a public port — this is why certs for purely
internal, split-DNS-only hosts like `grafana.lab.example.com` still work fine despite never being
reachable from the internet.

## Files in this folder

| File | Purpose |
|------|---------|
| `namespace.yaml` | Creates the `cert-manager` namespace. |
| `helmrepository.yaml` | The `cert-manager` chart from the project's own repo. |
| `helmrelease.yaml` | 2 replicas + 2 webhook replicas, CRDs installed via the chart, Prometheus ServiceMonitor. |
| `cloudflare-api-token-sealed.yaml` | A `SealedSecret` holding the Cloudflare API token the DNS-01 solver uses. Needs `Zone → DNS → Edit` scoped to `example.com` — see [Secrets](#secrets) below. |
| `grafana-dashboard-configmap.yaml` | Certificate expiry/readiness overview across every app ([grafana.com #20842](https://grafana.com/grafana/dashboards/20842-cert-manager-kubernetes/)) — auto-loaded by Grafana's sidecar, see `monitoring/kube-prometheus-stack/README.md`. |

The `ClusterIssuer`s themselves (staging + production) live in the sibling
`clusters/talos-dev/networking/cert-manager-issuers/` folder, reconciled as a **separate** Flux
`Kustomization` (`cert-manager-issuers-kustomization.yaml`, one level up) — not bundled into this
one.

> **Gotcha:** Flux validates every resource in a `Kustomization` via dry-run before applying any of
> them. `ClusterIssuer` CRDs don't exist until cert-manager itself installs, so putting the
> `ClusterIssuer`s in the *same* `Kustomization` as this `HelmRelease` blocks the entire
> `Kustomization` — including cert-manager. That's why the issuers reconcile independently instead,
> retrying until the CRDs exist.

## Secrets

**Cloudflare API token** — create a token in Cloudflare with `Zone → DNS → Edit` permission scoped
to `example.com`, then seal it (see the root README's Sealed Secrets section for the general
`kubeseal` workflow):
```bash
kubectl create secret generic cloudflare-api-token \
  --namespace cert-manager \
  --from-literal=api-token=<your-cloudflare-token> \
  --dry-run=client -o yaml | \
kubeseal --controller-namespace sealed-secrets --controller-name sealed-secrets-controller --format yaml \
  > clusters/talos-dev/networking/cert-manager/cloudflare-api-token-sealed.yaml
```

## Common tasks

**Verify ClusterIssuers are ready:**
```bash
kubectl get clusterissuer
```

**Test with staging first** — production has rate limits, always verify staging works before
touching production:
```bash
kubectl apply -f - <<'EOF'
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: test-cert
  namespace: default
spec:
  secretName: test-cert-tls
  issuerRef:
    name: letsencrypt-staging
    kind: ClusterIssuer
  dnsNames:
    - homelab.example.com
EOF

kubectl describe certificate test-cert -n default
# Clean up after verifying Ready: True
kubectl delete certificate test-cert -n default
kubectl delete secret test-cert-tls -n default
```

**Normal use needs no manual `Certificate` objects** — just the annotation on an `Ingress`:
```yaml
annotations:
  cert-manager.io/cluster-issuer: "letsencrypt-production"
```

**Re-trigger a SealedSecret reconcile** (e.g. after rotating the Cloudflare token):
```bash
kubectl annotate sealedsecrets cloudflare-api-token -n cert-manager \
  sealedsecrets.bitnami.com/trigger-reconcile="$(date +%s)" --overwrite
```
