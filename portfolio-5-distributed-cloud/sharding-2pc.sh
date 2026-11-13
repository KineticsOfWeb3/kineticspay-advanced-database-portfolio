#!/usr/bin/env bash
# =====================================================================
# KineticsPay - fragmentation, sharding and two-phase commit
# Portfolio 5: Distributed and Cloud Database Exercise
#
# MIT 8103 Advanced Database Systems
# Biliaminu Abdulfarid (301918844)
#
# Four experiments:
#
#   7  Horizontal fragmentation by region (declarative partitioning),
#      motivated by NDPA 2023 data residency
#   8  Partition pruning - what the planner does with the fragments
#   9  Cross-node sharding with postgres_fdw
#  10  Two-phase commit, and the blocking problem that makes it
#      unattractive for a payment platform
#
# The node promoted in Experiment 5 is reused as a second shard, so both
# nodes are independent primaries:
#     node A  localhost:5432   Lagos
#     node B  localhost:5433   Abuja
#
# Usage:  ./sharding-2pc.sh
# =====================================================================
set -u

A="psql -h localhost -p 5432 -U postgres -d kineticspay -X"
B="psql -h localhost -p 5433 -U postgres -d kineticspay -X"

banner () { printf '\n==============================================================\n%s\n==============================================================\n' "$1"; }

banner "EXPERIMENT 7 - Horizontal fragmentation by region (NDPA 2023)"
cat <<'EOF'
WHY FRAGMENT AT ALL

The Nigeria Data Protection Act 2023 restricts transfers of personal
data outside Nigeria unless the destination provides adequate
protection. A payment platform operating across West Africa therefore
cannot simply replicate every customer's records to whichever region has
spare capacity.

Horizontal fragmentation is the structural answer: split by ROWS, on a
region key, so that Nigerian data subjects' postings physically reside
in Nigerian infrastructure. This is the same horizontal fragmentation
Study Session 02 describes, and the reason GlobalBank in the Atomic Poll
chose it.

Vertical fragmentation (splitting COLUMNS) would not help here: every
fragment would still contain rows belonging to every data subject.
EOF

$A -q <<'SQL'
DROP TABLE IF EXISTS ledger_entries_sharded CASCADE;

CREATE TABLE ledger_entries_sharded (
    entry_id       BIGINT        NOT NULL,
    transaction_id BIGINT        NOT NULL,
    account_id     BIGINT        NOT NULL,
    region         TEXT          NOT NULL,
    currency_code  CHAR(3)       NOT NULL,
    direction      entry_direction_t NOT NULL,
    amount         NUMERIC(20,4) NOT NULL CHECK (amount > 0),
    posted_at      TIMESTAMPTZ   NOT NULL,
    PRIMARY KEY (entry_id, region)
) PARTITION BY LIST (region);

-- One partition per jurisdiction. In a real deployment each would sit on
-- a tablespace backed by storage in that jurisdiction, or on a separate
-- node entirely (Experiment 9).
CREATE TABLE ledger_ng_lagos PARTITION OF ledger_entries_sharded
    FOR VALUES IN ('NG_LAGOS');
CREATE TABLE ledger_ng_abuja PARTITION OF ledger_entries_sharded
    FOR VALUES IN ('NG_ABUJA');
CREATE TABLE ledger_gh_accra PARTITION OF ledger_entries_sharded
    FOR VALUES IN ('GH_ACCRA');
CREATE TABLE ledger_other     PARTITION OF ledger_entries_sharded DEFAULT;
SQL

echo "--- loading the real ledger into regional fragments ---"
echo "    region derived from account_id so the split is deterministic"
time $A -q -c "
INSERT INTO ledger_entries_sharded
    (entry_id, transaction_id, account_id, region, currency_code,
     direction, amount, posted_at)
SELECT le.entry_id, le.transaction_id, le.account_id,
       CASE
         WHEN le.currency_code = 'USD'       THEN 'GH_ACCRA'
         WHEN le.account_id % 3 = 0          THEN 'NG_ABUJA'
         ELSE 'NG_LAGOS'
       END,
       le.currency_code, le.direction, le.amount, le.posted_at
FROM ledger_entries le;" 2>&1 | tail -3

$A -c "
SELECT c.relname AS fragment,
       (SELECT COUNT(*) FROM ledger_entries_sharded s
         WHERE tableoid = c.oid) AS rows,
       pg_size_pretty(pg_total_relation_size(c.oid)) AS size
FROM pg_class c
JOIN pg_inherits i ON i.inhrelid = c.oid
WHERE i.inhparent = 'ledger_entries_sharded'::regclass
ORDER BY c.relname;"

