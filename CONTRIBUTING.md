# Contributing to homelab-infra

Thanks for taking the time. This repository holds the cluster-wide k3s infrastructure manifests
shared by several applications, so a change here can affect all of them. It is a single-maintainer
project and the process is deliberately small - but it is the same for every change, including the
maintainer's own.

## How changes get in

1. Open an issue first for anything bigger than a typo, so the direction can be agreed before you
   spend time on it. Use the templates under `.github/ISSUE_TEMPLATE/`.
2. Fork the repository (or branch, if you have write access) and make your change on a branch.
3. Open a pull request against `main`. The pull-request template asks for what changed and why.
4. `main` is protected: a PR merges only after `validate` and `review / dependency-review` are
   green and the branch is up to date with `main` (enable auto-merge and it lands on its own once
   that is the case). Nobody pushes to `main` directly, not even the maintainer.

## What belongs here

Cluster-wide infrastructure only: MetalLB configuration, cert-manager issuers, the shared Gateway
and shared HTTPRoutes, pod disruption budgets, network policies, Velero and Longhorn values, the
monitoring stack, the Flux control plane and the sealed secrets that go with them. Anything that
belongs to a single application stays in that application's own repository. The README's
"Why this split, and what didn't move" section is the reference when in doubt.

## What a pull request needs

- **Conventional Commits.** Commit and pull-request titles follow Conventional Commits
  (`feat:`, `fix:`, `docs:`, `ci:`, and so on), the same convention used across these
  repositories. Squash-merge keeps the PR title as the commit message. This repository is not
  versioned by semantic-release - Flux reconciles whatever `main` says.
- **Green required checks.** `validate` and `review / dependency-review` are required; a red one
  blocks the merge.
- **Strictly valid YAML.** [`.github/workflows/validate.yml`](.github/workflows/validate.yml) loads
  every `*.yaml`/`*.yml` outside `.git` and `.github` with a strict loader that **rejects duplicate
  keys**. This matters: PyYAML and `kubectl` tolerate a duplicated key, kustomize and Flux do not,
  so a file that looks fine locally can still break reconciliation. Let the check run before you
  assume a manifest is good.
- **The Flux kustomization still has to render.** `validate` runs
  `kubectl kustomize --load-restrictor LoadRestrictionsNone flux/infra-deploy` and then schema-checks
  the rendered output as well as the individual manifests, with `kubeconform -strict` against the
  default schemas plus the datree CRD catalog.
- **Secrets are sealed, never plain.** Anything under `sealed-secrets/` is committed as a
  SealedSecret. Never commit a plain `Secret`, and never patch a live secret in the cluster by
  hand - the controller reverts it, and Flux only applies what is in Git.
- **Say what it touches.** Name the affected namespaces and applications in the PR body. A change
  to the shared Gateway, a network policy or a PDB can take down an unrelated workload.

## Running the checks locally

There is no application code and no test suite; `validate` is the gate. You can run its parts
yourself:

```bash
kubectl kustomize --load-restrictor LoadRestrictionsNone flux/infra-deploy > /tmp/infra-deploy.yaml

kubeconform -strict -summary -ignore-missing-schemas \
  -schema-location default \
  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
  /tmp/infra-deploy.yaml
```

CI pins `kubeconform` to v0.8.0 and verifies its checksum before installing it.

## Layout

- `cluster/` - MetalLB, cert-manager issuers, the shared Gateway and HTTPRoutes, PDBs, network
  policies, Velero and Longhorn values, plus the runbook markdown files
- `flux/` - the Flux install, reconciler RBAC, Git source and kustomization; `flux/infra-deploy/`
  is the only Flux-reconciled kustomization
- `monitoring/` - Prometheus, node-exporter, kube-state-metrics, Grafana with its dashboards and
  alerting, Loki, Promtail, Uptime Kuma, the OTel collector and Tempo
- `provisioning/` - `setup-node.sh` per node, then `bootstrap-cluster.ps1`
- `sealed-secrets/` - the sealed secrets, by namespace

## Security issues

Please do not open a public issue for a vulnerability - use the private reporting path described
in [SECURITY.md](SECURITY.md). The [Code of Conduct](CODE_OF_CONDUCT.md) applies to every
interaction in this repository.
