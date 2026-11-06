#!/usr/bin/env bash
# pg-ops end-to-end test on local Docker.
#
#   HA scenario   : pg1 + pg2 (data) + wit (repmgr witness), custom layout (/PKe2e01)
#   Solo scenario : one node, repmgr_enabled=false, regular layout
#   Services      : HashiCorp Vault (secrets, AppRole), SeaweedFS (S3 over HTTPS, test CA)
#   Packages      : download.postgresql.org (stands in for the Nexus yum mirror)
#
# Usage: tests/e2e/run.sh [all|up|ha|solo|down]   (default: all = up + ha + solo)
#        E2E_PG_NEXT=18.6 sets the major-upgrade target version
#        E2E_FROM=<step number> tests/e2e/run.sh ha   resumes the HA scenario at a step
# Needs: docker (compose v2), ansible-playbook + hvac in PATH.
set -euo pipefail

E2E=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$E2E/../.." && pwd)
WORK=$E2E/work
LOGS=$E2E/logs
INV=$E2E/inventory/hosts.yml
INV_SOLO=$E2E/inventory-solo/hosts.yml
VERSION_FILE=$E2E/inventory/group_vars/pg_cluster/zz_version.yml
export ANSIBLE_CONFIG=$ROOT/ansible.cfg
export ANSIBLE_COLLECTIONS_PATH=${ANSIBLE_COLLECTIONS_PATH:-$WORK/collections}
export ANSIBLE_FORCE_COLOR=0
# macOS controller: forked workers crash in the Vault (HTTP) lookups without these
export OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES no_proxy='*'
VAULT="docker exec -e VAULT_ADDR=http://127.0.0.1:8200 -e VAULT_TOKEN=e2e-root pgops-e2e-vault vault"
FROM=${E2E_FROM:-1}
mkdir -p "$LOGS"

# ------------------------------------------------------------------ helpers
STEP=0
PASSED=()
step() {                       # step "<title>"  -> returns 1 (skip) before E2E_FROM
  STEP=$((STEP + 1))
  CURRENT="$STEP. $1"
  if (( STEP < FROM )); then echo "-- skip  $CURRENT"; return 1; fi
  echo "== $CURRENT"
}
ok()   { echo "   ok: $*"; PASSED+=("$CURRENT: $*"); }
fail() { echo "   FAIL: $*" >&2; echo "   (step: $CURRENT)" >&2; exit 1; }

pb() {                         # pb <inventory> <playbook> [ansible args...]
  local inv=$1 play=$2; shift 2
  local log="$LOGS/$(printf '%02d' "$STEP")-$(basename "$play" .yml)-$(date +%H%M%S).log"
  echo "   ansible-playbook $(basename "$play") $*  (log: ${log#"$E2E"/})"
  if ! ansible-playbook -i "$inv" "$ROOT/playbooks/$play" "$@" >"$log" 2>&1; then
    grep -E 'fatal:|FAILED!|ERROR|msg:' "$log" | tail -25 >&2 || true
    fail "$play failed"
  fi
  LAST_LOG=$log
}
pb_must_fail() {               # the playbook is expected to refuse
  local inv=$1 play=$2; shift 2
  local log="$LOGS/$(printf '%02d' "$STEP")-$(basename "$play" .yml)-refused.log"
  if ansible-playbook -i "$inv" "$ROOT/playbooks/$play" "$@" >"$log" 2>&1; then
    fail "$play should have refused to run"
  fi
}
assert_idempotent() {          # no task reported 'changed' in the last run
  local recap
  recap=$(sed -n '/PLAY RECAP/,$p' "$LAST_LOG" | grep -E 'changed=' || true)
  if echo "$recap" | grep -vq 'changed=0'; then
    echo "$recap" >&2
    grep -B1 -E '^changed:' "$LAST_LOG" | grep -E '^TASK|^changed' | tail -30 >&2 || true
    fail "second run is not idempotent"
  fi
  ok "idempotent (changed=0 everywhere)"
}

