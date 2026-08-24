# Velero: nightly application PVC backups to R2

Postgres already has offsite backups (CNPG barman -> R2, 7d retention). Everything else
worth keeping lived only on local-path PVs on the Pis: uptime-kuma's manually configured
monitors, grafana's manually configured Telegram contact point, autodoc's changelog/drift
history + admin config, homelab-hub's link data, qdrant's embeddings. A node SSD failure
meant losing them.

## Build vs. buy

A self-built orchestrator (scale down -> tar -> upload -> scale up, guaranteed-restart
trap, per-namespace RBAC) was designed first and deliberately discarded: Velero covers the
same requirements as the industry-standard tool - kopia file-system backups (compressed,
deduplicated), per-schedule TTL retention exactly like CNPG's, pre-backup hooks solving
consistency WITHOUT downtime, Prometheus metrics for alerting, and a real restore CLI.
Choosing and integrating the standard beats re-implementing it. Not chosen: CSI snapshots
(local-path has none - that's why the node-agent/file-system mode), Kasten/Stash
(license-gated), K8up (fine, but Velero's single-credential model fits the shared-token
requirement better).

## Install (by hand, like the other operators - no helm-controller in this cluster)

```bash
helm repo add vmware-tanzu https://vmware-tanzu.github.io/helm-charts
kubectl create namespace velero
kubectl label ns velero pod-security.kubernetes.io/enforce=privileged  # node-agent mounts /var/lib/kubelet/pods
helm upgrade --install velero vmware-tanzu/velero -n velero -f cluster/10-velero-values.yaml
```

## Credentials: ONE R2 token for every offsite backup

Velero reuses the exact token CNPG's barman uses - deliberately: revoking that one token
at Cloudflare kills every offsite backup path at once. It lives in TWO cluster secrets;
rotation is one command block:

```bash
AK=<new access key id>; SK=<new secret access key>
kubectl -n studylife-scale create secret generic r2-backup-credentials \
  --from-literal=ACCESS_KEY_ID="$AK" --from-literal=ACCESS_SECRET_KEY="$SK" \
  --dry-run=client -o yaml | kubectl apply -f -
printf "[default]\naws_access_key_id=%s\naws_secret_access_key=%s\n" "$AK" "$SK" \
  | kubectl -n velero create secret generic velero-r2-credentials \
      --from-file=cloud=/dev/stdin --dry-run=client -o yaml | kubectl apply -f -
kubectl -n velero rollout restart deploy/velero ds/node-agent
kubectl -n studylife-scale annotate cluster studylife-pg cnpg.io/reloadedAt="$(date -Is)" --overwrite
```

## What gets backed up (opt-in only)

Volumes join the nightly 03:00 run (TTL 168h) via pod annotation
`backup.velero.io/backup-volumes: <volume>` in each app's own repo:

| App (namespace) | Volume | Consistency |
|---|---|---|
| uptime-kuma (monitoring) | data | sqlite3 `.backup` pre-hook writes `kuma.db.velero-snapshot` |
| grafana (monitoring) | data | none - image has no sqlite3 CLI; accepted, 7 nightly states as fallback |
| autodoc-server (homelab-autodoc) | data, config | files only appended/rewritten atomically |
| homelab-hub (homelab-hub) | data | small JSON store |
| qdrant (studylife-ai) | storage | crash-consistent; embeddings re-derivable at worst |

Deliberately NOT backed up: prometheus TSDB + loki logs (observability data, accepted
loss), Postgres (CNPG barman owns it).

## Restore

```bash
kubectl -n velero get backup                        # pick one
velero restore create --from-backup <name> \
  --include-namespaces monitoring --selector app=uptime-kuma \
  --namespace-mappings monitoring:restore-test     # drill: restore beside prod, not over it
```
For uptime-kuma prefer `kuma.db.velero-snapshot` over `kuma.db` if the raw file is
suspect: stop the pod, replace kuma.db with the snapshot copy, start.
Without the velero CLI, a `Restore` custom resource with the same fields does the same.

Drill performed 2026-08-24 (uptime-kuma -> restore-test namespace): PVC data restored via
the node-agent, pod came up 1/1, raw kuma.db AND the hook snapshot both held all 11
monitors, restore Completed with 0 errors. Two learnings baked in:
- cert-manager-issued TLS secrets carry no app label, so a label-selected backup skips
  them - in a real disaster cert-manager re-issues them from the Certificate object; in a
  namespace-mapping drill, copy the secret over by hand or the pod blocks on FailedMount.
- CRD name clash: bare `kubectl get backup` resolves to CNPG's backups.postgresql.cnpg.io.
  Always use `kubectl -n velero get backups.velero.io`.

Gotcha found during the first verification run: a backup started immediately after a
rollout can attempt its pre-hook against the terminating old pod - the hook counts as
attempted but the snapshot lands nowhere. Nightly timing makes this a non-issue; for
manual runs, wait for the rollout to settle first.

## Monitoring

Prometheus scrapes the velero server (job `velero`, monitoring/01-prometheus.yaml);
`07-grafana-alerting.yaml` fires when the last successful `velero-nightly-pvc` backup is
older than 26h - same staleness pattern as the autodoc collector rule.
