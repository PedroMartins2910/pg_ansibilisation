# pg-ops — PostgreSQL + repmgr HA, operated from Ansible

Topology: **2 data nodes, no witness**, repmgrd **automatic failover** (split-brain risk
accepted, see *Two nodes, no witness*). There is
no VIP: applications list every data node in their connection string
(`host=pgdb01,pgdb02 target_session_attrs=read-write`) and libpq finds the primary.
With `repmgr_enabled: false` the cluster is a **single data node** (no replication, no
witness) for applications that do not need HA. Backups use
**pgBackRest** on the DB nodes, with one repository in an **on-prem S3-compatible bucket**:
daily full backups taken from the standby, continuous WAL archiving, and retention by
count. Secrets come from **HashiCorp Vault**.

Target OS: RHEL / Rocky / Alma 8–9 (x86_64 and aarch64). PostgreSQL, its extensions
(pgaudit, pgauditlogtofile, repmgr, optional pgvector; pgcrypto ships with -contrib) and
pgBackRest are **PGDG RPMs served by the Nexus yum mirror** (`pg_repo_base_url`), installed
at exactly `pg_version_full` and version-locked.

Tested end to end on local Docker (`tests/e2e/run.sh`, see *End-to-end test* below).

## Quick start

```bash
pip install ansible-core hvac            # hvac = HashiCorp Vault client used by the lookups
ansible-galaxy collection install -r requirements.yml

export VAULT_TOKEN=...                   # or ANSIBLE_HASHI_VAULT_ROLE_ID / ANSIBLE_HASHI_VAULT_SECRET_ID (approle)
INV=inventories/production/hosts.yml

# Existing cluster: always look first
ansible-playbook -i $INV playbooks/site.yml --check --diff
ansible-playbook -i $INV playbooks/site.yml
```

## Operations

| What | Command | Client impact |
|---|---|---|
| Converge everything (idempotent) | `site.yml` | none (never restarts unless `-e pg_allow_restart=true`) |
| DB, schema, roles, users only | `bootstrap_db.yml` | none |
| Health report | `cluster_status.yml` | none |
| Planned primary election | `switchover.yml -e new_primary=pgdb02 -e confirm=YES` | reconnect (seconds) |
| Manual failover (primary dead) | `promote.yml -e new_primary=pgdb02 -e confirm=YES` | already down |
| Old primary back as standby | `rejoin.yml -e target=pgdb01 -e confirm=YES` | none |
| Rebuild a replica | `rebuild_replica.yml -e target=pgdb02 -e confirm=YES` | none (HA reduced while cloning) |
| Minor upgrade (17.x → 17.y) | set `pg_version_full`, then `minor_upgrade.yml -e confirm=YES` | one switchover reconnect |
| Major upgrade preflight | `major_upgrade_preflight.yml -e pg_new_version_full=18.6 -e confirm=YES` | none |
| Major upgrade | `major_upgrade.yml -e pg_new_version_full=18.6 -e confirm=YES` | **downtime 1–5 min** |
| Backup now | `backup_now.yml` (`-e backup_now_type=diff`, `-e force_on=<host>`) | none |
| Point-in-time restore | `restore_pitr.yml -e target=pgdb01 [-e "restore_target_time='2026-11-05 10:30:00+01'"] [-e restore_set=<label>] -e confirm=YES` | full outage |

Every destructive playbook requires `-e confirm=YES`. Before acting, it finds out the
**real** primary by querying each node (`roles/pg_facts`), so it never relies on the
inventory for that. It also aborts if two primaries are found (split-brain).

### Automatic failover
repmgrd on the standby promotes it when the primary stays unreachable for
`repmgr_reconnect_attempts` × `repmgr_reconnect_interval` (default 6 × 5 s). Clients using
`target_session_attrs=read-write` reconnect to the new primary on their own.

The failed node stays down. Bring it back with `rejoin.yml`, which runs `pg_rewind` and
falls back to a full re-clone if the rewind fails.

