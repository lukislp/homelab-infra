# NGINX Gateway Fabric: control-plane resources and liveness (manual patch)

NGF (static manifest, v2.6.x - see 00c-nginx-gateway-fabric.md) ships its control plane
without resource requests/limits and without a liveness probe. Same pattern as the
cert-manager and MetalLB patches: **re-apply after every NGF upgrade**, a fresh upstream
manifest resets it.

The liveness probe reuses `/readyz` on the health port - verified live: v2.6.7 serves no
`/livez` or `/healthz`, and for a controller that serves no traffic, ready and alive are the
same statement (same reasoning as the cert-manager controller's probe).

```bash
kubectl -n nginx-gateway patch deployment nginx-gateway --type=strategic -p '{
  "spec": {"template": {"spec": {"containers": [{
    "name": "nginx-gateway",
    "resources": {"requests": {"cpu": "25m", "memory": "64Mi"},
                  "limits": {"cpu": "300m", "memory": "256Mi"}},
    "livenessProbe": {"httpGet": {"path": "/readyz", "port": 8081},
                      "initialDelaySeconds": 15, "periodSeconds": 15, "timeoutSeconds": 5}
  }]}}}}'
```

Deliberately NOT patched: the data-plane deployment (`studylife-gateway-nginx`) is
provisioned and continuously reconciled by the control plane - direct patches get reverted.
Its resources and readiness probe already come through the `NginxProxy` resources; the CRD
exposes no livenessProbe field in v2.6, so the data plane's missing liveness stays accepted
until upstream adds one. That acceptance is machine-readable for homelab-autodoc through an
annotation the control plane itself stamps onto the deployment, via the NginxProxy's
`deployment.patches` (the supported way to reach the reconciled deployment - it survives
control-plane reconciles, unlike a direct patch):

```bash
kubectl -n nginx-gateway patch nginxproxy studylife-gateway-config --type=merge -p '{
  "spec": {"kubernetes": {"deployment": {"patches": [
    {"type": "StrategicMerge",
     "value": {"metadata": {"annotations": {
       "autodoc.homelab/accept-missing-probes":
         "NginxProxy exposes no livenessProbe field for the data plane in v2.6; readiness is configured and gates traffic - a wedged worker not being auto-restarted is the accepted residual risk"
     }}}}
  ]}}}}'
```

The NetworkPolicies live in `08-network-policies-nginx-gateway.yaml` - the data plane's 443
must accept all sources (LAN clients arrive via the MetalLB IP), the control plane's 8443
only from the data plane's agent, and :9113 from Prometheus.

Verification after patching:

```bash
kubectl -n nginx-gateway rollout status deploy/nginx-gateway
curl -s -o /dev/null -w '%{http_code}\n' https://studylife.lukas2311-homelab.com/   # data path still serves
```
plus a Gateway config change dry-run (any HTTPRoute apply) to prove the agent connection
still flows under default-deny.
