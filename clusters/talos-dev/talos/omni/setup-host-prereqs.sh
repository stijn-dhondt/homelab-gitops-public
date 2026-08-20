#!/usr/bin/env bash
# Run this ONCE, directly on the Docker host (SSH in, not through Portainer),
# in the same folder as docker-compose.yml. It generates all the files that
# the compose stack mounts into the dex/omni containers:
#   ca.pem, server-key.pem, server-chain.pem, omni.asc, dex.yaml
#
# Requires: docker, gpg, curl. Installs cfssl/cfssljson to /usr/local/bin.
set -euo pipefail

# ---- 1. Set these to match your environment (or export them before running) ----
export HOST_PUBLIC_IP="${HOST_PUBLIC_IP:-$(curl -s https://ifconfig.me)}"
export HOST_PRIVATE_IP="${HOST_PRIVATE_IP:-$(hostname -I | awk '{print $1}')}"
export OMNI_ENDPOINT="${OMNI_ENDPOINT:-omni.internal}"
export AUTH_ENDPOINT="${AUTH_ENDPOINT:-auth.internal}"
export OMNI_USER_EMAIL="${OMNI_USER_EMAIL:-admin@omni.internal}"

echo "Public IP:  $HOST_PUBLIC_IP"
echo "Private IP: $HOST_PRIVATE_IP"

# Map internal hostnames locally so this host can resolve itself
grep -q "$OMNI_ENDPOINT" /etc/hosts || \
  echo "127.0.0.1 ${OMNI_ENDPOINT} ${AUTH_ENDPOINT}" | sudo tee -a /etc/hosts

# ---- 2. Install cfssl ----
if ! command -v cfssl >/dev/null; then
  CFSSL_VERSION=$(curl -sI https://github.com/cloudflare/cfssl/releases/latest \
    | grep -i location | awk -F '/' '{print $NF}' | tr -d '\r')
  curl -L -o cfssl \
    https://github.com/cloudflare/cfssl/releases/download/${CFSSL_VERSION}/cfssl_${CFSSL_VERSION#v}_linux_amd64
  curl -L -o cfssljson \
    https://github.com/cloudflare/cfssl/releases/download/${CFSSL_VERSION}/cfssljson_${CFSSL_VERSION#v}_linux_amd64
  chmod +x cfssl cfssljson
  sudo mv cfssl cfssljson /usr/local/bin/
fi

# ---- 3. Root CA ----
cat <<EOF > ca-csr.json
{
  "CN": "Internal Root CA",
  "key": { "algo": "rsa", "size": 4096 },
  "names": [{ "C": "US", "O": "Internal Infrastructure", "OU": "Security" }]
}
EOF
cfssl gencert -initca ca-csr.json | cfssljson -bare ca
sudo cp ca.pem /usr/local/share/ca-certificates/ca.crt
sudo update-ca-certificates

# ---- 4. Signing config + server cert ----
cat <<EOF > ca-config.json
{
  "signing": {
    "default": { "expiry": "8760h" },
    "profiles": {
      "web-server": { "usages": ["signing", "key encipherment", "server auth"], "expiry": "8760h" },
      "client": { "usages": ["signing", "key encipherment", "client auth"], "expiry": "8760h" }
    }
  }
}
EOF

cat <<EOF > wildcard-csr.json
{
  "CN": "Internal Wildcard",
  "hosts": ["${OMNI_ENDPOINT}", "${AUTH_ENDPOINT}", "127.0.0.1", "${HOST_PUBLIC_IP}", "${HOST_PRIVATE_IP}"],
  "key": { "algo": "rsa", "size": 4096 }
}
EOF

cfssl gencert -ca=ca.pem -ca-key=ca-key.pem -config=ca-config.json \
  -profile=web-server wildcard-csr.json | cfssljson -bare server
cat server.pem ca.pem > server-chain.pem
chmod 644 server*.pem

# ---- 5. etcd (GPG) encryption key ----
if [ ! -f omni.asc ]; then
  gpg --batch --passphrase '' --quick-generate-key \
    "Omni (Used for etcd data encryption) omni@internal.local" rsa4096 cert never
  FINGERPRINT=$(gpg --with-colons --list-keys "omni@internal.local" \
    | awk -F: '$1 == "fpr" {print $10; exit}')
  gpg --batch --passphrase '' --quick-add-key ${FINGERPRINT} rsa4096 encr never
  gpg --export-secret-key --armor omni@internal.local > omni.asc
fi

# ---- 6. Dex config + admin password ----
echo "Set the Omni admin password (used to log into the Omni UI):"
OMNI_USER_PASSWORD=$(docker run --rm httpd:2.4-alpine htpasswd -BnC 15 admin | cut -d: -f2)

cat <<EOF > dex.yaml
issuer: https://${AUTH_ENDPOINT}:5556

storage:
  type: memory

web:
  https: 0.0.0.0:5556
  tlsCert: /etc/dex/tls/server-chain.pem
  tlsKey: /etc/dex/tls/server-key.pem

enablePasswordDB: true

staticClients:
  - name: Omni
    id: omni
    secret: omni-dex-secret
    redirectURIs:
      - https://${OMNI_ENDPOINT}/oidc/consume

staticPasswords:
  - email: "${OMNI_USER_EMAIL}"
    username: "admin"
    preferredUsername: "admin"
    hash: "${OMNI_USER_PASSWORD}"
EOF

mkdir -p sqlite

echo ""
echo "Done. Generated in $(pwd): ca.pem, server-key.pem, server-chain.pem, omni.asc, dex.yaml, sqlite/"
echo "Now fill in .env (copy from .env.example) and deploy docker-compose.yml as a Portainer stack"
echo "from this same folder."
