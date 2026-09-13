# MetalLB: resources (manual patches)

MetalLB is installed from the upstream static manifest (v0.14.9), which ships controller and
speaker without resource requests/limits - flagged by homelab-autodoc's findings page.
Upstream security posture is already solid (privilege escalation off, capabilities dropped,
read-only root filesystem, non-root controller); the speaker's root is required by design
(host network, NET_RAW for ARP/NDP announcements) and is acknowledged as an accepted
finding via the annotation below - autodoc lists it under "Accepted Findings" with that
reason instead of as an open item.

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

kubectl -n metallb-system annotate daemonset speaker --overwrite \
  autodoc.homelab/accept-run-as-root-allowed='upstream-pinned by design: L2 announcement needs raw ARP/NDP sockets on the host network and the manifest ships the speaker without runAsNonRoot'
```

## Probe budget

The upstream manifest also leaves every probe at the Kubernetes default `timeoutSeconds: 1`.
That is what actually restarts MetalLB on this cluster - the controller had 31 restarts and the
speakers 5-15, every one of them a `context deadline exceeded` on `/metrics`, never a real
fault. See `00i-probe-timeout-budget.md` for the full diagnosis.

Unlike the resource patches above, this one is **automated** in
`provisioning/bootstrap-cluster.ps1` right after the MetalLB install, because it is the one
that causes restarts. It is repeated here so that a manual MetalLB upgrade (which resets it)
can be fixed without rerunning the whole bootstrap:

```bash
METALLB_PROBES='[{"op":"replace","path":"/spec/template/spec/containers/0/livenessProbe/timeoutSeconds","value":5},{"op":"replace","path":"/spec/template/spec/containers/0/livenessProbe/failureThreshold","value":5},{"op":"replace","path":"/spec/template/spec/containers/0/readinessProbe/timeoutSeconds","value":5},{"op":"replace","path":"/spec/template/spec/containers/0/readinessProbe/failureThreshold","value":3}]'

kubectl -n metallb-system patch deployment controller --type=json -p "$METALLB_PROBES"
kubectl -n metallb-system patch daemonset  speaker    --type=json -p "$METALLB_PROBES"
```

`--type=json` on purpose: if a future MetalLB version renames or drops those probe fields the
patch fails loudly instead of silently adding a probe that does nothing.

The NetworkPolicies live in `07-network-policies-metallb.yaml` (applied with the rest of
`cluster/`) - the webhook port must stay open to all sources, see the comment there.

Verification after patching: both workloads roll out (the speaker rollout briefly interrupts
L2 announcement per node - existing connections survive, new LoadBalancer traffic fails over
within seconds), and a server-side dry-run write passes the webhook:

```bash
kubectl -n metallb-system rollout status deployment/controller daemonset/speaker
kubectl apply --dry-run=server -f cluster/00-metallb-config.yaml
```
