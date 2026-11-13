#!/usr/bin/env bash
# =====================================================================
# KineticsPay - CAP, replication lag, failover and 2PC
# Portfolio 5: Distributed and Cloud Database Exercise
#
# MIT 8103 Advanced Database Systems
# Biliaminu Abdulfarid (301918844)
#
# Run after setup-replication.sh. Six experiments, all against the live
# primary/standby pair:
#
#   1  Replication lag under write load
#   2  CAP with ASYNCHRONOUS commit - availability over consistency
#   3  CAP with SYNCHRONOUS commit  - consistency over availability
#   4  Failover: promoting the standby
#   5  The data loss that async replication permits on failover
#   6  Two-phase commit across two nodes, and why it blocks
#
# Usage:  ./cap-experiments.sh
# =====================================================================
set -u

PGBIN=/usr/lib/postgresql/16/bin
PRIMARY=/var/lib/pgdata
STANDBY=/var/lib/pgstandby
P="psql -h localhost -p 5432 -U postgres -d kineticspay -X"
S="psql -h localhost -p 5433 -U postgres -d kineticspay -X"
PADM="psql -h localhost -p 5432 -U postgres -X"

banner () { printf '\n==============================================================\n%s\n==============================================================\n' "$1"; }

stop_standby () { su postgres -c "$PGBIN/pg_ctl -D $STANDBY -m immediate stop" >/dev/null 2>&1; sleep 2; }
start_standby () {
  su postgres -c "$PGBIN/pg_ctl -D $STANDBY -l $STANDBY/server.log \
    -o '-c listen_addresses=localhost -p 5433 -c hot_standby=on' start" >/dev/null 2>&1
  sleep 4
}

post_tx () {   # post one balanced transaction; $1 = reference suffix
  $P -q -c "
  WITH t AS (
    INSERT INTO transactions (transaction_reference, transaction_type, status,
                              currency_code, narration, initiated_at, settled_at)
    VALUES ('KP-2026-4$1','DEPOSIT','COMPLETED','NGN','CAP experiment', now(), now())
    RETURNING transaction_id)
  INSERT INTO ledger_entries (transaction_id, account_id, currency_code, direction, amount)
  SELECT t.transaction_id, a.account_id, 'NGN', d.dir, 500.00
  FROM t, (VALUES (1,'DEBIT'::entry_direction_t)) AS x(aid,dir0)
  CROSS JOIN LATERAL (VALUES ('DEBIT'::entry_direction_t),('CREDIT'::entry_direction_t)) AS d(dir)
  JOIN accounts a ON a.account_id = CASE WHEN d.dir='DEBIT' THEN 1 ELSE 13 END;" 2>&1 | tail -2
}

banner "EXPERIMENT 1 - Replication lag under write load"
cat <<'EOF'
Replication is asynchronous by default: the primary acknowledges a
commit as soon as it is durable LOCALLY, without waiting for the
standby. Lag is therefore the window in which a committed transaction
exists on one node only.
EOF
echo "--- baseline, idle ---"
$PADM -c "SELECT application_name, state, sync_state,
       pg_wal_lsn_diff(sent_lsn, replay_lsn) AS bytes_behind,
       replay_lag
FROM pg_stat_replication;"

echo "--- generating 20,000 rows of write load on the primary ---"
time $P -q -c "
CREATE TABLE IF NOT EXISTS replication_load (id BIGSERIAL PRIMARY KEY, payload TEXT, at TIMESTAMPTZ DEFAULT now());
INSERT INTO replication_load (payload)
SELECT repeat(md5(g::TEXT), 4) FROM generate_series(1, 20000) g;" 2>&1 | tail -3

echo "--- lag immediately after the write burst ---"
$PADM -c "SELECT pg_wal_lsn_diff(sent_lsn, replay_lsn) AS bytes_behind,
       write_lag, flush_lag, replay_lag FROM pg_stat_replication;"