$A -c "SELECT region, COUNT(*) AS postings,
              ROUND(100.0*COUNT(*)/SUM(COUNT(*)) OVER (),1) AS pct,
              SUM(amount) AS total_value
       FROM ledger_entries_sharded GROUP BY region ORDER BY postings DESC;"

banner "EXPERIMENT 8 - Partition pruning: does the planner use the fragments?"
cat <<'EOF'
Fragmentation only pays off if the planner can EXCLUDE fragments it does
not need. A query scoped to one region should touch one partition.
EOF
echo "--- 8A: query scoped to one region (expect ONE partition scanned) ---"
$A -c "EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT COUNT(*), SUM(amount) FROM ledger_entries_sharded
WHERE region = 'NG_LAGOS';" 2>&1 | head -12

echo ""
echo "--- 8B: query with NO region predicate (expect ALL partitions scanned) ---"
$A -c "EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT COUNT(*), SUM(amount) FROM ledger_entries_sharded;" 2>&1 | head -14

echo ""
echo "--- 8C: a cross-region aggregate - the real cost of fragmenting ---"
echo "    a compliance report spanning jurisdictions must touch every fragment"
$A -c "EXPLAIN (ANALYZE, COSTS OFF)
SELECT region, COUNT(*) FROM ledger_entries_sharded GROUP BY region;" 2>&1 | head -10

banner "EXPERIMENT 9 - Cross-node sharding with postgres_fdw"
cat <<'EOF'
Partitions above live on ONE node. Real sharding puts them on separate
nodes. postgres_fdw makes a remote table queryable as if it were local,
which is the mechanism behind a federated or sharded PostgreSQL
deployment.

Node B (port 5433) is the node promoted in Experiment 5, now an
independent primary. It plays the Abuja shard.
EOF
$A -q -c "CREATE EXTENSION IF NOT EXISTS postgres_fdw;"
$A -q <<'SQL'
DROP SERVER IF EXISTS shard_abuja CASCADE;
CREATE SERVER shard_abuja FOREIGN DATA WRAPPER postgres_fdw
    OPTIONS (host 'localhost', port '5433', dbname 'kineticspay');
CREATE USER MAPPING FOR postgres SERVER shard_abuja
    OPTIONS (user 'postgres');
SQL

echo "--- creating a local table on node B to stand in as the remote shard ---"
$B -q <<'SQL'
DROP TABLE IF EXISTS ledger_abuja_remote;
CREATE TABLE ledger_abuja_remote (
    entry_id       BIGINT PRIMARY KEY,
    transaction_id BIGINT NOT NULL,
    account_id     BIGINT NOT NULL,
    currency_code  CHAR(3) NOT NULL,
    direction      TEXT NOT NULL,
    amount         NUMERIC(20,4) NOT NULL,
    posted_at      TIMESTAMPTZ NOT NULL
);
SQL

echo "--- moving the Abuja fragment to node B ---"
$A -q -c "\copy (SELECT entry_id, transaction_id, account_id, currency_code, direction::TEXT, amount, posted_at FROM ledger_entries_sharded WHERE region='NG_ABUJA') TO '/tmp/abuja.csv' WITH (FORMAT csv)"
$B -q -c "\copy ledger_abuja_remote FROM '/tmp/abuja.csv' WITH (FORMAT csv)"
$B -c "SELECT COUNT(*) AS rows_on_node_b FROM ledger_abuja_remote;"

echo "--- exposing it on node A as a foreign table ---"
$A -q <<'SQL'
DROP FOREIGN TABLE IF EXISTS ledger_abuja;
CREATE FOREIGN TABLE ledger_abuja (
    entry_id       BIGINT,
    transaction_id BIGINT,
    account_id     BIGINT,
    currency_code  CHAR(3),
    direction      TEXT,
    amount         NUMERIC(20,4),
    posted_at      TIMESTAMPTZ
) SERVER shard_abuja OPTIONS (table_name 'ledger_abuja_remote');
SQL
$A -c "SELECT COUNT(*) AS rows_visible_from_node_a FROM ledger_abuja;"

echo ""
echo "--- 9A: aggregate pushed DOWN to the remote node ---"
$A -c "EXPLAIN (ANALYZE, VERBOSE, COSTS OFF)
SELECT COUNT(*), SUM(amount) FROM ledger_abuja;" 2>&1 | head -12

echo ""
echo "--- 9B: a JOIN across the shard boundary ---"
$A -c "EXPLAIN (ANALYZE, COSTS OFF)
SELECT a.account_type, COUNT(*)
FROM ledger_abuja r JOIN accounts a ON a.account_id = r.account_id
GROUP BY a.account_type;" 2>&1 | head -14

