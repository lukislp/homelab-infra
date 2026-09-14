# Probe timeout budget on arm64 (why nothing here runs at `timeoutSeconds: 1`)

## The finding

Containers on `pinode03` were being restarted several times a day. It is **not** OOM (no kernel
OOM kills, no `OOMKilled` container reason) and **not** a k3s/containerd restart (the unit has
been active since 2026-09-04 with `NRestarts=0`). Every single one of them is a **probe
timeout**:

```
Liveness probe failed: Get "http://10.42.4.27:9440/healthz":
  context deadline exceeded (Client.Timeout exceeded while awaiting headers)
```

`timeoutSeconds` defaults to **1** in Kubernetes, and almost every upstream manifest leaves it
there. `pinode03` is a 4 GB arm64 node that runs with well under 1 GB available and swap in
use; `pinode01` is a 4 GB node too. Under a load spike an HTTP handler that is perfectly
healthy simply does not get scheduled and answer within one second. The kubelet counts that as
a failure, `failureThreshold` (default 3) is reached, and the container is killed.

A 1-second probe on this hardware measures **node load, not process health**. 103
timeout-type `Unhealthy` events were recorded across the cluster, and their distribution
matched the restart counts workload for workload.

## The rule

For every workload in this cluster:

* HTTP probes get `timeoutSeconds: 5` (never below 3).
* `failureThreshold` is at least 3; **5** for the monitoring DaemonSets/exporters, which are
  the loudest offenders and the least critical thing running - a scrape gap is cheaper than a
  restart loop on the node that is already the bottleneck.
* `periodSeconds`, the probe path, port and type stay untouched. Probes are never disabled -
  the point is to make them a health signal again, not to stop looking.

## Where it is enforced, per component

| Component | Installed from | Where the budget lives |
| --- | --- | --- |
| `monitoring/*` (prometheus, grafana, loki, promtail, node-exporter, kube-state-metrics, uptime-kuma, otel-collector, tempo) | this repo | in the manifests themselves |
| Flux controllers | `flux/00-install.yaml` (generated, locally modified) | in that file - **a regenerated `flux install` must re-apply it** |
| CloudNativePG operator | upstream release manifest | `kubectl patch` in `provisioning/bootstrap-cluster.ps1` |
| MetalLB controller + speaker | upstream static manifest | `kubectl patch` in `provisioning/bootstrap-cluster.ps1` |
| cert-manager | upstream static manifest, installed by hand | `00d-cert-manager-hardening.md` |
| sealed-secrets controller | upstream static manifest, installed by hand | below |
| Velero, tailscale operator | Helm | chart defaults are already generous (5-10 s) - nothing to do |
| Longhorn | Helm + its own operator | see "Not fixable from git" |
| coredns, metrics-server, local-path-provisioner | k3s packaged addons | see "Not fixable from git" |

## sealed-secrets controller (manual patch)

Installed into `kube-system` from the upstream static manifest (bitnami
`sealed-secrets-controller:0.38.4`), like cert-manager and MetalLB - so like those,
**re-apply after every upgrade**, a fresh upstream manifest resets it. It had 22 restarts,
all probe timeouts; losing the controller means SealedSecrets stop being unsealed.

```bash
kubectl -n kube-system patch deployment sealed-secrets-controller --type=strategic -p '{
  "spec": {"template": {"spec": {"containers": [{
    "name": "sealed-secrets-controller",
    "livenessProbe":  {"timeoutSeconds": 5, "failureThreshold": 5},
    "readinessProbe": {"timeoutSeconds": 5, "failureThreshold": 3}
  }]}}}}'

kubectl -n kube-system rollout status deployment/sealed-secrets-controller
```

## Before rolling any DaemonSet on this cluster: check its tolerations

`pinode01` carries **two** taints: the usual control-plane one and
`studylife/relief=true:NoSchedule` (keeps app workloads off the control-plane node after the
2026-09 Longhorn rebalance). `NoSchedule` does not evict, so a DaemonSet pod that was already
running on `pinode01` when the taint was added keeps running there and everything looks
healthy - until the **first rollout** of that DaemonSet, at which point the pod is deleted and
cannot come back. The DaemonSet quietly goes from 3 nodes to 2.