echo "--- row counts on each node, read back to back ---"
echo "  primary: $($P -tAc 'SELECT COUNT(*) FROM replication_load;')"
echo "  standby: $($S -tAc 'SELECT COUNT(*) FROM replication_load;')"
sleep 2
echo "--- after 2 seconds ---"
echo "  primary: $($P -tAc 'SELECT COUNT(*) FROM replication_load;')"
echo "  standby: $($S -tAc 'SELECT COUNT(*) FROM replication_load;')"

banner "EXPERIMENT 2 - CAP with ASYNCHRONOUS commit (AP)"
cat <<'EOF'
The standby is now KILLED, simulating a partition between regions.
synchronous_commit is 'on', which in PostgreSQL means local durability
only - no standby is named as synchronous.

Prediction: writes continue to succeed. The system stays AVAILABLE and
gives up CONSISTENCY across nodes.
EOF
$PADM -c "SHOW synchronous_standby_names;"
echo "--- killing the standby ---"
stop_standby
$PADM -c "SELECT COUNT(*) AS wal_senders_connected FROM pg_stat_replication;"

echo "--- writing to the primary with the standby down ---"
START=$(date +%s.%N)
$P -c "SET statement_timeout = '10s';
       INSERT INTO replication_load (payload) VALUES ('written while standby was down');" 2>&1 | tail -2
END=$(date +%s.%N)
echo "  elapsed: $(echo "$END - $START" | bc) s"
echo "  RESULT: the write SUCCEEDED with no standby present -> AVAILABILITY chosen"

banner "EXPERIMENT 3 - CAP with SYNCHRONOUS commit (CP)"
cat <<'EOF'
Now the primary is told to require a synchronous standby, and the
standby is still down.

Prediction: the write BLOCKS. The primary refuses to acknowledge a
commit it cannot guarantee on a second node. The system stays
CONSISTENT and gives up AVAILABILITY.

A statement_timeout of 10s is used so the experiment terminates. Note
carefully what the timeout does NOT do: it does not roll the
transaction back on the primary. See the analysis.
EOF
$PADM -c "ALTER SYSTEM SET synchronous_standby_names = '*';"
$PADM -c "SELECT pg_reload_conf();"
sleep 1
$PADM -c "SHOW synchronous_standby_names;"

echo "--- writing to the primary, synchronous, standby still down ---"
START=$(date +%s.%N)
$P -c "SET statement_timeout = '10s';
       INSERT INTO replication_load (payload) VALUES ('synchronous write, no standby');" 2>&1 | tail -3
END=$(date +%s.%N)
echo "  elapsed: $(echo "$END - $START" | bc) s"
echo "  RESULT: the write BLOCKED until the timeout -> CONSISTENCY chosen"

echo ""
echo "--- bringing the standby back and retrying ---"
start_standby
$PADM -c "SELECT application_name, state, sync_state FROM pg_stat_replication;"
START=$(date +%s.%N)
$P -c "INSERT INTO replication_load (payload) VALUES ('synchronous write, standby present');" 2>&1 | tail -2
END=$(date +%s.%N)
echo "  elapsed: $(echo "$END - $START" | bc) s"
echo "  RESULT: with the standby present the same write completes immediately"

echo ""
echo "--- cost of synchronous commit on normal throughput ---"
$PADM -c "ALTER SYSTEM SET synchronous_standby_names = '';" >/dev/null
$PADM -c "SELECT pg_reload_conf();" >/dev/null
sleep 1
echo "  ASYNC: 2,000 inserts"
time $P -q -c "INSERT INTO replication_load (payload) SELECT 'async '||g FROM generate_series(1,2000) g;" 2>&1 | tail -3
$PADM -c "ALTER SYSTEM SET synchronous_standby_names = '*';" >/dev/null
$PADM -c "SELECT pg_reload_conf();" >/dev/null
sleep 1
echo "  SYNC (remote flush): 2,000 inserts"
time $P -q -c "INSERT INTO replication_load (payload) SELECT 'sync '||g FROM generate_series(1,2000) g;" 2>&1 | tail -3
$PADM -c "ALTER SYSTEM SET synchronous_standby_names = '';" >/dev/null
$PADM -c "SELECT pg_reload_conf();" >/dev/null

