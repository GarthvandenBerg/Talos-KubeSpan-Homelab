# Disaster Recovery Plan

Scope: the Talos + Proxmox homelab cluster and the services it depends on (OpenBao, MinIO/TrueNAS, Terraform state). Personal-data backups on TrueNAS are covered briefly because the cluster's backups share that hardware.

**Status: targets below are goals, not measurements.** The measured column is filled in only after a drill. Until then it says "not measured".

---

## 1. Principles

1. **Rebuild the cluster, restore the data.** The cluster is described by Terraform and Git. Durable state lives outside it: databases in S3, secrets in OpenBao, personal data on TrueNAS.
2. **Know the order.** Recovery fails when layers are restored out of order (see section 3).
3. **A backup that has not been restored is an assumption.** Every layer gets a drill, and every drill gets a row in the log.
4. **Write down what is not covered.** See section 7.

---

## 2. Where state lives

| State | Lives in | Protected by | Recovery method |
| :--- | :--- | :--- | :--- |
| Kubernetes manifests, ArgoCD config | GitHub repo | GitHub | `terraform apply`, then ArgoCD reconciles |
| VM + Talos + bootstrap definitions | `terraform/` + state on NAS | Git + NAS snapshots/replication | `terraform apply` (state loss: see S7) |
| Talos secrets (cluster PKI) | Terraform state | NAS (unencrypted, see limitations) | Regenerated on a fresh rebuild |
| etcd | Control-plane VMs | **Not backed up, by design** (see section 6) | Rebuild |
| PostgreSQL databases | Node-local disks + S3 (base backup + WAL) | CNPG replicas + MinIO on TrueNAS | CNPG recovery (S5) |
| Application secrets | OpenBao VM | PBS VM backup + cron Raft snapshot | Restore VM or snapshot (S6) |
| Immich photos | NFS on TrueNAS | ZFS snapshots, off-site NAS, B2 | TrueNAS restore (S8) |
| Prometheus data | Cluster | Not backed up | Accepted loss |

---

## 3. Recovery order

Restore in this order. Each step depends on the one before it.

1. Network, DNS and the Proxmox hosts
2. TrueNAS (MinIO, NFS, Terraform state location)
3. OpenBao (running **and unsealed**)
4. Terraform state available
5. Cluster (`terraform apply`)
6. ArgoCD → operators (ESO, CNPG) → secrets → databases → apps

---

## 4. Recovery objectives (targets)

| Scenario | RPO target | RTO target | Measured |
| :--- | :--- | :--- | :--- |
| Single worker or control-plane VM lost | 0 | Minutes | not measured |
| Database lost or corrupted | Bounded by WAL archiving (minutes) | Time to restore base backup + replay WAL | not measured |
| Full cluster rebuild | 0 for config (Git); DB per above | Set after drill 1 | not measured |
| OpenBao lost | Last Raft snapshot | Time to restore VM + unseal | not measured |
| Proxmox host with 2 control planes lost | As full rebuild | As full rebuild | not measured |

RTO targets are intentionally blank. **Drill 1 sets the baseline**: measure from "first `terraform apply`" to "all ArgoCD apps Healthy and databases restored", then record it here.

---

## 5. Runbooks

### S1. Single worker lost

1. `kubectl get nodes` to confirm which node is `NotReady`.
2. Re-run `terraform apply` to recreate the VM and rejoin it.
3. Check pods rescheduled. For CNPG, check `kubectl get cluster -A` and that a replica was promoted if the primary was on that node.

### S2. Single control plane lost

1. From a healthy control plane: `talosctl -n <healthy-ip> etcd members`.
2. Remove the dead member: `talosctl -n <healthy-ip> etcd remove-member <member-id>`.
3. `terraform apply` to recreate the VM, then confirm it rejoins and `etcd members` shows three.

### S3. Proxmox host with two control planes lost

Quorum is lost and the API server stops. Workloads keep running; changes stop.

- **Host recoverable:** bring it back and let etcd re-form.
- **Host not recoverable:** there are no etcd snapshots, so treat it as S4 (full rebuild). If snapshots exist in future, use `talosctl bootstrap --recover-from=<snapshot>`.

### S4. Full cluster loss (rebuild)

**Before starting, check:** MinIO reachable, OpenBao running and unsealed, Terraform state readable, repo up to date.

1. **Databases first:** for every database, commit the `*.restore` variant (or the restore overlay once it exists) **before the first sync**. Otherwise the databases start empty (`initdb`).
2. Set a **new `serverName`** for each recovered cluster's own backups (see S5).
3. `cd terraform && terraform apply`.
4. Create the `openbao-approle` secret (manual step, see README bootstrap).
5. Watch ArgoCD: `kubectl -n argocd-system get applications`. Wait for Healthy.
6. Verify: `kubectl get externalsecret -A` all `SecretSynced`; `kubectl get cluster -A` all healthy; spot-check each app, and Immich photos load.
7. Record start time, end time and problems in the drill log.

