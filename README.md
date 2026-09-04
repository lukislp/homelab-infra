# homelab-infra

Cluster-wide Kubernetes infrastructure for the k3s homelab that [studylife](https://github.com/lukislp/studylife),
[studylife-ai](https://github.com/lukislp/studylife-ai), [studylife-mcp](https://github.com/lukislp/studylife-mcp),
[piwatch](https://github.com/lukislp/piwatch), and [UnifiProtectDashboard](https://github.com/lukislp/UnifiProtectDashboard)
all run on. Split out of studylife's own `k8s/` folder, which had organically become the de
facto home for this shared infra alongside studylife's own app manifests — every other app repo
already followed a "small, genuinely app-scoped `k8s/`/`deploy/` folder, no infra of its own"
convention and depended on studylife's folder by file path for cert-manager, the shared Gateway,
Prometheus, and Flux's reconciler RBAC.

## What lives here vs. what stays in each app's own repo

- **`cluster/`** — MetalLB IP pool, cert-manager `ClusterIssuer`s, the shared `Gateway`
  (`studylife-gateway`), shared/monitoring-namespace `HTTPRoute`s and `NetworkPolicy`s, Pod
  Disruption Budgets for cluster-wide components (CoreDNS, NGINX Gateway Fabric). **Not**
  Flux-managed — applied once via the provisioning script or by hand.
- **`monitoring/`** — the whole Prometheus/Grafana/Loki/Promtail/node-exporter/kube-state-metrics/
  otel-collector/Tempo stack, shared by every app above. `01-prometheus.yaml`, the 3 grafana
  files (`05`/`06`/`07`), and `11-otel-collector.yaml`/`12-tempo.yaml` **are** Flux-managed (see
  `flux/infra-deploy/`); everything else here is applied once.
- **`flux/`** — Flux's own install manifest and the single shared reconciler RBAC
  (`flux-studylife-reconciler` ClusterRole/Binding) used by every app's Kustomization regardless
  of which repo it's defined in. **Each app's own `GitRepository`/`ImageRepository`/
  `ImagePolicy`/`ImageUpdateAutomation`/`Kustomization` objects stay in that app's own repo** —
  they already point at that app's own GitHub repo, this repo doesn't become a new root of trust.
- **`sealed-secrets/flux-system/`** — the shared git/registry credentials used by every
  GitRepository object above, historically named after studylife but reused by all of them.
- **`provisioning/`** — `setup-node.sh` (flash + provision a Pi node) and
  `bootstrap-cluster.ps1` (cluster-wide infra install: CNPG operator, MetalLB, ingress
  controller, applies everything in `cluster/` and `monitoring/`). Each app then runs its own
  bootstrap step from its own repo on top of this.

An app's own `k8s/`/`deploy/` folder keeps its own Namespace, Deployment/Service, HTTPRoute for
its own hostname, and NetworkPolicy scoped to its own namespace.

## Bootstrap order for a fresh cluster

1. `provisioning/setup-node.sh` on each Pi node.
2. `provisioning/bootstrap-cluster.ps1` from this repo — cluster-wide infra (CNPG operator,
   MetalLB, ingress controller, Flux install, everything in `cluster/` + `monitoring/`).
3. `studylife/k8s/bootstrap-cluster.ps1` — studylife's own app manifests.
4. Each other app's own bootstrap step, documented in its own repo.

## Image cache: embedded registry mirror

The three nodes pull every new `studylife-server` release from ghcr.io separately (about 400 MB,
10-13 s per node measured on 2026-09-05), and an HPA scale-up onto a node that has not seen the
current version yet pulls it again from the internet. k3s ships a distributed OCI mirror
(`embedded-registry: true`, Spegel): nodes serve image layers they already have to each other
over the LAN (TCP 5001), so only the first node fetches from upstream and the others get the
image in seconds. `provisioning/k3s/config.yaml` (server only) and `provisioning/k3s/registries.yaml` (every
node) are the node files; `setup-node.sh` writes them for new nodes.

Enable it on the existing nodes. `embedded-registry` is a SERVER flag: it turns the mirror on
for the whole cluster, and k3s-agent does not accept the key (an agent with that line in its
config.yaml fails to start - hit live on pinode02, 2026-09-05). Agents only need the registries
listed under `mirrors:` in their registries.yaml, which setup-node.sh already writes.

```bash
# pinode01 (server) only
sudo mkdir -p /etc/rancher/k3s
grep -q '^embedded-registry:' /etc/rancher/k3s/config.yaml 2>/dev/null || echo 'embedded-registry: true' | sudo tee -a /etc/rancher/k3s/config.yaml
sudo systemctl restart k3s

# pinode02 / pinode03 (agents): no config.yaml change, just pick up the setting
sudo systemctl restart k3s-agent
```

Verify from any machine with kubectl: `kubectl get nodes` stays Ready, and after the next release
the `Pulled` events on the second and third node show pull times of a few seconds instead of
10+ s (`kubectl -n studylife-scale get events --field-selector reason=Pulled`).

## Tracing

Phase 4 of the StudyLife telemetry rollout adds distributed tracing alongside the existing
Prometheus metrics and Loki logs. The studylife-server (.NET) sends spans via OTLP to
`otel-collector.monitoring.svc.cluster.local:4317`, sampled at 10% at the source (the collector
itself does no sampling, just batching/memory-limiting and fan-out - see
`monitoring/11-otel-collector.yaml`). Traces are stored in Tempo (`monitoring/12-tempo.yaml`),
local-disk backend, 7 day retention. To look at them: Grafana → Explore → the "Tempo"
datasource, or jump there directly from a log line in the "Loki" datasource that contains a
`TraceId`/`trace_id` field (log-to-trace link) - trace view then links back to the matching pod's
logs the other way (trace-to-log, by `pod`/`namespace`).

## Why this split, and what didn't move

Migrated out of `studylife/k8s/`, which had organically become the shared infra home alongside
studylife's own manifests. Everything genuinely shared moved here; each app's own Flux wiring
(`GitRepository`/`ImageRepository`/`ImagePolicy`/`ImageUpdateAutomation`/`Kustomization`)
deliberately stayed in that app's own repo, since the objects already point at that repo
regardless of where the YAML defining them physically lives — moving them here would just
relocate the same one-repo-owns-everything pattern instead of fixing it.