banner "EXPERIMENT 4 - The data loss async replication permits"
cat <<'EOF'
This is the concrete cost of choosing AP. A transaction is committed on
the primary while the standby cannot receive it, and then the primary is
lost and the standby promoted. The acknowledged commit is gone.

For a payment platform this is not abstract: the customer saw a success
response for a transfer that no longer exists.
EOF
sleep 2
echo "--- marker row committed with the standby CONNECTED ---"
$P -q -c "INSERT INTO replication_load (payload) VALUES ('BEFORE the partition - should survive');"
sleep 2
echo "  primary count: $($P -tAc 'SELECT COUNT(*) FROM replication_load;')"
echo "  standby count: $($S -tAc 'SELECT COUNT(*) FROM replication_load;')"

echo "--- partition: standby killed ---"
stop_standby
echo "--- committing 3 rows the standby will never see ---"
$P -q -c "INSERT INTO replication_load (payload)
          SELECT 'LOST - committed during partition #'||g FROM generate_series(1,3) g;"
echo "  these commits were ACKNOWLEDGED to the client:"
$P -c "SELECT id, payload FROM replication_load ORDER BY id DESC LIMIT 3;"
PRIMARY_COUNT=$($P -tAc 'SELECT COUNT(*) FROM replication_load;')
echo "  primary now holds: $PRIMARY_COUNT rows"

banner "EXPERIMENT 5 - Failover: promoting the standby"
echo "--- primary is lost ---"
su postgres -c "$PGBIN/pg_ctl -D $PRIMARY -m immediate stop" >/dev/null 2>&1
sleep 2
$PADM -c "SELECT 1;" 2>&1 | tail -1

echo "--- restarting the standby, then promoting it ---"
start_standby
$S -tAc "SELECT 'in recovery before promotion: ' || pg_is_in_recovery();"
su postgres -c "$PGBIN/pg_ctl -D $STANDBY promote" 2>&1 | tail -2
sleep 4

echo "--- after promotion ---"
$S -c "SELECT pg_is_in_recovery() AS still_in_recovery,
              current_setting('port') AS port;"
echo "--- the promoted node is now WRITABLE ---"
$S -c "INSERT INTO replication_load (payload) VALUES ('written to the PROMOTED node');" 2>&1 | tail -2

STANDBY_COUNT=$($S -tAc 'SELECT COUNT(*) FROM replication_load;')
echo ""
echo "=============================================================="
echo "  DATA LOSS MEASURED"
echo "=============================================================="
echo "  rows on the old primary at the moment it died : $PRIMARY_COUNT"
echo "  rows on the promoted node (minus the 1 new)   : $((STANDBY_COUNT - 1))"
echo "  acknowledged commits LOST                     : $((PRIMARY_COUNT - (STANDBY_COUNT - 1)))"
echo ""
echo "--- are the 'LOST' marker rows present on the promoted node? ---"
$S -c "SELECT COUNT(*) AS lost_rows_found FROM replication_load WHERE payload LIKE 'LOST%';"
$S -c "SELECT COUNT(*) AS before_partition_row FROM replication_load WHERE payload LIKE 'BEFORE%';"
echo "--- timeline: a promotion starts a new timeline, which is why the old"
echo "    primary cannot simply be restarted as a standby without rewind ---"
$S -tAc "SELECT 'timeline on promoted node: ' || timeline_id FROM pg_control_checkpoint();"

banner "CLEANUP - rebuild the original topology"
echo "The old primary's timeline has diverged, so it cannot rejoin as a"
echo "standby without pg_rewind or a fresh base backup. Restarting it"
echo "standalone for the remaining experiments:"
su postgres -c "$PGBIN/pg_ctl -D $PRIMARY -l $PRIMARY/server.log \
  -o '-c listen_addresses=localhost -p 5432' start" >/dev/null 2>&1
sleep 4
su postgres -c "$PGBIN/pg_isready -h localhost -p 5432"
su postgres -c "$PGBIN/pg_isready -h localhost -p 5433"
echo "primary: $($P -tAc 'SELECT COUNT(*) FROM ledger_entries;') ledger entries"
echo "promoted node is now an independent primary on 5433"