This is exactly what the probe rollout did to `node-exporter` and `promtail` on 2026-09-13
(fixed in the same pass by giving both the toleration `piwatch`'s node-agent already had).
Checked and fixed at the same time: `metallb-system/speaker` and `velero/node-agent`, both of
which were sitting on the same landmine.

```bash
# Which DaemonSets would lose pinode01 on their next rollout?
kubectl get ds -A -o json | jq -r '
  .items[] | select([.spec.template.spec.tolerations[]?.key]
    | index("studylife/relief") | not)
  | "\(.metadata.namespace)/\(.metadata.name)"'
```

As of 2026-09-13 that leaves only Longhorn's three DaemonSets (`longhorn-manager`,
`longhorn-csi-plugin`, `engine-image-*`), which ship with **no** tolerations at all and are
therefore on the same landmine: today they run on `pinode01` only because they were scheduled
before the taint existed. The chart route is `defaultSettings.taintToleration` in
`11-longhorn-values.yaml` (Longhorn propagates it to its own components).

**Status 2026-09-14: staged, not yet in effect.** The Longhorn 1.7 setting reference says the
change is safe to make while volumes are attached - the components are simply not restarted -
so the value was set live without a helm upgrade:

```bash
kubectl -n longhorn-system patch settings.longhorn.io taint-toleration   --type=merge -p '{"value":"studylife/relief=true:NoSchedule"}'
```

All 27 attached volumes stayed `attached/healthy` through it. The setting now reports
`applied: false` and the three DaemonSets still carry no tolerations, exactly as documented:
Longhorn applies it once every volume is detached. So the landmine is **still live today** -
do not roll a Longhorn DaemonSet until `kubectl -n longhorn-system get settings.longhorn.io
taint-toleration -o jsonpath='{.status.applied}'` reports `true`. The value is recorded in
`11-longhorn-values.yaml` so a later helm upgrade cannot silently drop it.

## Not fixable from git

### coredns / metrics-server / local-path-provisioner (k3s packaged addons)

These carry `objectset.rio.cattle.io/*` annotations: they are applied by k3s' own deploy
controller from `/var/lib/rancher/k3s/server/manifests/` on the control-plane node
(`pinode01`), and **k3s re-applies them on every k3s restart and every k3s upgrade**. A
`kubectl patch` against the live object works until then and is then silently reverted, so it
is not written down here as a supported step.

`HelmChartConfig` - the normal k3s override mechanism - does **not** apply to them either:
`kubectl get helmchart -A` is empty in this cluster (Traefik is disabled, NGINX Gateway Fabric
is used instead), i.e. these three are plain manifests, not k3s HelmCharts.

The supported route requires shell access on `pinode01` and is a deliberate decision, not a
side effect of a probe fix, which is why it has not been taken:

1. Drop the packaged copy: `touch /var/lib/rancher/k3s/server/manifests/coredns.yaml.skip`
   (k3s skips any packaged manifest with a matching `.skip` file), or add
   `disable: [coredns, metrics-server]` to `provisioning/k3s/config.yaml`.
2. Vendor the manifest into this repo with the probe budget applied, and apply it like any
   other file in `cluster/`.

That trades "k3s keeps these up to date for you" for "this repo owns DNS and the metrics API".
Current restart counts for these three are low (coredns 4, metrics-server 6, local-path 0 - it
has no probes at all), so the trade is not worth making yet. Revisit if coredns starts
restarting during load spikes, because DNS flapping amplifies into every other workload.

### Longhorn `longhorn-csi-plugin` and `engine-image-*`

Both DaemonSets are created at runtime by `longhorn-manager` (the driver deployer), not by the
Helm chart, and chart `1.7.2` exposes no probe fields for them - the same "the chart offers no
field to change it" situation already documented in `11-longhorn-values.yaml`. Their probes are
already at `timeoutSeconds: 4`, so the 1-second problem does not apply.

`longhorn-csi-plugin` on `pinode03` does restart (31 times), but for a *different* reason:
`Liveness probe failed: HTTP probe failed with statuscode: 500`. That is the
`longhorn-liveness-probe` sidecar reporting that the CSI driver did not answer its gRPC probe -
a real signal, not a timeout, and raising a timeout would not address it. Tracked separately.