echo ""
echo "--- 9C: local fragment versus remote shard, same query ---"
echo "  LOCAL partition:"
for i in 1 2 3; do
  $A -tAc "EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF) SELECT COUNT(*) FROM ledger_entries_sharded WHERE region='NG_ABUJA';" 2>&1 | grep -oE "Execution Time: [0-9.]+ ms"
done
echo "  REMOTE shard over FDW:"
for i in 1 2 3; do
  $A -tAc "EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF) SELECT COUNT(*) FROM ledger_abuja;" 2>&1 | grep -oE "Execution Time: [0-9.]+ ms"
done

banner "EXPERIMENT 10 - Two-phase commit across two nodes"
cat <<'EOF'
A transfer whose sender is in Lagos and recipient in Abuja must be
atomic across BOTH nodes. The classic mechanism is two-phase commit:
PREPARE on every participant, then COMMIT PREPARED on every participant.

PostgreSQL exposes the participant half directly.
EOF
$A -c "SHOW max_prepared_transactions;"
$B -c "SHOW max_prepared_transactions;"

echo ""
echo "--- 10A: a successful distributed transaction ---"
$A -q -c "BEGIN; INSERT INTO ledger_entries_sharded
   (entry_id, transaction_id, account_id, region, currency_code, direction, amount, posted_at)
   VALUES (999000001, 1, 13, 'NG_LAGOS', 'NGN', 'DEBIT', 7500.00, now());
   PREPARE TRANSACTION 'xfer_lagos_001';"
$B -q -c "BEGIN; INSERT INTO ledger_abuja_remote
   (entry_id, transaction_id, account_id, currency_code, direction, amount, posted_at)
   VALUES (999000002, 1, 13, 'NGN', 'CREDIT', 7500.00, now());
   PREPARE TRANSACTION 'xfer_abuja_001';"

echo "  both nodes have PREPARED but not committed:"
$A -c "SELECT gid, prepared, database FROM pg_prepared_xacts;"
$B -c "SELECT gid, prepared, database FROM pg_prepared_xacts;"
echo "  is the row visible yet on node A? (expect 0 - prepared is not committed)"
$A -tAc "SELECT COUNT(*) FROM ledger_entries_sharded WHERE entry_id = 999000001;"

echo "  phase 2: commit on both"
$A -q -c "COMMIT PREPARED 'xfer_lagos_001';"
$B -q -c "COMMIT PREPARED 'xfer_abuja_001';"
echo "  node A now sees: $($A -tAc 'SELECT COUNT(*) FROM ledger_entries_sharded WHERE entry_id = 999000001;')"
echo "  node B now sees: $($B -tAc 'SELECT COUNT(*) FROM ledger_abuja_remote WHERE entry_id = 999000002;')"

echo ""
echo "--- 10B: THE BLOCKING PROBLEM - coordinator dies after PREPARE ---"
cat <<'EOF'
    Node A prepares. The coordinator then crashes before telling anyone
    whether to commit or abort. The prepared transaction survives, holds
    its locks, and holds back the transaction horizon - indefinitely.
EOF
$A -q -c "BEGIN; INSERT INTO ledger_entries_sharded
   (entry_id, transaction_id, account_id, region, currency_code, direction, amount, posted_at)
   VALUES (999000003, 1, 13, 'NG_LAGOS', 'NGN', 'DEBIT', 123.00, now());
   PREPARE TRANSACTION 'orphan_xfer_002';"
echo "  coordinator is now assumed dead. State left behind:"
$A -c "SELECT gid, prepared, owner FROM pg_prepared_xacts;"
echo "  locks still held by the orphan:"
$A -c "SELECT l.locktype, l.relation::regclass AS rel, l.mode
       FROM pg_locks l WHERE l.transactionid IS NOT NULL OR l.relation IS NOT NULL
       AND l.pid IS NULL LIMIT 5;"
echo "  effect on VACUUM: the orphan pins the transaction horizon"
$A -c "SELECT COUNT(*) AS prepared_xacts_blocking_vacuum,
              MIN(age(transaction)) AS oldest_xid_age
       FROM pg_prepared_xacts;"
echo ""
echo "  a new session touching the same row now WAITS on the orphan:"
timeout 8 $A -c "SET lock_timeout = '5s';
  DELETE FROM ledger_entries_sharded WHERE entry_id = 999000003;" 2>&1 | tail -3
echo ""
echo "  only a human (or an external transaction manager) can resolve it:"
$A -q -c "ROLLBACK PREPARED 'orphan_xfer_002';"
$A -c "SELECT COUNT(*) AS remaining_prepared FROM pg_prepared_xacts;"

banner "CLEANUP"
$A -q -c "DROP FOREIGN TABLE IF EXISTS ledger_abuja; DROP SERVER IF EXISTS shard_abuja CASCADE;" 2>/dev/null
echo "done"
