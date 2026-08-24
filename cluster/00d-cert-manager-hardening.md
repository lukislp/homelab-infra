# cert-manager: resources and probes (manual patches)

cert-manager is installed from the upstream static manifest (v1.21), which ships all three
deployments without resource requests/limits, without a readiness probe on the controller and
without any probes on the cainjector - flagged by homelab-autodoc's findings page. Like the
Gateway API flag (00c-nginx-gateway-fabric.md), these are `kubectl patch`es on the live
deployments: **re-apply after every cert-manager upgrade**, a fresh upstream manifest resets
them.

Probe endpoints are what v1.21 actually serves (verified against the live pods): the
controller only exposes `/livez` on its http-healthz port (no `/readyz`), so readiness reuses
it - for a controller that serves no traffic, "ready" and "alive" are the same statement. The
cainjector exposes nothing but `/metrics`; probing it is a process-responsiveness check, the
best this version offers.

```bash
kubectl -n cert-manager patch deployment cert-manager --type=strategic -p '{
  "spec": {"template": {"spec": {"containers": [{
    "name": "cert-manager-controller",
    "resources": {"requests": {"cpu": "10m", "memory": "64Mi"},
                  "limits": {"cpu": "200m", "memory": "192Mi"}},
    "readinessProbe": {"httpGet": {"path": "/livez", "port": "http-healthz"},
                       "initialDelaySeconds": 10, "periodSeconds": 10, "timeoutSeconds": 15}
  }]}}}}'

kubectl -n cert-manager patch deployment cert-manager-cainjector --type=strategic -p '{
  "spec": {"template": {"spec": {"containers": [{
    "name": "cert-manager-cainjector",
    "resources": {"requests": {"cpu": "10m", "memory": "64Mi"},
                  "limits": {"cpu": "200m", "memory": "256Mi"}},
    "livenessProbe": {"httpGet": {"path": "/metrics", "port": "http-metrics"},
                      "initialDelaySeconds": 10, "periodSeconds": 10,
                      "timeoutSeconds": 15, "failureThreshold": 8},
    "readinessProbe": {"httpGet": {"path": "/metrics", "port": "http-metrics"},
                       "initialDelaySeconds": 5, "periodSeconds": 10, "timeoutSeconds": 15}
  }]}}}}'

kubectl -n cert-manager patch deployment cert-manager-webhook --type=strategic -p '{
  "spec": {"template": {"spec": {"containers": [{
    "name": "cert-manager-webhook",
    "resources": {"requests": {"cpu": "10m", "memory": "32Mi"},
                  "limits": {"cpu": "200m", "memory": "128Mi"}}
  }]}}}}'
```

The NetworkPolicies for the namespace live in `06-network-policies-cert-manager.yaml`
(a normal manifest, applied with the rest of `cluster/`) - the webhook port must stay open to
all sources, see the comment there.

Verification after patching: all three deployments roll out, and a server-side dry-run write
passes the webhook (proves the apiserver->webhook path still works under default-deny):

```bash
kubectl -n cert-manager rollout status deploy/cert-manager deploy/cert-manager-cainjector deploy/cert-manager-webhook
kubectl apply --dry-run=server -f cluster/01-cert-manager-issuers.yaml
```
