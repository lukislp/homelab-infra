<#
.SYNOPSIS
  Bootstraps the cluster-wide infrastructure on an already-running K3s cluster: CNPG operator,
  MetalLB, cert-manager issuers, the shared Gateway, the monitoring stack, and (optionally) Flux.

.DESCRIPTION
  Runs on your LAPTOP (PowerShell), NOT on a Pi - assumes at least the K3s server node has
  already been set up via provisioning/setup-node.sh and KUBECONFIG points at the cluster. This
  is the generic, app-agnostic half of what used to be a single studylife/k8s/bootstrap-
  cluster.ps1 - part of the cluster-wide-infra split (see README.md). Run this FIRST on a fresh
  cluster, then each app's own bootstrap-cluster.ps1 (studylife's, studylife-ai's, ...).

  NOT included (deliberately):
    - Loki/Promtail (log aggregation) - Promtail demonstrably yields 0 targets on a fresh
      cluster, so it's skipped by default. Include it anyway with -WithLoki.
    - Flux install - needs the studylife-git-auth/studylife-registry-auth secrets created
      manually BEFOREHAND (real credentials, see README.md), which this script deliberately
      never creates itself. Include it anyway with -WithFlux (only useful if both secrets
      already exist).
    - cert-manager itself (the controller/CRDs, as opposed to the ClusterIssuers in
      cluster/01-cert-manager-issuers.yaml) - install via its own upstream instructions first,
      this script only provisions the issuers that depend on it.
    - NGINX Gateway Fabric (the Gateway API controller/CRDs) - see
      cluster/00c-nginx-gateway-fabric.md for the manual install steps; this script only applies
      the Gateway object itself (cluster/02-gateway.yaml), not the controller.
    - The vendored community Grafana dashboards (monitoring/06-grafana-community-dashboards.yaml,
      >250KB) - blows past kubectl apply's client-side last-applied-configuration annotation
      limit (256KiB). Applied EXCLUSIVELY via Flux's own Kustomization (flux/infra-deploy/),
      which uses server-side apply and has no such limit - see -WithFlux.

  Idempotent: kubectl apply is idempotent by nature.

.PARAMETER GrafanaHost
  Optional: additional hostname for Grafana beyond the ones already committed in
  cluster/02-gateway.yaml - only needed if you're adapting this for a different domain, not for
  a normal bootstrap.

.EXAMPLE
  .\bootstrap-cluster.ps1
  .\bootstrap-cluster.ps1 -WithLoki -WithFlux
#>
param(
    [switch]$WithLoki,
    [switch]$WithFlux
)

$ErrorActionPreference = "Stop"
$RepoDir = Split-Path -Parent $PSScriptRoot

function Wait-Deployment {
    param([string]$Namespace, [string]$Name, [int]$TimeoutSec = 180)
    Write-Host "Waiting for deployment ${Namespace}/${Name}..."
    kubectl -n $Namespace rollout status "deployment/$Name" --timeout="${TimeoutSec}s"
}

Write-Host "=== [1/6] Checking cluster reachability ==="
kubectl get nodes
if ($LASTEXITCODE -ne 0) {
    throw "kubectl cannot reach the cluster - is KUBECONFIG set? (`$env:KUBECONFIG)"
}

Write-Host ""
Write-Host "=== [2/6] CloudNativePG operator ==="
# Cluster-wide operator (installs into cnpg-system) - any app needing Postgres can use it, not
# just studylife, hence living here rather than in any single app's bootstrap script.
kubectl apply --server-side -f https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-1.29/releases/cnpg-1.29.1.yaml
Wait-Deployment -Namespace "cnpg-system" -Name "cnpg-controller-manager"
# The upstream manifest ships the operator with a 100m CPU limit and 1-second probes. On this
# cluster that was the amplifier of the 2026-09-04 incident: under node load the probes timed out,
# the kubelet restarted the operator mid-failover (29 restarts), and every restart re-initiated a
# Postgres failover that never completed. Same values as the live hotfix applied that night.
kubectl -n cnpg-system patch deploy cnpg-controller-manager --type=json -p '[{"op":"replace","path":"/spec/template/spec/containers/0/resources","value":{"requests":{"cpu":"200m","memory":"200Mi"},"limits":{"cpu":"500m","memory":"400Mi"}}},{"op":"replace","path":"/spec/template/spec/containers/0/livenessProbe/timeoutSeconds","value":5},{"op":"replace","path":"/spec/template/spec/containers/0/livenessProbe/failureThreshold","value":6},{"op":"replace","path":"/spec/template/spec/containers/0/readinessProbe/timeoutSeconds","value":5}]'
Wait-Deployment -Namespace "cnpg-system" -Name "cnpg-controller-manager"

