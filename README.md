# pg-ops — PostgreSQL 16 + repmgr HA, operated from Ansible

Topology: **2 data nodes + 1 repmgr witness**, repmgrd **automatic failover**. There is
no VIP: applications list every data node in their connection string
(`host=pgdb01,pgdb02 target_session_attrs=read-write`) and libpq finds the primary.
With `repmgr_enabled: false` the cluster is a **single data node** (no replication, no
witness) for applications that do not need HA. Backups use
**pgBackRest** on the DB nodes, with one repository in an **on-prem S3-compatible bucket**:
daily full backups taken from the standby, continuous WAL archiving, and retention by
count. Secrets come from **HashiCorp Vault**.

Target OS: RHEL / Rocky / Alma 8–9 with PGDG packages.

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
| Minor upgrade (16.x → 16.y) | `minor_upgrade.yml -e confirm=YES` | one switchover reconnect |
| Major upgrade preflight | `major_upgrade_preflight.yml -e pg_new_version=17 -e confirm=YES` | none |
| Major upgrade | `major_upgrade.yml -e pg_new_version=17 -e confirm=YES` | **downtime 1–5 min** |
| Backup now | `backup_now.yml` (`-e backup_now_type=diff`, `-e force_on=<host>`) | none |
| Point-in-time restore | `restore_pitr.yml -e target=pgdb01 [-e "restore_target_time='2026-11-05 10:30:00+01'"] [-e restore_set=<label>] -e confirm=YES` | full outage |

Every destructive playbook requires `-e confirm=YES`. Before acting, it finds out the
**real** primary by querying each node (`roles/pg_facts`), so it never relies on the
inventory for that. It also aborts if two primaries are found (split-brain).

### Automatic failover
repmgrd promotes the standby when the primary is unreachable and the witness agrees
(`primary_visibility_consensus`). Clients using `target_session_attrs=read-write`
reconnect to the new primary on their own.

The failed node stays down. Bring it back with `rejoin.yml`, which runs `pg_rewind` and
falls back to a full re-clone if the rewind fails.

### Minor upgrade flow
1. Upgrade the witness.
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
4. Set `pg_version: <new>` in the inventory.
5. When you're satisfied, clean up the old data (`delete_old_cluster.sh` on the primary,
   the old data directory on the other nodes).

**Rollback** before cleanup: the old standby's data directory is untouched. Unmask
`postgresql-16` on it and promote it. You lose any writes made after the upgrade.

## Defaults you must set (`inventories/<env>/group_vars/pg_cluster/`)

| Variable | Purpose |
|---|---|
| `pg_db_name` | application database; **the schema has the same name** |
| `pg_role_ro_name` / `pg_role_dml_name` / `pg_role_ddl_name` | NOLOGIN group roles (ddl ⊃ dml ⊃ ro; ddl owns the schema) |
| `pg_login_users` | `[{name, group: ro\|dml\|ddl, conn_limit?, vault_path?}]`. ddl users get `SET role = <ddl>` on login, so the ddl group owns every new object and default privileges apply |
| `repmgr_enabled` | `true` (default) = 2 data nodes + witness with repmgr; `false` = single data node, the HA playbooks refuse to run |
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
6. `major_upgrade.yml -e pg_new_version=17`.
7. `restore_pitr.yml` to a time before a test `DELETE`.

## Layout
```
playbooks/   one playbook per operation (+ group_vars/all.yml project defaults)
roles/
  pg_facts      live topology discovery (who is primary), split-brain guard
  secrets       HashiCorp Vault lookups (once, on the controller)
  pg_repo       PGDG / mirror repositories
  postgresql    packages, initdb (greenfield only), conf.d + pg_hba block, pg.env
  repmgr        repmgr.conf, sudo, ssh trust, register/clone/rebuild/switchover/minor-upgrade tasks
  db_bootstrap  database, schema, ro/dml/ddl group roles, default privileges, login users
  pgbackrest    pgBackRest (S3 repo), stanza, backup wrapper + cron, PITR restore tasks
  pgbadger      pgBadger + report script
```
