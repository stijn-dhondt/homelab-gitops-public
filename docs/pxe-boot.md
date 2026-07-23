# PXE Boot Configuration

How the bare-metal nodes get Talos Linux onto them over the network — only needed when
provisioning a node from scratch (a wipe, a new node, hardware replacement). Once a node is
running, this isn't touched again.

## Overview

PXE (Preboot eXecution Environment) allows bare metal nodes to boot Talos Linux from the network.
The boot server runs in a Docker container on the NAS (VLAN 10) — see
[hardware.md](hardware.md) and [network.md](network.md) for where that fits.

## Prerequisites

- Docker and Docker Compose installed on NAS (Maiyunda)
- Network connectivity between NAS (VLAN 10) and cluster nodes (VLAN 20)
- DHCP server configured on Unifi for VLAN 20
- PXE options set on VLAN 20 network (Unifi) Boot server and file
  - Boot Server (Next Server): `10.0.10.13` (NAS IP)
  - Boot Filename: `snp.efi`

## Step 1: Obtain Talos Schematic ID

Generate a custom Talos image with your required customizations at https://factory.talos.dev/:

1. Visit the factory website
2. Configure system extensions (if needed)
3. Copy the generated **Schematic ID**

The schematic actually used to build the running nodes (with the `iscsi-tools`/`util-linux-tools`
extensions Longhorn needs) is tracked in
[clusters/talos-dev/talos/README.md](../clusters/talos-dev/talos/README.md), not here — this page
is about the PXE mechanism, not the current schematic's contents.

## Step 2: Configure PXE Boot Server on NAS and start container

Create `booter_compose.yaml` on the NAS:

```yaml
services:
  booter:
    # https://github.com/siderolabs/booter
    image: ghcr.io/siderolabs/booter:v0.3.0
    container_name: talos-booter
    network_mode: host # Required for DHCP proxy functionality
    restart: unless-stopped
    command:
      - --talos-version=v1.13.3 # Define Talos version to be used
      - --schematic-id=<schematic-id> # ← from Step 1, or clusters/talos-dev/talos/README.md
```

## Step 3: PXE Boot Nodes

This will boot into Talos if everything is configured as laid out. As from now the OS lives in
memory and is in the state "Maintenance mode". From this point the node is ready for configuration
and cluster creation — see [cluster-bootstrap.md](cluster-bootstrap.md).

## References

- [Talos Linux Documentation](https://www.talos.dev/)
- [Talos Factory (Schematic Generator)](https://factory.talos.dev/)
- [Siderolabs Booter](https://github.com/siderolabs/booter)
