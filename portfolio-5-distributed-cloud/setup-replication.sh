#!/usr/bin/env bash
# =====================================================================
# KineticsPay - PostgreSQL streaming replication
# Portfolio 5: Distributed and Cloud Database Exercise
#
# MIT 8103 Advanced Database Systems
# Biliaminu Abdulfarid (301918844)
#
# Builds a real primary + hot standby pair on one host, two ports:
#
#     primary  localhost:5432   /var/lib/pgdata     (Lagos region)
#     standby  localhost:5433   /var/lib/pgstandby  (Abuja region)
#
# Two ports on one machine is not a multi-region deployment. What it IS
# is genuine physical streaming replication: a real WAL sender, a real
# replication slot, a real read-only hot standby, and a real failover.
# Everything measured in the experiments that follow is produced by that
# machinery rather than described. The network latency of a true
# multi-region link is the one thing this cannot reproduce, and that is
# stated wherever it matters.
#
# Usage:  ./setup-replication.sh
# =====================================================================
set -u

PGBIN=/usr/lib/postgresql/16/bin
PRIMARY=/var/lib/pgdata
STANDBY=/var/lib/pgstandby
PSQL_P="psql -h localhost -p 5432 -U postgres -X"

banner () { printf '\n==============================================================\n%s\n==============================================================\n' "$1"; }

banner "1. Prepare the primary for replication and 2PC"

# max_prepared_transactions defaults to 0, which disables PREPARE
# TRANSACTION entirely. Two-phase commit needs it, and changing it
# requires a restart.
$PSQL_P -c "ALTER SYSTEM SET max_prepared_transactions = 20;"
$PSQL_P -c "ALTER SYSTEM SET wal_level = 'replica';"
$PSQL_P -c "ALTER SYSTEM SET max_wal_senders = 10;"
$PSQL_P -c "ALTER SYSTEM SET wal_keep_size = '256MB';"
$PSQL_P -c "ALTER SYSTEM SET hot_standby_feedback = on;"

# A replication role, and trust auth for the loopback replication
# connection. In a real deployment this would be scram-sha-256 over TLS
# with a restricted CIDR - noted in deployment/README.
$PSQL_P -c "DROP ROLE IF EXISTS replicator;" 2>/dev/null
$PSQL_P -c "CREATE ROLE replicator WITH REPLICATION LOGIN PASSWORD 'replica_pw';"
grep -q "replicator" $PRIMARY/pg_hba.conf 2>/dev/null || \
  echo "host replication replicator 127.0.0.1/32 trust" >> $PRIMARY/pg_hba.conf

su postgres -c "$PGBIN/pg_ctl -D $PRIMARY -m fast restart -l $PRIMARY/server.log -o '-c listen_addresses=localhost -p 5432'" >/dev/null 2>&1
sleep 4
su postgres -c "$PGBIN/pg_isready -h localhost -p 5432"
$PSQL_P -c "SELECT name, setting FROM pg_settings WHERE name IN ('max_prepared_transactions','wal_level','wal_keep_size','hot_standby_feedback');"

banner "2. Create a physical replication slot"
# A slot makes the primary RETAIN WAL the standby has not consumed. The
# trade-off is explicit and worth stating: without a slot a standby that
# falls far behind can be orphaned when the WAL it needs is recycled;
# with one, a standby that stays offline will eventually fill the
# primary's disk. Neither is free.
$PSQL_P -c "SELECT pg_drop_replication_slot('standby_abuja') WHERE EXISTS (SELECT 1 FROM pg_replication_slots WHERE slot_name='standby_abuja');" 2>/dev/null
$PSQL_P -c "SELECT * FROM pg_create_physical_replication_slot('standby_abuja');"

banner "3. Base backup to build the standby"
su postgres -c "$PGBIN/pg_ctl -D $STANDBY -m immediate stop" >/dev/null 2>&1
rm -rf $STANDBY
mkdir -p $STANDBY && chown postgres:postgres $STANDBY && chmod 700 $STANDBY

echo "running pg_basebackup (streams the whole 528k-row cluster) ..."
time su postgres -c "$PGBIN/pg_basebackup -h localhost -p 5432 -U replicator \
     -D $STANDBY -Fp -Xs -P -R -S standby_abuja" 2>&1 | tail -4

banner "4. Configure and start the standby"
# -R already wrote primary_conninfo and standby.signal. Confirm:
echo "--- standby.signal present? ---"
ls -la $STANDBY/standby.signal 2>&1 | tail -1
echo "--- primary_conninfo ---"
grep -E "primary_conninfo|primary_slot_name" $STANDBY/postgresql.auto.conf

su postgres -c "$PGBIN/pg_ctl -D $STANDBY -l $STANDBY/server.log \
     -o '-c listen_addresses=localhost -p 5433 -c hot_standby=on' start" >/dev/null 2>&1
sleep 4
su postgres -c "$PGBIN/pg_isready -h localhost -p 5433"

banner "5. Verify the replication link is live"
echo "--- on the primary: who is connected as a WAL sender? ---"
$PSQL_P -x -c "SELECT application_name, state, sync_state, sent_lsn, write_lsn,
                      flush_lsn, replay_lsn, write_lag, flush_lag, replay_lag
               FROM pg_stat_replication;"

echo "--- on the standby: is it in recovery? ---"
psql -h localhost -p 5433 -U postgres -X -c "SELECT pg_is_in_recovery() AS in_recovery,
       pg_last_wal_receive_lsn() AS received, pg_last_wal_replay_lsn() AS replayed;"

echo "--- does the standby already hold the data? ---"
psql -h localhost -p 5433 -U postgres -d kineticspay -X -tAc \
  "SELECT 'ledger entries on standby: ' || COUNT(*) FROM ledger_entries;"

banner "6. The standby is READ-ONLY"
echo "attempting a write on the standby (must be refused):"
psql -h localhost -p 5433 -U postgres -d kineticspay -X 2>&1 <<'SQL' | tail -3
INSERT INTO transactions (transaction_reference, transaction_type, status,
                          currency_code, narration, initiated_at, settled_at)
VALUES ('KP-2026-550001','DEPOSIT','COMPLETED','NGN','write to standby', now(), now());
SQL

echo ""
echo "setup complete: primary on 5432, hot standby on 5433"