major() { cut -d. -f1 <<<"$PGV"; }
sql() {                        # sql <container> <query> [db]
  docker exec "pgops-e2e-$1" sudo -iu postgres "/usr/pgsql-$(major)/bin/psql" -X -A -t -q \
    -d "${3:-postgres}" -c "$2"
}
sh_on() { docker exec "pgops-e2e-$1" bash -c "$2"; }
role_of() {                    # primary | standby | down
  local r
  r=$(sql "$1" "SELECT pg_is_in_recovery()" 2>/dev/null) || { echo down; return; }
  [[ $r == f ]] && echo primary || echo standby
}
wait_for() {                   # wait_for <seconds> <description> <command...>
  local secs=$1 what=$2; shift 2
  for ((i = 0; i < secs; i += 3)); do "$@" >/dev/null 2>&1 && return 0; sleep 3; done
  fail "timeout ($secs s) waiting for: $what"
}
expect_eq() { [[ "$1" == "$2" ]] || fail "$3: expected '$2', got '$1'"; ok "$3 = $2"; }
set_version() { PGV=$1; printf -- '---\npg_version_full: "%s"\n' "$PGV" >"$VERSION_FILE"; }
primary_host() { for h in pg1 pg2; do [[ $(role_of $h) == primary ]] && { echo $h; return; }; done; echo none; }
other_host() { [[ $1 == pg1 ]] && echo pg2 || echo pg1; }
streaming_count() { sql "$1" "SELECT count(*) FROM pg_stat_replication WHERE state='streaming'"; }

# ------------------------------------------------------------------ environment
up() {
  echo "== environment"
  docker build -q -t pgops-e2e-el9 "$E2E/image" >/dev/null
  if [[ ! -f $WORK/certs/s3.crt ]]; then
    mkdir -p "$WORK/certs"
    docker run --rm -v "$WORK/certs:/c" rockylinux/rockylinux:9 bash -ec '
      cd /c
      openssl req -x509 -newkey rsa:2048 -nodes -days 365 -subj "/CN=pg-ops e2e CA" -keyout ca.key -out ca.crt
      openssl req -newkey rsa:2048 -nodes -subj "/CN=172.30.0.20" -keyout s3.key -out s3.csr
      printf "subjectAltName=IP:172.30.0.20,DNS:s3\n" > ext.cnf
      openssl x509 -req -in s3.csr -CA ca.crt -CAkey ca.key -CAcreateserial -days 365 -extfile ext.cnf -out s3.crt
      chmod 644 s3.key' 2>/dev/null
  fi
  # always start from fresh machines (the playbooks refuse to touch half-built clusters)
  docker compose -f "$E2E/docker-compose.yml" down -v --remove-orphans >/dev/null 2>&1 || true
  rm -f "$VERSION_FILE"
  docker compose -f "$E2E/docker-compose.yml" up -d >/dev/null 2>&1
  for n in pg1 pg2 wit solo; do
    wait_for 60 "systemd on $n" docker exec "pgops-e2e-$n" systemctl is-system-running
  done
  wait_for 60 "vault" curl -sf http://127.0.0.1:18200/v1/sys/health
  wait_for 60 "S3 bucket" bash -c 'echo "s3.bucket.create -name pgbackrest" | docker exec -i pgops-e2e-s3 weed shell 2>&1 | grep -qE "created|exist"'

  # Vault: KV v2 secrets + AppRole limited to read secret/postgres/*
  for c in e2e e2esolo; do
    $VAULT kv put -mount=secret "postgres/$c/pgbackrest_s3" access_key=e2e-access secret_key=e2e-secret-key-0123456789 >/dev/null
  done
  $VAULT kv put -mount=secret postgres/e2e/repmgr password=e2e-repmgr-pw >/dev/null
  for u in e2e_app e2e_read e2e_owner; do
    $VAULT kv put -mount=secret "postgres/e2e/users/$u" password="pw-$u-$RANDOM$RANDOM" >/dev/null
  done
  $VAULT kv put -mount=secret postgres/e2esolo/users/solo_app password="pw-solo-$RANDOM" >/dev/null
  printf 'path "secret/data/postgres/*" { capabilities = ["read"] }\n' |
    docker exec -i -e VAULT_ADDR=http://127.0.0.1:8200 -e VAULT_TOKEN=e2e-root pgops-e2e-vault vault policy write pg-ops - >/dev/null
  $VAULT auth list | grep -q '^approle/' || $VAULT auth enable approle >/dev/null
  $VAULT write auth/approle/role/pg-ops token_policies=pg-ops token_ttl=2h >/dev/null
  echo "   environment ready (vault seeded, bucket created)"
}
vault_login_env() {
  ANSIBLE_HASHI_VAULT_ROLE_ID=$($VAULT read -field=role_id auth/approle/role/pg-ops/role-id)
  ANSIBLE_HASHI_VAULT_SECRET_ID=$($VAULT write -f -field=secret_id auth/approle/role/pg-ops/secret-id)
  export ANSIBLE_HASHI_VAULT_ROLE_ID ANSIBLE_HASHI_VAULT_SECRET_ID
}
down() { docker compose -f "$E2E/docker-compose.yml" down -v --remove-orphans; rm -f "$VERSION_FILE"; }