Write-Host ""
Write-Host "=== [3/6] Installing MetalLB ==="
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.14.9/config/manifests/metallb-native.yaml
Wait-Deployment -Namespace "metallb-system" -Name "controller"

Write-Host ""
Write-Host "=== [4/6] Applying cluster/ manifests ==="
# No more placeholder substitution needed here (unlike the old studylife script's -MetalLBRange
# param) - cluster/00-metallb-config.yaml already carries the real, git-committed range, see the
# INCIDENT note in that file for why it must stay that way.
$clusterFiles = Get-ChildItem (Join-Path $RepoDir "cluster") -Filter "*.yaml" | Sort-Object Name
foreach ($f in $clusterFiles) {
    Write-Host "  apply: $($f.Name)"
    kubectl apply -f $f.FullName
    if ($LASTEXITCODE -ne 0) { throw "kubectl apply failed for $($f.Name)" }
}

Write-Host ""
Write-Host "=== [5/6] Applying monitoring/ manifests ==="
$skip = @()
if (-not $WithLoki) { $skip += @("08-loki.yaml", "09-promtail.yaml") }
# Always skipped (cannot be enabled via a switch, see the .DESCRIPTION note above) - only
# applied via Flux's infra-deploy Kustomization (-WithFlux).
$skip += "06-grafana-community-dashboards.yaml"

$monitoringFiles = Get-ChildItem (Join-Path $RepoDir "monitoring") -Filter "*.yaml" | Sort-Object Name
foreach ($f in $monitoringFiles) {
    if ($skip -contains $f.Name) {
        Write-Host "  skipping $($f.Name)"
        continue
    }
    Write-Host "  apply: $($f.Name)"
    kubectl apply -f $f.FullName
    if ($LASTEXITCODE -ne 0) { throw "kubectl apply failed for $($f.Name)" }
}

if ($WithFlux) {
    Write-Host ""
    Write-Host "=== [6/6] Flux (GitOps) ==="
    # Both secrets must be created by hand BEFOREHAND (real credentials, see README.md) - this
    # script deliberately never creates them itself. Shared by every GitRepository on the
    # cluster (studylife, studylife-ai, studylife-mcp, piwatch, unifiprotectdashboard,
    # homelab-infra itself), not studylife-specific despite the name.
    kubectl -n flux-system get secret studylife-git-auth, studylife-registry-auth 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw "Secrets 'studylife-git-auth'/'studylife-registry-auth' are missing in namespace 'flux-system' - see README.md, Flux section."
    }
    kubectl apply -f (Join-Path $RepoDir "flux/00-install.yaml")
    Wait-Deployment -Namespace "flux-system" -Name "source-controller"
    Wait-Deployment -Namespace "flux-system" -Name "kustomize-controller"
    Wait-Deployment -Namespace "flux-system" -Name "image-reflector-controller"
    Wait-Deployment -Namespace "flux-system" -Name "image-automation-controller"
    kubectl apply -f (Join-Path $RepoDir "flux/01-reconciler-rbac.yaml")
    kubectl apply -f (Join-Path $RepoDir "flux/02-git-source.yaml")
    kubectl apply -f (Join-Path $RepoDir "flux/03-kustomization.yaml")
    Write-Host "  homelab-infra registered as its own Flux source - each app now bootstraps its"
    Write-Host "  own Flux wiring separately, see that app's own bootstrap/README."
}

$ErrorActionPreference = "Continue"

Write-Host ""
Write-Host "=== Gateway / MetalLB IP ==="
kubectl -n nginx-gateway get svc studylife-gateway-nginx

Write-Host ""
Write-Host "=== Monitoring ==="
Write-Host "Grafana (temporary, before the Gateway/DNS is set up): kubectl -n monitoring port-forward svc/grafana 3000:80"
Write-Host "  Login admin/admin, change it right after the first login."

Write-Host ""
Write-Host "Done. Next: install cert-manager and NGINX Gateway Fabric per their own upstream docs"
Write-Host "(cluster/00c-nginx-gateway-fabric.md has the NGF steps this repo relies on), then run"
Write-Host "each app's own bootstrap-cluster.ps1 (studylife's first, for the shared Postgres/Redis"
Write-Host "no other app currently depends on)."