### Two nodes, no witness: split-brain (accepted risk)
With 2 servers the standby cannot tell "primary dead" from "network cut between the two
nodes". On a network cut it promotes itself while the old primary keeps running: **two
writable primaries**, and applications (multi-host, read-write) can write to both.
Writes made on the old primary during the cut are **lost** when it is rejoined.
`primary_visibility_consensus` is off (it needs a witness).

pg-ops detects it: every playbook refuses to run while two primaries exist (`SPLIT-BRAIN`).
Recovery (tested end to end):
1. Keep the node repmgr promoted (`repmgr cluster show` lists it as primary).
2. Fence the old primary: `systemctl stop repmgr-<major> postgresql-<major> && systemctl mask postgresql-<major>`.
3. `rejoin.yml -e target=<old primary> -e confirm=YES` (pg_rewind, falls back to a re-clone).

A witness in a third location (`pg_witness` group) removes this risk; it is supported but
not used.

### Changing parameters
`site.yml` applies `pg_settings_*` / pg_hba changes with a **reload** (no restart, no
disconnection). Settings that need a restart (`shared_buffers`, `max_connections`,
`shared_preload_libraries`, …) are reported as pending; `-e pg_allow_restart=true` restarts
the affected nodes (**both at once**, short outage). A `repmgr.conf` change restarts repmgrd
one node at a time; PostgreSQL is not touched.

### Minor upgrade flow
1. Upgrade the witness (if any).
2. Upgrade the standby.
3. Switch over to the upgraded standby.
4. Upgrade the old primary (now a standby).
5. Optionally switch back with `-e minor_upgrade_switch_back=true`.

### Major upgrade flow (`pg_upgrade --link`)
1. **Preflight** (no downtime):
   - install the new version side by side on all nodes;
   - `initdb` the new cluster with the old cluster's locale, encoding and checksums;
   - run `pg_upgrade --check` against the live cluster.
2. **Window**:
   - stop repmgrd, the standby and the witness;
   - stop the primary and run `pg_upgrade --link` (minutes, whatever the database size);
   - start the new primary, update extensions, re-register it in repmgr;
   - start `ANALYZE` in the background.
3. **After** (cluster open, no HA yet):
   - a normal converge on the new version re-clones the standby and re-creates the
     witness, and switches pgBackRest and pgBadger to the new paths;
   - pgBackRest `stanza-upgrade` already ran before the new primary started; a fresh
     full backup is taken because the new cluster has a **new system identifier**.
4. Set `pg_version_full: <new>` in the inventory.
5. When you're satisfied, clean up the old data (`delete_old_cluster.sh` on the primary,
   the old data directory on the other nodes).

**Rollback** before cleanup: the old standby's data directory is untouched. Unmask
`postgresql-<old major>` on it and promote it. You lose any writes made after the upgrade.

## Filesystem layout (`pg_fs_layout`)

Binaries always come from the RPMs (`/usr/pgsql-<major>`, `/usr/bin/pgbackrest`).

| Path | `regular` | `custom` (`pkage: /PKfbgad1`) |
|---|---|---|
| data | `/var/lib/pgsql/17/data` | `/PKfbgad1/data/pgs/17/data` |
| PostgreSQL + pgaudit logs | `/var/log/postgresql` | `/PKfbgad1/log/pgs` |
| repmgr / pgBackRest / pg-ops logs | `/var/log/{repmgr,pgbackrest,pg-ops}` | `/PKfbgad1/log/{repmgr,pgbackrest,pg-ops}` |
| certificates (TLS, coming next) | `/etc/pki/pgsql` | `/PKfbgad1/soft/<host>.jks` |

Any of these can be overridden per host (`pg_data_dir_template`, `pg_log_dir`, ...).

## Packages (Nexus) and versions