# ------------------------------------------------------------------ HA scenario
ha() {
  vault_login_env
  [[ -f $VERSION_FILE ]] && PGV=$(sed -n 's/^pg_version_full: "\(.*\)"/\1/p' "$VERSION_FILE") || set_version 17.10

  if step "greenfield converge (17.10, custom layout, secrets from Vault)"; then
    set_version 17.10
    pb "$INV" site.yml
    expect_eq "$(role_of pg1)" primary "pg1 role"
    expect_eq "$(role_of pg2)" standby "pg2 role"
    expect_eq "$(streaming_count pg1)" 1 "streaming standbys on pg1"
    expect_eq "$(sql pg1 'SHOW server_version')" 17.10 "server version"
    sh_on pg1 'test -f /PKe2e01/data/pgs/17/data/PG_VERSION' && ok "data dir under /PKe2e01/data/pgs/17/data"
    sh_on pg1 'ls /PKe2e01/log/pgs/postgresql-*.log >/dev/null' && ok "PostgreSQL logs under /PKe2e01/log/pgs"
    sh_on pg1 'ls /PKe2e01/log/repmgr/repmgrd.log /PKe2e01/log/pgbackrest >/dev/null' && ok "repmgr/pgBackRest logs under /PKe2e01/log"
    expect_eq "$(sql pg1 'SHOW shared_preload_libraries')" "repmgr,pg_stat_statements,pgaudit,pgauditlogtofile" "shared_preload_libraries"
    expect_eq "$(sql pg1 "SELECT string_agg(extname, ',' ORDER BY extname) FROM pg_extension WHERE extname <> 'plpgsql'" e2edb)" \
      "pg_stat_statements,pgaudit,pgauditlogtofile,pgcrypto,vector" "extensions in e2edb"
    sh_on pg1 "dnf -q versionlock list | grep -q 'postgresql17-server-0:17.10'" && ok "postgresql17 locked at 17.10"
    sh_on wit "test -f /PKe2e01/data/pgs/17/data/PG_VERSION" && ok "witness initialised"
    sh_on pg1 "sudo -iu postgres /usr/pgsql-17/bin/repmgr -f /etc/repmgr/17/repmgr.conf cluster show" | grep -q 'witness.*\* running' \
      && ok "repmgr cluster show lists a running witness"
  fi

  if step "second converge is a no-op"; then
    pb "$INV" site.yml
    assert_idempotent
  fi

  if step "Vault secrets are really used"; then
    local pw
    pw=$($VAULT kv get -mount=secret -field=password postgres/e2e/users/e2e_app)
    sh_on pg1 "PGPASSWORD='$pw' /usr/pgsql-17/bin/psql -X -A -t -h 172.30.0.11 -U e2e_app -d e2edb -c 'select 1'" | grep -q 1 \
      && ok "e2e_app logs in with the password stored in Vault"
    if sh_on pg1 "PGPASSWORD=wrong /usr/pgsql-17/bin/psql -X -h 172.30.0.11 -U e2e_app -d e2edb -c 'select 1'" >/dev/null 2>&1; then
      fail "a wrong password was accepted"
    fi
    ok "a wrong password is rejected"
    $VAULT kv put -mount=secret postgres/e2e/users/e2e_read password=rotated-in-vault-42 >/dev/null
    pb "$INV" bootstrap_db.yml
    sh_on pg1 "PGPASSWORD=rotated-in-vault-42 /usr/pgsql-17/bin/psql -X -A -t -h 172.30.0.11 -U e2e_read -d e2edb -c 'select 1'" | grep -q 1 \
      && ok "password rotated in Vault is applied by bootstrap_db.yml"
  fi

  if step "replication, privileges and audit log"; then
    sql pg1 "CREATE TABLE IF NOT EXISTS e2edb.repl_check(id int); TRUNCATE e2edb.repl_check; INSERT INTO e2edb.repl_check SELECT generate_series(1,1000)" e2edb
    wait_for 30 "rows on pg2" bash -c "[[ \$(docker exec pgops-e2e-pg2 sudo -iu postgres /usr/pgsql-17/bin/psql -X -A -t -d e2edb -c 'select count(*) from e2edb.repl_check') == 1000 ]]"
    ok "1000 rows replicated to pg2"
    if sql pg2 "INSERT INTO e2edb.repl_check VALUES (1)" e2edb >/dev/null 2>&1; then fail "standby accepted a write"; fi
    ok "standby is read-only"
    sh_on pg1 "grep -l 'CREATE TABLE' /PKe2e01/log/pgs/audit-*.log >/dev/null" && ok "pgaudit DDL lines in /PKe2e01/log/pgs/audit-*.log"
  fi

  if step "backup to S3 (from the standby) + status"; then
    pb "$INV" backup_now.yml
    local n
    n=$(sh_on pg1 "sudo -iu postgres pgbackrest --stanza=e2e --output=json info" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)[0]["backup"]))')
    (( n >= 1 )) || fail "no backup in the repository"
    ok "$n backup(s) in s3://pgbackrest/pgbackrest/e2e"
    # (failures before the stanza existed during the greenfield build are expected)
    expect_eq "$(sql pg1 'SELECT last_failed_time IS NULL OR last_archived_time > last_failed_time FROM pg_stat_archiver')" t \
      "WAL archiving to S3 healthy (last success newer than last failure)"
    pb "$INV" cluster_status.yml
    ok "cluster_status.yml"
  fi

  if step "planned switchover pg1 -> pg2"; then
    pb "$INV" switchover.yml -e new_primary=pg2 -e confirm=YES
    expect_eq "$(role_of pg2)" primary "pg2 role"
    expect_eq "$(role_of pg1)" standby "pg1 role"
    expect_eq "$(streaming_count pg2)" 1 "streaming standbys on pg2"
  fi

  if step "automatic failover (stop the primary pg2), then rejoin"; then
    sh_on pg2 "systemctl stop postgresql-17"
    wait_for 150 "repmgrd promotes pg1" bash -c "[[ \$(docker exec pgops-e2e-pg1 sudo -iu postgres /usr/pgsql-17/bin/psql -X -A -t -c 'select pg_is_in_recovery()') == f ]]"
    ok "repmgrd promoted pg1 (witness consensus)"
    pb "$INV" rejoin.yml -e target=pg2 -e confirm=YES
    expect_eq "$(role_of pg2)" standby "pg2 role after rejoin"
    expect_eq "$(streaming_count pg1)" 1 "streaming standbys on pg1"
  fi

  if step "rebuild replica pg2"; then
    pb "$INV" rebuild_replica.yml -e target=pg2 -e confirm=YES
    expect_eq "$(role_of pg2)" standby "pg2 role"
    expect_eq "$(sql pg2 'select count(*) from e2edb.repl_check' e2edb)" 1000 "rows on rebuilt pg2"
  fi

  if step "converge with a new pg_version_full does not touch running nodes"; then
    set_version 17.11
    pb "$INV" site.yml
    expect_eq "$(sql pg1 'SHOW server_version')" 17.10 "pg1 still on"
    grep -q 'Version change postponed' "$LAST_LOG" && ok "converge reported the postponed version change"
  fi

  if step "rolling minor upgrade 17.10 -> 17.11"; then
    local p
    p=$(primary_host)
    pb "$INV" minor_upgrade.yml -e confirm=YES
    for h in pg1 pg2 wit; do expect_eq "$(sql $h 'SHOW server_version')" 17.11 "$h version"; done
    sh_on pg1 "dnf -q versionlock list | grep -q 'postgresql17-server-0:17.11'" && ok "version lock moved to 17.11"
    expect_eq "$(streaming_count "$(primary_host)")" 1 "streaming standbys after upgrade"
    ok "primary was $p, now $(primary_host)"
  fi

  if step "point-in-time restore"; then
    local p target
    p=$(primary_host)
    pb "$INV" backup_now.yml
    sql "$p" "DROP TABLE IF EXISTS e2edb.pitr; CREATE TABLE e2edb.pitr AS SELECT generate_series(1,500) id" e2edb
    sleep 2
    target=$(sql "$p" "SELECT to_char(now(), 'YYYY-MM-DD HH24:MI:SS.US+00') FROM (SELECT set_config('timezone','UTC',false)) s")
    sleep 2
    sql "$p" "DELETE FROM e2edb.pitr WHERE id > 100" e2edb
    sql "$p" "SELECT pg_switch_wal()" >/dev/null
    wait_for 60 "WAL archived" bash -c "docker exec pgops-e2e-$p sudo -iu postgres pgbackrest --stanza=e2e check"
    pb "$INV" restore_pitr.yml -e target="$p" -e "restore_target_time='$target'" -e confirm=YES
    expect_eq "$(sql "$p" 'select count(*) from e2edb.pitr' e2edb)" 500 "rows after PITR to $target"
    expect_eq "$(role_of "$p")" primary "$p role"
    expect_eq "$(role_of "$(other_host "$p")")" standby "$(other_host "$p") role"
    expect_eq "$(sql "$(other_host "$p")" 'select count(*) from e2edb.pitr' e2edb)" 500 "rows on the re-cloned standby"
  fi

  if step "major upgrade 17.11 -> 18.x (pg_upgrade --link)"; then
    local p new
    new=${E2E_PG_NEXT:-18.6}          # target of the major upgrade (PGDG 18 repo is added by the preflight)
    p=$(primary_host)
    pb "$INV" major_upgrade.yml -e pg_new_version_full="$new" -e confirm=YES
    set_version "$new"
    for h in pg1 pg2 wit; do expect_eq "$(sql $h 'SHOW server_version')" "$new" "$h version"; done
    expect_eq "$(role_of "$p")" primary "$p role"
    expect_eq "$(streaming_count "$p")" 1 "streaming standbys on $p"
    expect_eq "$(sql "$p" 'select count(*) from e2edb.pitr' e2edb)" 500 "data survived the upgrade"
    expect_eq "$(sql "$p" "SELECT string_agg(extname, ',' ORDER BY extname) FROM pg_extension WHERE extname <> 'plpgsql'" e2edb)" \
      "pg_stat_statements,pgaudit,pgauditlogtofile,pgcrypto,vector" "extensions after upgrade"
    sh_on "$p" "test -f /PKe2e01/data/pgs/18/data/PG_VERSION" && ok "new data dir /PKe2e01/data/pgs/18/data"
    local n
    n=$(sh_on "$p" "sudo -iu postgres pgbackrest --stanza=e2e --output=json info" | python3 -c 'import json,sys; d=json.load(sys.stdin)[0]; print(sum(1 for b in d["backup"] if b["database"]["id"] == max(x["database"]["id"] for x in d["backup"])))')
    (( n >= 1 )) || fail "no backup of the upgraded cluster"
    ok "fresh full backup of the upgraded cluster in S3"
  fi

  if step "converge on the new major is a no-op"; then
    pb "$INV" site.yml
    assert_idempotent
  fi
}

