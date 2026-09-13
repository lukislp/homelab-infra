# CNPG: moving off in-tree Barman Cloud (assessment, not executed)

Both Postgres clusters back up to Cloudflare R2 through `spec.backup.barmanObjectStore` -
the Barman Cloud support that is compiled into the CloudNativePG operator itself. That
support is deprecated and is being removed. Every `kubectl apply` against either cluster
already prints it:

```
Warning: Native support for Barman Cloud backups and recovery is deprecated and will be
completely removed in CloudNativePG 1.30.0. Found usage in: spec.backup.barmanObjectStore.
Please migrate existing clusters to the new Barman Cloud Plugin to ensure a smooth transition.
```

This document is the assessment only. **Nothing here has been applied.**

## The version question, and it runs the other way round

The obvious question is "which CNPG version do we have to reach first?". The answer is
none - we are already past it:

| | |
|---|---|
| Plugin minimum | CNPG **1.26** |
| Plugin recommended | CNPG **1.27+** (better plugin error handling and status reporting) |
| Installed here | **1.29.1** (`ghcr.io/cloudnative-pg/cloudnative-pg:1.29.1`) |
| Plugin latest | **v0.15.0** (2026-09-03) |
| cert-manager (required by the plugin) | present, `cert-manager` namespace, healthy |

Every prerequisite is already satisfied. The constraint points the other way: the operator
must **not** be upgraded past the removal release before the migration is done, because at
that point `spec.backup.barmanObjectStore` stops being understood and both clusters lose
WAL archiving and scheduled backups at once.

The removal target has slipped repeatedly upstream - first announced for 1.28, then 1.30,
and the current docs say 1.31. Our installed operator's own admission webhook still says
**1.30.0**. Plan against 1.30: treat **1.29.x as the last safe operator version** until this
migration is done. Since nothing in this cluster upgrades the operator automatically (it is
installed by hand, like the other operators), the practical rule is simply: do not run the
CNPG upgrade command again until this is finished.

## What is affected

| Cluster | Instances | destinationPath | serverName | Retention | Schedule |
|---|---|---|---|---|---|
| `studylife-scale/studylife-pg` | 3 | `s3://studylifebackup/` | `studylife-pg` | 30d | 03:00 daily |
| `claude-queue/claude-queue-pg` | 1 | `s3://studylifebackup/claude-queue` | `claude-queue-pg` | 30d | 02:00 daily |

Neither cluster uses `externalClusters`, so the replica-cluster part of the upstream
migration guide does not apply here. Both use the same R2 token, which Velero also uses.

## What changes in the manifests

Three edits per cluster, plus one new object.

**1. A new `ObjectStore` resource** (new CRD `barmancloud.cnpg.io/v1`, installed with the
plugin), in the same namespace as the cluster. It is a near-verbatim lift of the existing
`barmanObjectStore` block, with the retention policy moved in from the Cluster:

```yaml
apiVersion: barmancloud.cnpg.io/v1
kind: ObjectStore
metadata:
  name: r2-claude-queue
  namespace: claude-queue
spec:
  retentionPolicy: "30d"          # moved here out of Cluster .spec.backup
  configuration:
    destinationPath: "s3://studylifebackup/claude-queue"
    endpointURL: "https://<account>.r2.cloudflarestorage.com"
    s3Credentials:
      accessKeyId: { name: r2-backup-credentials, key: ACCESS_KEY_ID }
      secretAccessKey: { name: r2-backup-credentials, key: ACCESS_SECRET_KEY }
    wal: { compression: gzip }
    data: { compression: gzip }
```

The SealedSecrets do not change - the plugin reads the same secret keys.

**2. The `Cluster`** loses its whole `spec.backup` block and gains a `spec.plugins` entry.
This has to be one atomic edit; a cluster with neither is a cluster that is not archiving.

```yaml
spec:
  plugins:
    - name: barman-cloud.cloudnative-pg.io
      isWALArchiver: true
      parameters:
        barmanObjectName: r2-claude-queue
        serverName: claude-queue-pg      # pin explicitly, see below
```

**3. The `ScheduledBackup`** gains a method and a plugin reference:

```yaml
spec:
  method: plugin
  pluginConfiguration:
    name: barman-cloud.cloudnative-pg.io
```

Files that would change: `claude-queue-platform` `k8s/02-postgres.yaml` +
`k8s/08-scheduled-backup.yaml` (plus a new ObjectStore file and a `kustomization.yaml`
entry), and `studylife` `k8s/02-postgres.yaml` + `k8s/08-scheduled-backup.yaml` likewise.
Both sets are bootstrap-only, so both are hand-applied - Flux does not reconcile CNPG kinds
in either repo.

## Risk to what is already in R2

**Low, and the old backups stay restorable.** The plugin is the same barman-cloud code,
moved out of the operator into a sidecar; the layout in the bucket
(`<destinationPath>/<serverName>/{base,wals}`) is unchanged, and upstream states explicitly
that backups taken by the in-tree implementation are fully supported by the plugin. There is
no re-upload, no re-baseline, and no need to keep the old backups separately.