`roles/pg_repo` points dnf at `pg_repo_base_url` (a Nexus yum proxy or hosted repository
with the PGDG layout), plus EPEL (pgBadger). How Nexus is organised does not matter to the
playbooks, only the URL does. Set the GPG key URLs to the Nexus copies as well.

- `pg_version_full` (e.g. `"17.11"`) is installed exactly: `postgresql17{,-libs,-server,-contrib}-17.11`,
  then locked with `dnf versionlock` so `dnf update` cannot move it.
- Changing `pg_version_full` and running `site.yml` changes **nothing** on a running node
  (it reports "Version change postponed"). `minor_upgrade.yml` releases the lock, upgrades
  node by node with one switchover, and locks again.
- Extensions: `pgaudit_17`, `pgauditlogtofile_17` (always, preloaded), `repmgr_17` (if
  `repmgr_enabled`), `pgvector_17` when `vector` is listed in `pg_extensions_optional`.
- Note: the PGDG server RPM restarts PostgreSQL when it is upgraded. That is why the lock
  matters: an unplanned `dnf update` on a primary would restart it.

## Defaults you must set (`inventories/<env>/group_vars/pg_cluster/`)

| Variable | Purpose |
|---|---|
| `pg_db_name` | application database; **the schema has the same name** |
| `pg_role_ro_name` / `pg_role_dml_name` / `pg_role_ddl_name` | NOLOGIN group roles (ddl ⊃ dml ⊃ ro; ddl owns the schema) |
| `pg_login_users` | `[{name, group: ro\|dml\|ddl, conn_limit?, vault_path?}]`. ddl users get `SET role = <ddl>` on login, so the ddl group owns every new object and default privileges apply |
| `pg_version_full` | e.g. `"17.11"`; the major (`pg_version`) is derived from it; installed exactly and version-locked |
| `pg_fs_layout`, `pkage` | `regular` (FHS paths) or `custom` (everything under `pkage`, e.g. `/PKfbgad1`) |
| `pg_repo_base_url`, `pg_repo_gpg_key_url`, `pg_repo_epel_*` | Nexus yum mirror of PGDG / EPEL |
| `pg_extensions_optional` | `[{name: vector, db: appdb}, {name: pgcrypto, db: appdb}]` |
| `repmgr_enabled` | `true` (default) = 2 data nodes with repmgr; `false` = single data node, the HA playbooks refuse to run |
| `hashi_vault_*` | Vault URL, auth method, KV v2 mount and paths (key `password`) |
| `pgbackrest_s3_*` | S3 endpoint, port, bucket, region, path-style, private CA |
| `pgbackrest_retention_full`, `pgbackrest_encrypt` | number of daily fulls kept (default 14); optional repo encryption |
| host vars `repmgr_node_id` (+ `repmgr_location`, `repmgr_priority`) | **must match the existing repmgr cluster** when adopting one; the playbook refuses to run on a mismatch |

Variable precedence: put overrides in `group_vars/pg_cluster`. Inventory `group_vars/all`
has lower precedence than `playbooks/group_vars/all.yml`.

## Adopting an existing cluster — checklist
- `repmgr_node_id` and node names in the inventory match `repmgr cluster show`.
- Settings in `conf.d/00-ansible.conf` **override** `postgresql.conf`. Review
  `pg_shared_preload_libraries` (keep your own extensions) and `pg_settings_extra`.
- The managed `pg_hba` block is inserted at the **top** of `pg_hba.conf`. Use
  `pg_hba_auth_method: md5` if the passwords are still md5-hashed.
- `archive_command` is replaced by `pgbackrest archive-push`. The S3 bucket and its
  credentials in Vault must exist **first**, otherwise archiving fails and `pg_wal` grows.
  The converge runs `pgbackrest check` on the primary and stops if it fails.
- Settings that need a restart (`archive_mode`, `shared_preload_libraries`, `wal_log_hints`)
  are only reported. Apply them with `minor_upgrade.yml` (a rolling restart through a
  switchover) or `-e pg_allow_restart=true`.