# ------------------------------------------------------------------ single-node scenario
solo() {
  vault_login_env
  PGV=17.11
  STEP=100; FROM=1
  if step "single node: converge (repmgr disabled, regular layout, Vault)"; then
    pb "$INV_SOLO" site.yml
    expect_eq "$(role_of solo)" primary "solo role"
    expect_eq "$(sql solo 'SHOW shared_preload_libraries')" "pg_stat_statements,pgaudit,pgauditlogtofile" "shared_preload_libraries (no repmgr)"
    sh_on solo 'test -f /var/lib/pgsql/17/data/PG_VERSION && ls /var/log/postgresql/postgresql-*.log >/dev/null' && ok "regular layout paths"
    sh_on solo '! rpm -q repmgr_17 >/dev/null' && ok "repmgr not installed"
  fi
  if step "single node: second converge is a no-op"; then
    pb "$INV_SOLO" site.yml
    assert_idempotent
  fi
  if step "single node: backup on the primary"; then
    pb "$INV_SOLO" backup_now.yml
    local n
    n=$(sh_on solo "sudo -iu postgres pgbackrest --stanza=e2esolo --output=json info" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)[0]["backup"]))')
    (( n >= 1 )) || fail "no backup"
    ok "$n backup(s) in s3://pgbackrest/pgbackrest-solo/e2esolo"
  fi
  if step "single node: HA playbooks refuse to run"; then
    pb_must_fail "$INV_SOLO" switchover.yml -e new_primary=solo -e confirm=YES
    ok "switchover.yml refused"
  fi
}

summary() {
  echo
  echo "=================== PASSED (${#PASSED[@]} checks)"
  printf '  %s\n' "${PASSED[@]}"
}

case "${1:-all}" in
  up) up ;;
  ha) ha; summary ;;
  solo) solo; summary ;;
  down) down ;;
  all) up; ha; solo; summary ;;
  *) echo "usage: $0 [all|up|ha|solo|down]" >&2; exit 2 ;;
esac
