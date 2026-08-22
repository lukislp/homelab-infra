# Patch for the ingress-nginx controller

The official controller is installed via
`https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.11.3/deploy/static/provider/cloud/deploy.yaml`
(not fully vendored — the original file is large and maintained by the ingress-nginx
community). This file is deliberately **not** a `.yaml` file (it cannot be applied via
`kubectl apply -f` and is therefore outside the kubeconform CI check over `k8s/*.yaml`)
— it only documents the deviation from the standard deploy needed for this project: 2 replicas
instead of 1 (this is the "clustered LB" — multiple controller pods behind ONE MetalLB IP) +
the same soft anti-affinity as for web/worker/Redis.

A `kubectl apply -f` with only these deviations would fail ("spec.selector: Required
value", since `apply` expects a complete resource spec, not just a diff) — instead:

```bash
kubectl -n ingress-nginx scale deployment ingress-nginx-controller --replicas=2

kubectl -n ingress-nginx patch deployment ingress-nginx-controller --type=merge --patch-file=<(cat <<'PATCH'
{"spec":{"template":{"spec":{"affinity":{"podAntiAffinity":{"preferredDuringSchedulingIgnoredDuringExecution":[{"weight":100,"podAffinityTerm":{"labelSelector":{"matchLabels":{"app.kubernetes.io/component":"controller","app.kubernetes.io/name":"ingress-nginx"}},"topologyKey":"kubernetes.io/hostname"}}]}}}}}}
PATCH
)
```

Verified locally: after this process, 2 `ingress-nginx-controller` pods are running, both `Running`.

Additionally, resource requests/limits (the container name in the official deploy is `controller`):

```bash
kubectl -n ingress-nginx patch deployment ingress-nginx-controller --type=strategic --patch-file=<(cat <<'PATCH'
{"spec":{"template":{"spec":{"containers":[{"name":"controller","resources":{"requests":{"cpu":"50m","memory":"90Mi"},"limits":{"cpu":"200m","memory":"200Mi"}}}]}}}}
PATCH
)
```

The official "cloud" deploy also sets `--enable-metrics=false` by default — without changing
this, the ingress-nginx Grafana dashboard (see `k8s/17-grafana.yaml`) stays empty. Must be
switched to `true` (container `args` can only be replaced wholesale, individual flags cannot
be merged):

```bash
kubectl -n ingress-nginx patch deployment ingress-nginx-controller --type=strategic --patch-file=<(cat <<'PATCH'
{"spec":{"template":{"spec":{"containers":[{"name":"controller","args":["/nginx-ingress-controller","--publish-service=$(POD_NAMESPACE)/ingress-nginx-controller","--election-id=ingress-nginx-leader","--controller-class=k8s.io/ingress-nginx","--ingress-class=nginx","--configmap=$(POD_NAMESPACE)/ingress-nginx-controller","--validating-webhook=:8443","--validating-webhook-certificate=/usr/local/certificates/cert","--validating-webhook-key=/usr/local/certificates/key","--enable-metrics=true"]}]}}}}
PATCH
)
```

Verified locally: `nginx_ingress_controller_*` metrics then appear in Prometheus
(`curl http://prometheus.monitoring.svc.cluster.local:9090/api/v1/label/__name__/values`).
