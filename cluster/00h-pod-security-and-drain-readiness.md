# Pod Security Standards + drain readiness (cluster-wide state)

Two cluster-wide properties that are only partly expressible in this repo's YAML, because
several namespaces and Deployments involved come from upstream static manifests or from k3s'
own packaged addons rather than from a file we own. Like `00c-nginx-gateway-fabric.md`, this is
deliberately **not** a `.yaml` file (outside the kubeconform CI check) — it documents state and
hand-applied commands.

Audited and applied 2026-09-13.

## 1. Pod Security Standards

Before this round, a namespace without any `pod-security.kubernetes.io/*` label ran at the API
server default — `privileged`. Nothing rejected, warned about or even audited a pod that ran as
root, privileged, or with host mounts.

The level per namespace was chosen by asking the API server itself rather than by reading
manifests:

```bash
kubectl label --dry-run=server --overwrite ns <ns> pod-security.kubernetes.io/enforce=restricted
kubectl label --dry-run=server --overwrite ns <ns> pod-security.kubernetes.io/enforce=baseline
```

A server-side dry run on a Namespace evaluates every pod that already exists in it and warns
about each violating one. `enforce` gates only pod *creation*, so a level the dry run reports as
clean can never evict something already running — the worst case is a rejected pod at the *next*
rollout, which the dry run has already ruled out.

### Namespaces whose labels live in an app repo

These carry their labels in their own `k8s/00-namespace.yaml` (or `k8s/namespace.yaml`) and are
applied by hand from there — the Flux kustomize-controller's least-privilege ClusterRole has no
permission on the `namespaces` resource at all, so those files are bootstrap-only:

| Namespace | enforce | Why not stricter |
| --- | --- | --- |
| `claude-queue` | `restricted` | — |
| `github-dashboard` | `restricted` | — |
| `homelab-hub` | `restricted` | — |
| `studylife-alexa` | `restricted` | — |
| `studylife-developers` | `restricted` | — |
| `studylife-mcp` | `restricted` | — |
| `studylife-webhooks` | `restricted` | — |
| `homelab-autodoc` | `baseline` | `autodoc-server` runs as uid 0 with unrestricted capabilities and no seccomp profile |
| `studylife-ai` | `baseline` | the `qdrant` image runs as root (`runAsUser=0`, `allowPrivilegeEscalation != false`) |
| `studylife-scale` | `baseline` | the 6 `redis-cluster` pods run as root with unrestricted capabilities |
| `unifiprotectdashboard` | `baseline` | the app pod runs as uid 0 with unrestricted capabilities |

All of them additionally carry `warn: restricted` + `audit: restricted`, so the four on
`baseline` keep reporting exactly what still stands between them and `restricted` — those four
are the open hardening backlog.

### Namespaces with no manifest in any repo (labelled by hand)

These namespaces are created by an upstream static manifest, by an operator, or by k3s itself,
so there is no file in git to put the labels in. They were labelled directly and must be
re-labelled after a cluster re-bootstrap:

```bash
# restricted-clean per server-side dry run (no violating pod)
for ns in nginx-gateway cert-manager cnpg-system; do
  kubectl label --overwrite ns "$ns" \
    pod-security.kubernetes.io/enforce=restricted \
    pod-security.kubernetes.io/warn=restricted \
    pod-security.kubernetes.io/audit=restricted
done

# flux-system: the vendored flux/00-install.yaml already sets warn=restricted upstream, so only
# enforce+audit are added here. A later "kubectl apply" of that vendored manifest does NOT strip
# these two: kubectl only prunes fields that were in its own last-applied-configuration, and
# these never were.
kubectl label --overwrite ns flux-system \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/audit=restricted

# tailscale: visibility only, deliberately NOT enforced (see the table below)
kubectl label --overwrite ns tailscale \
  pod-security.kubernetes.io/warn=baseline \
  pod-security.kubernetes.io/audit=baseline
```

### Namespaces deliberately left without an enforce label

| Namespace | Dry-run result | Reason |
| --- | --- | --- |
| `monitoring` | violates `baseline` | `node-exporter` needs host namespaces + hostPort, `piwatch-node-agent` needs `privileged` + hostPath, `promtail` needs hostPath. Already documented in `monitoring/00-namespace.yaml`; stays on `warn`/`audit: baseline`. |
| `tailscale` | clean at `baseline` | Operator-managed. The proxies running today are userspace-mode and baseline-clean, but the tailscale operator legitimately creates subnet routers / egress proxies that need `NET_ADMIN`, which `baseline` forbids — enforcing it would break a future proxy at creation time with no warning beforehand. `warn`/`audit: baseline` gives the signal without the failure mode. |
| `kube-system` | clean at `baseline` | k3s' own packaged addons live here and are re-applied on every k3s upgrade. A future k3s version adding a privileged addon (or re-enabling `servicelb`/klipper-lb, which needs hostPort + `NET_ADMIN`) would fail to start against an enforced `baseline` — during an upgrade, in the namespace that runs DNS. |
| `longhorn-system` | violates `baseline` | Already `enforce: privileged` — CSI plugins and engine images genuinely need `privileged` + hostPath. |
| `metallb-system` | violates `baseline` | Already `enforce: privileged` — the `speaker` DaemonSet needs host namespaces, hostPort and `NET_RAW`. |
| `velero` | violates `baseline` | Already `enforce: privileged` — the `node-agent` DaemonSet needs hostPath into the kubelet pod directory. |