The one way to lose the archive is to change where it points. `serverName` defaults to the
Cluster's name on both the in-tree and the plugin path, and neither cluster is being renamed,
so continuity holds by default here - but it holds *implicitly*. Pin `serverName` explicitly
in the plugin parameters anyway: if it ever drifts (a rename, a typo, a copy-paste between
the two clusters), barman silently starts a **new** tree. That is the genuinely bad outcome,
because it is not an error - archiving keeps reporting healthy while the 30d recovery window
quietly restarts at zero, the old base backups are orphaned from the new WAL chain, and the
retention sweep eventually deletes them.

So the rule for the migration is: `destinationPath` and `serverName` byte-identical to what
is in the manifests today, verified with a `barman-cloud-backup-list` **before and after**.

Rollback is available for as long as we stay on 1.29: revert the three edits and the in-tree
path picks the same archive back up.

## Blast radius

Adding `spec.plugins` triggers a **rolling update** of the cluster - the instance pods gain
the plugin sidecar, so they get recreated.

- **`studylife-pg`** (3 instances): the normal rolling update - replicas first, then a
  switchover for the primary. Seconds of write interruption. Low risk.
- **`claude-queue-pg`** (1 instance): there is no replica, so the update is a restart of the
  only instance - a real, if short, outage of that database. It is also the cluster whose
  object-store backup is its *only* recovery path beyond Velero's nightly PVC snapshot, so
  the migration should be done while someone is watching it.

Second-order cost worth noting on three Raspberry Pis: every instance pod gains a sidecar
container. Four instance pods total across both clusters, all with 512Mi limits today. Check
the memory headroom before, not after.

## Monitoring fallout - this one bites silently

The plugin renames the backup metrics:

| Today | After migration |
|---|---|
| `cnpg_collector_last_failed_backup_timestamp` | `barman_cloud_cloudnative_pg_io_last_failed_backup_timestamp` |
| `cnpg_collector_last_available_backup_timestamp` | `barman_cloud_cloudnative_pg_io_last_available_backup_timestamp` |
| `cnpg_collector_first_recoverability_point` | `barman_cloud_cloudnative_pg_io_first_recoverability_point` |

`monitoring/07-grafana-alerting.yaml` references the first two. They would not error - they
would just return no data forever.

There is an upside hiding here, though. That same file already carries a note explaining why
a "no successful backup for X hours" alert was deliberately *not* added: on the in-tree path
`cnpg_collector_last_available_backup_timestamp` is permanently stuck at 0 for us, and
`cnpg_collector_last_failed_backup_timestamp` keeps reporting a long-superseded one-off
failure, so any alert on them would fire permanently and incorrectly. The note guesses that
this is a limitation of the classic barmanObjectStore path rather than of the plugin. If the
plugin's equivalents report correctly, this migration is what finally makes a real
backup-freshness alert possible - which would close the last gap that currently leaves
backup success as a manual check.

That should be verified during the migration, not assumed: after the first cluster is moved,
query the new metric and confirm it carries a real timestamp before writing the alert.

## Suggested sequence

1. Confirm the operator stays on 1.29.x. Do not run the CNPG upgrade until step 7 is done.
2. Install the plugin into `cnpg-system`:
   `kubectl apply -f https://github.com/cloudnative-pg/plugin-barman-cloud/releases/download/v0.15.0/manifest.yaml`
   (needs cert-manager, present). `cnpg-system`'s NetworkPolicy leaves egress open, so no
   policy change there; the instance pods already have the `0.0.0.0/0:443` egress they need
   in both namespaces.
3. Record the current catalogue for both clusters (`barman-cloud-backup-list`) so there is a
   before-picture to diff against.
4. Migrate **`claude-queue-pg` first**, as the canary. Counter-intuitive given it is the
   single-instance one, but its archive was only created on 2026-09-13 - if a `serverName`
   mistake does start a new tree, almost nothing is lost, whereas the same mistake against
   `studylife-pg` throws away a month of history.
5. Verify that migration: an on-demand `Backup` reaching `completed`, a
   `barman-cloud-backup-list` showing the *old* backups still listed alongside the new one,
   and a forced WAL switch reaching R2.
6. Migrate `studylife-pg` the same way once the procedure is proven.
7. Update `monitoring/07-grafana-alerting.yaml` to the new metric names, and add the
   backup-freshness alert if the new metrics turn out to report properly.
8. Only then consider the operator upgrade past 1.29.

## Verdict

Not urgent this week, but not something to leave until the operator upgrade forces it either
- the failure mode of discovering it late is "both clusters stopped archiving when the
operator was upgraded". Everything needed is already in place: the operator is new enough,
cert-manager is there, and the existing backups migrate without being touched. The real work
is care around `serverName`, one watched restart of the single-instance cluster, and the
monitoring rename.
