# MetalLB: resources (manual patches)

MetalLB is installed from the upstream static manifest (v0.14.9), which ships controller and
speaker without resource requests/limits - flagged by homelab-autodoc's findings page.
Upstream security posture is already solid (privilege escalation off, capabilities dropped,
read-only root filesystem, non-root controller); the speaker's root is required by design
(host network, NET_RAW for ARP/NDP announcements) and stays as an accepted finding.

Like cert-manager's patches (00d-cert-manager-hardening.md): **re-apply after every MetalLB
upgrade**, a fresh upstream manifest resets them.

```bash
kubectl -n metallb-system patch deployment controller --type=strategic -p '{
  "spec": {"template": {"spec": {"containers": [{
    "name": "controller",
    "resources": {"requests": {"cpu": "10m", "memory": "64Mi"},
                  "limits": {"cpu": "200m", "memory": "128Mi"}}
  }]}}}}'

kubectl -n metallb-system patch daemonset speaker --type=strategic -p '{
  "spec": {"template": {"spec": {"containers": [{
    "name": "speaker",
    "resources": {"requests": {"cpu": "10m", "memory": "64Mi"},
                  "limits": {"cpu": "200m", "memory": "128Mi"}}
  }]}}}}'
```

The NetworkPolicies live in `07-network-policies-metallb.yaml` (applied with the rest of
`cluster/`) - the webhook port must stay open to all sources, see the comment there.

Verification after patching: both workloads roll out (the speaker rollout briefly interrupts
L2 announcement per node - existing connections survive, new LoadBalancer traffic fails over
within seconds), and a server-side dry-run write passes the webhook:

```bash
kubectl -n metallb-system rollout status deployment/controller daemonset/speaker
kubectl apply --dry-run=server -f cluster/00-metallb-config.yaml
```
