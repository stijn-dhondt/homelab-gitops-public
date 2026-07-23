# Quick Reference

## Common Commands

```bash
# Cluster status
talosctl health
talosctl nodes

# View logs
talosctl logs -n 10.0.20.11 -k <service-name>

# Reboot nodes
talosctl reboot -n 10.0.20.11

# Check disk layout
talosctl get disks -n 10.0.20.11

# Verify Cilium
cilium status
cilium connectivity test

# Kubernetes commands
kubectl get nodes
kubectl get pods -A
kubectl top nodes
kubectl top pods -A
```

## References

- [Talos Linux Documentation](https://www.talos.dev/)
- [Talos Factory (Schematic Generator)](https://factory.talos.dev/)
- [Siderolabs Booter](https://github.com/siderolabs/booter)
- [Cilium Documentation](https://docs.cilium.io/)
- [Kubernetes Documentation](https://kubernetes.io/docs/)
- [Sidero Labs](https://www.siderolabs.com/)
- [Ubiquiti Unifi VLAN Configuration](https://help.ui.com/articles/222269098)
