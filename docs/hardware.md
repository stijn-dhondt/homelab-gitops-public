# Hardware Setup

Physical inventory — none of this is git-managed (it can't be), but it's the context every other
doc assumes.

## Network Components

- Routing: Ubiquiti Unifi Express 7 (UX7)
- Switching: Ubiquiti USW-Flex 8Port 2.5Gbps Managed (USW-FLEX-2.5G-8)

## Storage NAS

- Small NAS with Open Media Vault (Maiyunda)
  - 2.5Gbit network uplink
  - NFS with ZFS as backend
  - Volume 1: `/dev/nvme0n1p2` OS disk 250GB
  - Volume 2: `/dev/nvme1n1p1` DATA disk 512GB
  - Hosts Docker engine for PXE boot server

## Bare Metal Nodes

- **4x DELL Optiplex 3070** nodes
- 3 x Intel I5-9500T cpu 2,2Ghz as Control planes
- 1 x Intel I5-9500 cpu 3,0Ghz as the single worker node
- Replaced cooling paste on all CPU's
- **16GB RAM** per node
- **128GB** local storage (SSD)
- **1Gb** uplink to network switch
- Network interface: `enp1s0`
- Storage device: `sda`
- BIOS Configuration
  - Update to latest version 1.7.1
  - Enable **UEFI** mode
  - Disable **Secure Boot** (enable after cluster stabilization)
  - Boot priority: **PXE** → **HDD/SSD**
  - Turbo boost Disabled on the one with the I5-9500 cpu
  - Block Sleep Enabled
  - Advanced configurations ASPM L1 only selected