## Backups — pgBackRest + S3

Layout:
- pgBackRest is installed on both data nodes (the witness doesn't need it). There is no
  backup server: the single repository is the S3 bucket (`repo1-type=s3`, path-style URLs,
  optional private CA).
- Each data node's `pgbackrest.conf` has `pg1` = the local instance and `pg2` = the peer
  over SSH as `postgres`. The playbook sets up the SSH keys and `~/.ssh/config`.

What runs:
- **WAL**: `archive_command = pgbackrest archive-push %p`, with `archive-async=y` and a
  local spool so pushes to S3 are parallel. Standbys use
  `restore_command = pgbackrest archive-get` to catch up from S3. After a failover the new
  primary archives automatically.
- **Backups**: `pg_backup.sh`, from cron at 01:00 on both data nodes. Only the standby
  actually runs it:
  - it does a `--type=full` backup with `backup-standby=y`, so files are copied from the
    standby and the primary is only contacted for start/stop backup;
  - if no standby is streaming, set `backup_allow_on_primary: true` to fall back to the
    primary.
- **Retention**: `repo1-retention-full=14` (count). After each backup, pgBackRest expires
  older fulls and the WAL that only they needed. That gives 14 days of point-in-time
  restore.
- **Encryption** (optional): `pgbackrest_encrypt: true` turns on `aes-256-cbc`, with the
  passphrase in Vault at `<base>/pgbackrest_cipher`. Decide **before** the first
  `stanza-create`: you can't enable it on an existing repo.
- **Stanza**: `pgbackrest_stanza` (default: `pg_cluster_name`). The converge creates it on
  the primary if it's missing, then runs `pgbackrest check`.
- **Restore** (`restore_pitr.yml`): an in-place `--delta` restore by default, with
  `--type=time --target-action=promote` when a target time is given. pgBackRest chooses
  the backup itself.
- **Monitoring** (for Dynatrace):
  - logs in `/var/log/pgbackrest/` and `/var/log/pg-ops/pg_backup.log` (failures also go
    to syslog with tag `pg-ops`);
  - last run in `/var/lib/pg-ops/backup.status`;
  - `pgbackrest info` and `pg_stat_archiver` are shown by `cluster_status.yml`.
- **Upgrades**:
  - pgBackRest versions must match on both nodes; `minor_upgrade.yml` updates them
    together and pauses backups meanwhile;
  - `major_upgrade.yml` runs `stanza-upgrade`.

Vault secrets needed, under `hashi_vault_base_path`:

| Path | Keys |
|---|---|
| `repmgr` | `password` |
| `users/<login user>` | `password` |
| `pgbackrest_s3` | `access_key`, `secret_key` |
| `pgbackrest_cipher` | `password` (only if `pgbackrest_encrypt: true`) |

### TODO — pgBadger / Dynatrace script (placeholder)
PostgreSQL logging is already set to a format both pgBadger and Dynatrace can parse
(`pg_log_line_prefix`). The cron job currently runs a placeholder
(`roles/pgbadger/templates/pgbadger_report.sh.j2`). Point `pgbadger_script_src` at the
in-house script.

## Lab
```bash
vagrant up
ansible-playbook -i inventories/lab/hosts.yml playbooks/lab_prepare.yml playbooks/site.yml
```
The lab uses static secrets (`secrets_backend: vars`) and runs MinIO with self-signed TLS on
the witness as the S3 bucket (`playbooks/lab_prepare.yml`).

Single-node mode: put one host in `pg_data`, leave `pg_witness` empty and set
`repmgr_enabled: false`; run steps 1–3 below (switchover, promote, rejoin, rebuild, upgrades and PITR restore need repmgr for now).

Suggested test sequence:
1. `site.yml` twice. The second run must report `changed=0`.
2. `bootstrap_db.yml`, then check the privileges:
   - ro cannot write;
   - dml cannot CREATE;
   - a table created by the ddl user is readable by ro.
3. `backup_now.yml`, then `cluster_status.yml`.
4. `switchover.yml`, then kill the primary (repmgrd fails over), then
   `rejoin.yml`.
5. `rebuild_replica.yml`, then `minor_upgrade.yml`.
6. `major_upgrade.yml -e pg_new_version_full=18.6`.
7. `restore_pitr.yml` to a time before a test `DELETE`.

## End-to-end test (Docker)

```bash
pip install ansible-core hvac
ansible-galaxy collection install -r requirements.yml -r tests/e2e/requirements.yml -p tests/e2e/work/collections
tests/e2e/run.sh            # all: fresh environment + HA scenario + single-node scenario
tests/e2e/run.sh down       # remove the containers
```

`tests/e2e/docker-compose.yml` starts 3 Rocky Linux 9 containers with systemd (pg1, pg2,
solo), **HashiCorp Vault** (dev server, secrets read through AppRole, as in
production) and **SeaweedFS** as the S3 server over HTTPS with a test CA. Packages come from
download.postgresql.org in place of Nexus. Every playbook run writes its log to
`tests/e2e/logs/`; `E2E_FROM=<n> tests/e2e/run.sh ha` resumes at step n.

| # | HA scenario (2 data nodes, no witness, `pg_fs_layout: custom`) |
|---|---|
| 1 | greenfield `site.yml` at 17.10: roles, `/PKe2e01` paths, preload libs, extensions, version lock, 2-node repmgr |
| 2 | second `site.yml` reports `changed=0` |
| 3 | passwords come from Vault; a password rotated in Vault is applied by `bootstrap_db.yml` |
| 4 | replication, read-only standby, pgaudit lines in `audit-*.log` |
| 5 | `backup_now.yml` (backup from the standby to S3), WAL archiving healthy, `cluster_status.yml` |
| 6 | `work_mem` change applied by reload, no restart (postmaster start time unchanged) |
| 7 | `max_connections` change reported as pending, applied with `pg_allow_restart=true` |
| 8 | repmgr setting change: repmgrd restarted on one node at a time |
| 9 | `switchover.yml` |
| 10 | automatic failover by repmgrd (primary stopped), `rejoin.yml` |
| 11 | `rebuild_replica.yml` |
| 12 | network cut between the nodes: split-brain, detected (`SPLIT-BRAIN`), fenced and rejoined; old-primary writes lost |
| 13 | `site.yml` with a new `pg_version_full` leaves running nodes alone |
| 14 | `minor_upgrade.yml` 17.10 → 17.11, lock moved |
| 15 | `restore_pitr.yml` to a timestamp before a `DELETE`; standby re-cloned |
| 16 | `major_upgrade.yml` 17 → 18 (`pg_upgrade --link`), data + extensions kept, fresh backup |
| 17 | `site.yml` on 18 reports `changed=0` |

Single-node scenario (`repmgr_enabled: false`, `pg_fs_layout: regular`): converge,
idempotence, backup on the primary, HA playbooks refuse to run.

## Layout
```
playbooks/   one playbook per operation (+ group_vars/all.yml project defaults)
tests/e2e/   end-to-end test on Docker (run.sh, compose file, test inventories)
roles/
  pg_facts      live topology discovery (who is primary), split-brain guard
  secrets       HashiCorp Vault lookups (once, on the controller)
  pg_repo       PGDG / EPEL yum repositories (Nexus mirror)
  postgresql    pinned + version-locked packages, initdb (greenfield only), conf.d + pg_hba block, pg.env
  repmgr        repmgr.conf, sudo, ssh trust, register/clone/rebuild/switchover/minor-upgrade tasks
  db_bootstrap  database, schema, ro/dml/ddl group roles, default privileges, login users
  pgbackrest    pgBackRest (S3 repo), stanza, backup wrapper + cron, PITR restore tasks
  pgbadger      pgBadger + report script
```