### S5. Database lost or corrupted

1. Swap the database manifest for its `*.restore` variant (`bootstrap.recovery`, source = the S3 `externalClusters` entry).
2. **Use a new `serverName` for the recovered cluster's backups.** Keep the old `serverName` only under `externalClusters`. A recovered cluster that archives into the old path can clash with, or overwrite, the history it recovered from. Verify this behaviour in a drill with your CNPG version.
3. For point-in-time recovery, add `recoveryTarget.targetTime` under `bootstrap.recovery`.
4. Commit, push, let ArgoCD sync. Confirm the cluster reaches `Cluster in healthy state` and the app reconnects.
5. Re-point application secrets/credentials if the credential-sync Job needs to run again (wave 3).

### S6. OpenBao lost

1. Restore the OpenBao VM from Proxmox Backup Server, **or** restore the latest Raft snapshot on a fresh instance: `bao operator raft snapshot restore <file>`.
2. Unseal using the unseal keys (stored offline, see section 7).
3. Confirm the AppRole `eso` and policy `eso-read` exist. If not, re-run the bootstrap commands from the README.
4. Verify ESO: `kubectl get clustersecretstore` is `Valid` and `kubectl get externalsecret -A` is `SecretSynced`.

### S7. Terraform state lost

State is on the NAS. Restore it from the NAS snapshot or replica first. If it is gone entirely, do not try to `import` everything: delete what is left and rebuild (S4). A fresh rebuild regenerates the Talos secrets.

### S8. TrueNAS lost (MinIO, NFS, state)

1. Restore from the off-site NAS replica (or Backblaze B2 for personal data).
2. Redeploy the MinIO container pointing at the restored dataset and check the `database-backup` bucket.
3. Restore Terraform state to its path.
4. Note: the off-site NAS restore has **not** been tested, and it is unconfirmed that the MinIO zvol is included in the off-site and cloud copies. See section 7.

### S9. Site loss

Personal data comes back from the off-site NAS and B2. The cluster needs new Proxmox hardware, then S4. This only works if the OpenBao backup and the Terraform state also exist off-site. **That is not confirmed yet.**

---

## 6. Decision: etcd is not backed up

**Why:** nothing in etcd is irreplaceable. Manifests are in Git, databases are in S3, secrets are in OpenBao. Rebuilding is a tested path and avoids maintaining a second restore path.

**What I accept:** losing quorum means a full rebuild, which takes longer than restoring a snapshot. Anything created imperatively in the cluster and never committed to Git is lost.

**Revisit if:** the rebuild takes longer than I can tolerate (drill 1 will tell me), or I run stateful workloads whose cluster-level objects are not in Git. A snapshot is cheap to add: `talosctl -n <ip> etcd snapshot <file>` on a schedule, copied to MinIO.

---

## 7. Known gaps

| Gap | Risk | Action |
| :--- | :--- | :--- |
| Off-site NAS restore never tested | Replica might not restore as expected | Drill 3 |
| Unclear whether the MinIO zvol is covered by the off-site NAS and cloud replication | DB backups lost with the main NAS | Check each replication and Cloud Sync task, then restore MinIO data from each copy |
| OpenBao backups and Terraform state: off-site copy unconfirmed | Site loss blocks a rebuild | Confirm, then copy off-site |
| Unseal keys / root token storage | Cannot unseal after restore | Confirm they are stored offline in two places |
| Terraform state unencrypted | Secret exposure | Move to OpenTofu state encryption |
| No alerting | A backup failure goes unnoticed | Alertmanager push channel + dead-man switch; alert on failed CNPG backups |
| Restore variants are swapped by hand | Slow and error-prone during a rebuild | Kustomize `restore` overlay |

---

## 8. Drill program

| # | Drill | Frequency | Status |
| :-: | :--- | :--- | :--- |
| 1 | Full cluster rebuild + all DBs restored, **timed** | Every 6 months | Done Oct 2026 (untimed), repeat with timing |
| 2 | Single DB point-in-time restore | Every 3 months | Not done |
| 3 | TrueNAS off-site replica restore | Every 6 months | Not done |
| 4 | OpenBao restore from PBS and from Raft snapshot | Every 6 months | Not done |
| 5 | Proxmox host loss simulation (power off one host) | Yearly | Not done |

### Drill log

| Date | Drill # | Start → end | Result | Problems found | Fixes |
| :--- | :-: | :--- | :--- | :--- | :--- |
| Oct 2026 | 1 | not recorded | Cluster rebuilt, DBs recovered from S3 | No Data | N/A |
| Nov 19 2026 | 2 | 9:41am -> | Cluster Rebuilt - fully deleted VM's and rebuilt, restored DB's from S3 | Outdated Talos image on Proxmox host, helm repo not updated on provisioning machine, ESO CRD's missing when trying to sync | |

