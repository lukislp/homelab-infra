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
- **`monitoring/`** — the whole Prometheus/Grafana/Loki/Promtail/node-exporter/kube-state-metrics
  stack, shared by every app above. `01-prometheus.yaml` and the 3 grafana files (`05`/`06`/`07`)
  **are** Flux-managed (see `flux/infra-deploy/`); everything else here is applied once.
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

## Why this split, and what didn't move

Migrated out of `studylife/k8s/`, which had organically become the shared infra home alongside
studylife's own manifests. Everything genuinely shared moved here; each app's own Flux wiring
(`GitRepository`/`ImageRepository`/`ImagePolicy`/`ImageUpdateAutomation`/`Kustomization`)
deliberately stayed in that app's own repo, since the objects already point at that repo
regardless of where the YAML defining them physically lives — moving them here would just
relocate the same one-repo-owns-everything pattern instead of fixing it.
