# Installing NGINX Gateway Fabric (Gateway API)

Successor to ingress-nginx (archived by the Kubernetes project on 24.03.2026, no more
security updates — see `docs/SCALING.md`). As with CNPG/MetalLB/ingress-nginx, deliberately
installed via a static manifest instead of Helm (Helm is not present in the cluster and is
deliberately not used). Like `06b-ingress-nginx-patch.md`, this file is deliberately **not**
a `.yaml` file (outside the kubeconform CI check) — it documents the installation steps;
the project's own resources (Gateway, HTTPRoutes, policies), on the other hand, are versioned
in `k8s/07c-gateway.yaml` / `k8s/07d-httproutes.yaml` (+ `deploy/httproute.yaml` in the piwatch
repo).

```bash
# 1. Gateway API CRDs (standard channel), exactly the version NGF v2.6.7 expects
#    (bundle v1.5.1) - hence via NGF's own Kustomize ref instead of the generic
#    gateway-api release URL:
kubectl kustomize "https://github.com/nginx/nginx-gateway-fabric/config/crd/gateway-api/standard?ref=v2.6.7" | kubectl apply --server-side -f -

# 2. NGF-eigene CRDs + Control-Plane (Namespace nginx-gateway):
kubectl apply --server-side -f https://raw.githubusercontent.com/nginx/nginx-gateway-fabric/v2.6.7/deploy/crds.yaml
kubectl apply -f https://raw.githubusercontent.com/nginx/nginx-gateway-fabric/v2.6.7/deploy/default/deploy.yaml
```

Unlike ingress-nginx, NGF consists of two layers: the control-plane pod (`nginx-gateway`)
translates Gateway/HTTPRoute objects into NGINX configuration; the actual NGINX data plane
is only provisioned when a `Gateway` object is created (Deployment + LoadBalancer service
`<gateway-name>-nginx` in the Gateway's namespace — automatically gets the next free
MetalLB IP). 2 replicas + anti-affinity + resource limits for the data plane are therefore
NOT patched here, but set declaratively via the `NginxProxy` object in `k8s/07c-gateway.yaml`
(via `Gateway.spec.infrastructure.parametersRef`) — no equivalent to the manual
kubectl patch steps from `06b-ingress-nginx-patch.md` is needed anymore.

## cert-manager: enabling Gateway API support

cert-manager (static manifest, v1.21) only watches `Gateway` objects with an additional
controller flag (purely additive, Ingress behavior unchanged; the corresponding feature gate
`ExperimentalGatewayAPISupport` has been enabled by default since 1.15). Must happen AFTER
installing the Gateway API CRDs (otherwise cert-manager starts without a Gateway informer):

```bash
kubectl -n cert-manager patch deployment cert-manager --type=json \
  -p '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--enable-gateway-api"}]'
```

Verified live: after the rollout, the controller logs "enabling the sig-network Gateway API
certificate-shim", all existing certificates remain `Ready: True`, and the
`cert-manager.io/cluster-issuer` annotation on the Gateway automatically creates a Certificate
in the `nginx-gateway` namespace for each referenced listener secret.

## Important behavioral difference from ingress-nginx: SNI must match the Host header

For requests where the TLS SNI and the HTTP Host header belong to DIFFERENT listeners, NGF
responds, in compliance with the Gateway API specification, with **421 Misdirected Request**
(verified live; cannot be disabled, see nginx-gateway-fabric Discussion #4521). The previous
NPM pattern "SNI=X.home.lan, public Host header is passed through" therefore no longer works —
which is why the Gateway has TWO listeners per service (home.lan + public domain, same TLS
secret, the certificates cover both names as SAN). During the migration, NPM must be configured
per proxy host so that the SNI follows the forwarded Host header (Advanced config:
`proxy_ssl_server_name on; proxy_ssl_name $host;`) — then SNI and Host match the same listener
(verified live against the Gateway IP for both hostnames). In addition, curl/NGINX sends NO
SNI to a bare IP — the handshake is then rejected (`ssl_reject_handshake` in the default
server), so tests should always run against `--resolve <host>:443:<ip>` rather than directly
against the IP.