## 2. Drain readiness (PodDisruptionBudgets)

A PDB reporting `disruptionsAllowed: 0` does not protect its workload — it blocks
`kubectl drain` of whichever node holds that pod, indefinitely, until somebody deletes the PDB
by hand. On a 1-replica Deployment, `minAvailable: 1` guarantees exactly that. Check with:

```bash
kubectl get pdb -A
```

State after the 2026-09-13 round:

| PDB | Before | After | Where the fix lives |
| --- | --- | --- | --- |
| `kube-system/coredns` | `minAvailable: 1`, allowed 0 | `maxUnavailable: 1`, allowed 1 | `cluster/04-pod-disruption-budgets.yaml` |
| `nginx-gateway/nginx-gateway` | `minAvailable: 1`, allowed 0 | `maxUnavailable: 1`, allowed 1 | `cluster/04-pod-disruption-budgets.yaml` |
| `studylife-scale/studylife-pg-pooler` | `minAvailable: 1` of 1, allowed 0 | `minAvailable: 1` of 2, allowed 1 | studylife repo, `k8s/11-pooler.yaml` → `instances: 2` |
| `claude-queue/claude-queue-pg-primary` | CNPG-managed, allowed 0 | PDB no longer created | claude-queue-platform repo, `k8s/02-postgres.yaml` → `enablePDB: false` |
| `studylife-scale/studylife-pg-primary` | CNPG-managed, allowed 0 | **unchanged, by design** | see below |
| `longhorn-system/instance-manager-*` | Longhorn-managed, allowed 0 | **unchanged, by design** | Longhorn releases these itself once the node's volumes are detached / rebuilt elsewhere |

### CoreDNS: why it is not simply 2 replicas

The CoreDNS Deployment is a k3s *packaged addon*
(`objectset.rio.cattle.io/owner-gvk: k3s.cattle.io/v1, Kind=Addon`, source
`/var/lib/rancher/k3s/server/manifests/coredns.yaml`). It is not a HelmChart, so there is no
`HelmChartConfig` to override it with, and a plain `kubectl scale` is reverted the next time k3s
re-applies the addon — i.e. on the next k3s upgrade, which is exactly when a drain happens. A
durable replica bump needs a file on the server node, outside this repo's GitOps scope.

Optional, non-durable pre-drain step if a DNS blip during the drain is unacceptable:

```bash
kubectl -n kube-system scale deploy/coredns --replicas=2   # reverts on the next k3s upgrade
# ... drain, maintain, uncordon ...
kubectl -n kube-system scale deploy/coredns --replicas=1
```

`maxUnavailable: 1` stays correct either way: at 2 replicas it keeps one pod up during the
drain, at 1 replica it lets the drain through.

### CNPG single-instance clusters: `enablePDB: false`

For a CNPG `Cluster` with `instances: 1`, the operator still creates a `<cluster>-primary` PDB
with `minAvailable: 1`, which can never allow a disruption. CNPG's own documented answer for
single-instance clusters is `.spec.enablePDB: false` — there is no HA to protect anyway, the
single instance is simply restarted wherever it lands. Applied to `claude-queue-pg`.

### CNPG multi-instance clusters: the primary PDB is supposed to block

`studylife-pg` runs `instances: 3`. CNPG creates two PDBs for it:

- `studylife-pg` — the replicas, `minAvailable: 1`, currently allows 1 disruption.
- `studylife-pg-primary` — the primary, `minAvailable: 1`, permanently `disruptionsAllowed: 0`.

The second is **not** a bug and must not be removed or loosened: it is what stops a node drain
from evicting the Postgres primary without a controlled failover. The supported ways to drain
the node that currently holds the primary:

```bash
# Option A - tell CNPG the cluster is in maintenance (reuses the cluster's nodeMaintenanceWindow):
kubectl cnpg maintenance set --all-namespaces
# ... kubectl drain <node> ... then:
kubectl cnpg maintenance unset --all-namespaces

# Option B - move the primary off the node first, then drain normally:
kubectl cnpg promote studylife-pg <instance-number-on-another-node>
```

Either way the drain of that one node is a deliberate two-step operation — not something to
"fix" in the PDB.
