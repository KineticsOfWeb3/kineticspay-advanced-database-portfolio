#!/usr/bin/env bash
# =====================================================================
# KineticsPay - Portfolio 2 benchmark runner
# MIT 8103 Advanced Database Systems
# Biliaminu Abdulfarid (301918844)
#
# Runs seven experiments against the loaded benchmark dataset and writes
# the captured execution plans into execution-plans/.
#
# Each measured query is run REPEATEDLY (3 warm runs). Experiment 1 also
# includes a cold run taken immediately after a server restart, so the
# difference between reading from disk and reading from shared buffers is
# visible rather than assumed.
#
# Usage:  ./run-benchmarks.sh
# =====================================================================
set -u

PSQL="psql -h localhost -U postgres -d kineticspay -X"
PGCTL="/usr/lib/postgresql/16/bin/pg_ctl -D /var/lib/pgdata"
OUT="execution-plans"
mkdir -p "$OUT"

# Representative accounts, chosen from the actual posting distribution:
BUSY_WALLET=2415     #  56,297 postings  = 10.65 % of the table
MID_WALLET=3547      #     694 postings  =  0.13 %
QUIET_WALLET=13      #       6 postings  =  0.001 %
BANK_NGN=1           # 115,724 postings  = 21.89 %

banner () { printf '\n==============================================================\n%s\n==============================================================\n' "$1"; }

restart_pg () {
    su postgres -c "$PGCTL stop -m fast" >/dev/null 2>&1
    sleep 1
    su postgres -c "$PGCTL -l /var/lib/pgdata/server.log -o '-c listen_addresses=localhost -p 5432' start" >/dev/null 2>&1
    sleep 3
}

# Run one EXPLAIN three times, labelling each run.
repeat3 () {
    local label="$1"; local sql="$2"
    for i in 1 2 3; do
        echo ""
        echo "--- $label | run $i ---"
        $PSQL -c "EXPLAIN (ANALYZE, BUFFERS, COSTS, TIMING) $sql" 2>&1
    done
}

# ---------------------------------------------------------------------
# Make sure we start from a known state: no secondary indexes.
# ---------------------------------------------------------------------
$PSQL -q <<'SQL'
DROP INDEX IF EXISTS idx_le_account;
DROP INDEX IF EXISTS idx_le_account_posted;
DROP INDEX IF EXISTS idx_le_direction;
DROP MATERIALIZED VIEW IF EXISTS mv_account_balances;
DROP TABLE IF EXISTS ledger_entries_bench;
SQL

# =====================================================================
# EXPERIMENT 1 - Sequential scan vs index scan
# =====================================================================
{
banner "EXPERIMENT 1 - Sequential scan versus index scan"
cat <<EOF
Query: every posting for one mid-volume wallet (account_id = $MID_WALLET,
694 rows, 0.13% of the table).

Part A measures the unindexed baseline. Part B adds a single-column index
and repeats. A cold run follows a server restart so that disk reads are
distinguishable from shared-buffer hits.
EOF

banner "1A - BASELINE, no secondary index (COLD: server just restarted)"
restart_pg
$PSQL -c "EXPLAIN (ANALYZE, BUFFERS) SELECT entry_id, transaction_id, account_id, amount, posted_at FROM ledger_entries WHERE account_id = $MID_WALLET;" 2>&1

banner "1A - BASELINE, no secondary index (WARM)"
repeat3 "baseline seq scan" "SELECT entry_id, transaction_id, account_id, amount, posted_at FROM ledger_entries WHERE account_id = $MID_WALLET;"

banner "1B - CREATE INDEX"
$PSQL -c "\timing on" -c "CREATE INDEX idx_le_account ON ledger_entries (account_id);" 2>&1
$PSQL -c "ANALYZE ledger_entries;" 2>&1
$PSQL -c "SELECT pg_size_pretty(pg_relation_size('idx_le_account')) AS index_size;" 2>&1

banner "1B - WITH single-column index (COLD: server just restarted)"
restart_pg
$PSQL -c "EXPLAIN (ANALYZE, BUFFERS) SELECT entry_id, transaction_id, account_id, amount, posted_at FROM ledger_entries WHERE account_id = $MID_WALLET;" 2>&1

banner "1B - WITH single-column index (WARM)"
repeat3 "indexed" "SELECT entry_id, transaction_id, account_id, amount, posted_at FROM ledger_entries WHERE account_id = $MID_WALLET;"
} > "$OUT/exp1-seqscan-vs-index.txt" 2>&1
echo "exp1 done"

# =====================================================================
# EXPERIMENT 2 - Single-column versus composite index
# =====================================================================
{
banner "EXPERIMENT 2 - Single-column versus composite index"
cat <<EOF
Query: the wallet-statement query a mobile app actually issues -
most recent 50 postings for one account, newest first.

    SELECT transaction_id, account_id, amount, posted_at
    FROM ledger_entries
    WHERE account_id = $MID_WALLET
    ORDER BY posted_at DESC
    LIMIT 50;

With a single-column index on (account_id) the engine can find the rows but
must still SORT them. A composite index on (account_id, posted_at DESC)
stores them already ordered, so the sort node should disappear entirely.
EOF

banner "2A - single-column index on (account_id) only"
repeat3 "single-column + sort" "SELECT transaction_id, account_id, amount, posted_at FROM ledger_entries WHERE account_id = $MID_WALLET ORDER BY posted_at DESC LIMIT 50;"

banner "2B - CREATE COMPOSITE INDEX (account_id, posted_at DESC)"
$PSQL -c "CREATE INDEX idx_le_account_posted ON ledger_entries (account_id, posted_at DESC);" 2>&1
$PSQL -c "ANALYZE ledger_entries;" 2>&1
$PSQL -c "SELECT pg_size_pretty(pg_relation_size('idx_le_account_posted')) AS composite_index_size;" 2>&1

banner "2B - with composite index"
repeat3 "composite, no sort" "SELECT transaction_id, account_id, amount, posted_at FROM ledger_entries WHERE account_id = $MID_WALLET ORDER BY posted_at DESC LIMIT 50;"

banner "2C - the composite index also serves a range predicate"
repeat3 "composite range" "SELECT COUNT(*), SUM(amount) FROM ledger_entries WHERE account_id = $MID_WALLET AND posted_at >= TIMESTAMPTZ '2026-08-01' AND posted_at < TIMESTAMPTZ '2026-09-01';"

banner "2D - but NOT a query that filters on the second column alone"
cat <<EOF
A composite index is ordered by its leading column first. A predicate on
posted_at with no account_id cannot use it efficiently - the leading column
is unconstrained, so there is no contiguous range to scan.
EOF
repeat3 "leading column missing" "SELECT COUNT(*) FROM ledger_entries WHERE posted_at >= TIMESTAMPTZ '2026-10-28';"
} > "$OUT/exp2-composite-index.txt" 2>&1
echo "exp2 done"

# =====================================================================
# EXPERIMENT 3 - Selectivity: when the planner abandons the index
# =====================================================================
{
banner "EXPERIMENT 3 - Query selectivity and the planner's crossover point"
cat <<EOF
The same query shape against four accounts of very different volume. Every
index needed is already in place, so any choice of a sequential scan is the
planner deciding the index is not worth using - not the absence of one.

    account $QUIET_WALLET :      6 postings  (0.001 % of the table)
    account $MID_WALLET   :    694 postings  (0.13 %)
    account $BUSY_WALLET  : 56,297 postings  (10.65 %)
    account $BANK_NGN     : 115,724 postings (21.89 %)

An index lookup costs a random I/O per matching row. Once enough of the
table matches, reading it sequentially is cheaper. That crossover is what
this experiment locates.
EOF
for acct in $QUIET_WALLET $MID_WALLET $BUSY_WALLET $BANK_NGN; do
    banner "account_id = $acct"
    $PSQL -c "SELECT COUNT(*) AS matching_rows, ROUND(100.0*COUNT(*)/(SELECT COUNT(*) FROM ledger_entries),3) AS pct_of_table FROM ledger_entries WHERE account_id = $acct;" 2>&1
    repeat3 "account $acct" "SELECT entry_id, transaction_id, amount, posted_at FROM ledger_entries WHERE account_id = $acct;"
done

banner "3B - forcing the index on the high-volume account, to show WHY the planner refused"
$PSQL -c "SET enable_seqscan = off;" -c "EXPLAIN (ANALYZE, BUFFERS) SELECT entry_id, transaction_id, amount, posted_at FROM ledger_entries WHERE account_id = $BANK_NGN;" 2>&1
} > "$OUT/exp3-selectivity.txt" 2>&1
echo "exp3 done"

# =====================================================================
# EXPERIMENT 4 - Sorting and pagination depth
# =====================================================================
{
banner "EXPERIMENT 4 - Index-assisted ordering and the cost of deep pagination"
cat <<EOF
LIMIT/OFFSET pagination over the busiest wallet (account $BUSY_WALLET,
56,297 postings). The composite index supplies the ordering, but OFFSET
still requires the engine to walk and discard every skipped row.
EOF
for off in 0 500 5000 50000; do
    banner "OFFSET $off"
    repeat3 "offset $off" "SELECT transaction_id, amount, posted_at FROM ledger_entries WHERE account_id = $BUSY_WALLET ORDER BY posted_at DESC LIMIT 50 OFFSET $off;"
done

banner "4B - keyset pagination instead of OFFSET"
cat <<EOF
Keyset ('seek') pagination replaces OFFSET with a predicate on the last row
seen. The index can jump straight to the position, so cost stays flat no
matter how deep the page.
EOF
CURSOR=$($PSQL -tAc "SELECT posted_at FROM ledger_entries WHERE account_id = $BUSY_WALLET ORDER BY posted_at DESC OFFSET 50000 LIMIT 1;")
echo "cursor value from row 50,000: $CURSOR"
repeat3 "keyset at depth 50000" "SELECT transaction_id, amount, posted_at FROM ledger_entries WHERE account_id = $BUSY_WALLET AND posted_at < TIMESTAMPTZ '$CURSOR' ORDER BY posted_at DESC LIMIT 50;"
} > "$OUT/exp4-pagination.txt" 2>&1
echo "exp4 done"

# =====================================================================
# EXPERIMENT 5 - Derived balance versus materialised view
# =====================================================================
{
banner "EXPERIMENT 5 - Derived balance versus materialised view"
cat <<EOF
Portfolio 1 deliberately stores no balance anywhere: account_balances is a
view that aggregates the ledger. normalisation.md promised that the cost of
that decision would be measured rather than assumed. This is that
measurement.

Three things are compared:
  A  one account's balance, derived from the ledger
  B  every account's balance, derived from the ledger
  C  the same, served from a materialised view
and then the refresh cost and storage overhead of the materialised view.
EOF

banner "5A - single account balance, derived"
repeat3 "derived, one account" "SELECT account_id, balance FROM account_balances WHERE account_id = $MID_WALLET;"

banner "5A' - single account balance, busiest wallet"
repeat3 "derived, busiest" "SELECT account_id, balance FROM account_balances WHERE account_id = $BUSY_WALLET;"

banner "5B - ALL account balances, derived from the ledger"
repeat3 "derived, all accounts" "SELECT account_id, balance FROM account_balances;"

banner "5C - CREATE MATERIALIZED VIEW"
$PSQL -c "\timing on" -c "CREATE MATERIALIZED VIEW mv_account_balances AS SELECT a.account_id, a.account_reference, a.account_type, a.customer_id, a.currency_code, COALESCE(SUM(CASE WHEN le.direction = a.normal_balance THEN le.amount ELSE -le.amount END),0)::NUMERIC(20,4) AS balance, COUNT(le.entry_id) AS entry_count, MAX(le.posted_at) AS last_posted_at, now() AS refreshed_at FROM accounts a LEFT JOIN ledger_entries le ON le.account_id = a.account_id GROUP BY a.account_id, a.account_reference, a.account_type, a.customer_id, a.currency_code, a.normal_balance;" 2>&1
$PSQL -c "CREATE UNIQUE INDEX idx_mv_balances_account ON mv_account_balances (account_id);" 2>&1
$PSQL -c "ANALYZE mv_account_balances;" 2>&1

banner "5C - single account balance, from the materialised view"
repeat3 "matview, one account" "SELECT account_id, balance FROM mv_account_balances WHERE account_id = $MID_WALLET;"

banner "5C - ALL balances, from the materialised view"
repeat3 "matview, all accounts" "SELECT account_id, balance FROM mv_account_balances;"

banner "5D - refresh cost and storage"
$PSQL -c "\timing on" -c "REFRESH MATERIALIZED VIEW CONCURRENTLY mv_account_balances;" 2>&1
$PSQL -c "\timing on" -c "REFRESH MATERIALIZED VIEW CONCURRENTLY mv_account_balances;" 2>&1
$PSQL -c "SELECT pg_size_pretty(pg_total_relation_size('mv_account_balances')) AS matview_total_size, pg_size_pretty(pg_total_relation_size('ledger_entries')) AS ledger_total_size;" 2>&1

banner "5E - FRESHNESS: the materialised view is stale the moment the ledger moves"
$PSQL 2>&1 <<SQL
BEGIN;
INSERT INTO transactions (transaction_reference, transaction_type, status,
                          currency_code, narration, initiated_at, settled_at)
VALUES ('KP-2026-700001','DEPOSIT','COMPLETED','NGN','Freshness probe', now(), now());
INSERT INTO ledger_entries (transaction_id, account_id, currency_code, direction, amount)
SELECT t.transaction_id, 1, 'NGN', 'DEBIT', 5000.00 FROM transactions t
WHERE t.transaction_reference='KP-2026-700001';
INSERT INTO ledger_entries (transaction_id, account_id, currency_code, direction, amount)
SELECT t.transaction_id, $MID_WALLET, 'NGN', 'CREDIT', 5000.00 FROM transactions t
WHERE t.transaction_reference='KP-2026-700001';
COMMIT;
SELECT 'derived (view)'      AS source, balance FROM account_balances    WHERE account_id = $MID_WALLET
UNION ALL
SELECT 'materialised view', balance FROM mv_account_balances WHERE account_id = $MID_WALLET;
SQL
echo ""
echo "The derived view reflects the new posting immediately. The materialised"
echo "view still reports the pre-posting balance until it is refreshed - which"
echo "is the entire trade-off, stated numerically."
} > "$OUT/exp5-balance-vs-matview.txt" 2>&1
echo "exp5 done"

# =====================================================================
# EXPERIMENT 6 - What indexes cost on write
# =====================================================================
{
banner "EXPERIMENT 6 - Index write overhead and storage cost"
cat <<EOF
Indexes are not free. Every INSERT must also maintain every index on the
table, and each index occupies storage.

Measured on a copy of the ledger structure WITHOUT the Portfolio 1 integrity
triggers, so the figures isolate index maintenance rather than trigger cost.
100,000 rows are inserted into an unindexed table, then the same 100,000
into an identically shaped table carrying three indexes.
EOF

$PSQL -q -c "CREATE TABLE ledger_entries_bench (entry_id BIGINT, transaction_id BIGINT, account_id BIGINT, currency_code CHAR(3), direction entry_direction_t, amount NUMERIC(20,4), posted_at TIMESTAMPTZ);"

banner "6A - inserting 100,000 rows into an UNINDEXED table"
$PSQL -c "\timing on" -c "INSERT INTO ledger_entries_bench SELECT entry_id, transaction_id, account_id, currency_code, direction, amount, posted_at FROM ledger_entries LIMIT 100000;" 2>&1
$PSQL -c "SELECT pg_size_pretty(pg_table_size('ledger_entries_bench')) AS heap, pg_size_pretty(pg_indexes_size('ledger_entries_bench')) AS indexes;" 2>&1

banner "6B - same 100,000 rows into a table carrying THREE indexes"
$PSQL -q -c "TRUNCATE ledger_entries_bench;"
$PSQL -q -c "CREATE INDEX idx_bench_account ON ledger_entries_bench (account_id);"
$PSQL -q -c "CREATE INDEX idx_bench_account_posted ON ledger_entries_bench (account_id, posted_at DESC);"
$PSQL -q -c "CREATE INDEX idx_bench_tx ON ledger_entries_bench (transaction_id);"
$PSQL -c "\timing on" -c "INSERT INTO ledger_entries_bench SELECT entry_id, transaction_id, account_id, currency_code, direction, amount, posted_at FROM ledger_entries LIMIT 100000;" 2>&1
$PSQL -c "SELECT pg_size_pretty(pg_table_size('ledger_entries_bench')) AS heap, pg_size_pretty(pg_indexes_size('ledger_entries_bench')) AS indexes;" 2>&1

banner "6C - storage cost of the real ledger's indexes"
$PSQL -c "SELECT indexrelname AS index_name, pg_size_pretty(pg_relation_size(indexrelid)) AS size, idx_scan AS times_used FROM pg_stat_user_indexes WHERE relname = 'ledger_entries' ORDER BY pg_relation_size(indexrelid) DESC;" 2>&1
$PSQL -c "SELECT pg_size_pretty(pg_table_size('ledger_entries')) AS heap, pg_size_pretty(pg_indexes_size('ledger_entries')) AS all_indexes, ROUND(100.0*pg_indexes_size('ledger_entries')/pg_table_size('ledger_entries'),1) AS index_pct_of_heap;" 2>&1
} > "$OUT/exp6-write-overhead.txt" 2>&1
echo "exp6 done"

# =====================================================================
# EXPERIMENT 7 - A deliberately unhelpful index
# =====================================================================
{
banner "EXPERIMENT 7 - An index that does not help"
cat <<EOF
Not every index earns its place. direction has exactly two distinct values
across 528,000+ rows, so any predicate on it matches roughly half the table.
An index offers no way to avoid reading most of the heap, and the planner
should ignore it.

This experiment is included deliberately: showing an index that FAILS to
help demonstrates understanding of why indexes work, which a collection of
successful examples does not.
EOF

banner "7A - cardinality of the candidate column"
$PSQL -c "SELECT direction, COUNT(*), ROUND(100.0*COUNT(*)/SUM(COUNT(*)) OVER (),1) AS pct FROM ledger_entries GROUP BY direction;" 2>&1
$PSQL -c "SELECT attname, n_distinct, correlation FROM pg_stats WHERE tablename='ledger_entries' AND attname IN ('direction','account_id','posted_at','currency_code') ORDER BY attname;" 2>&1

banner "7B - before the index"
repeat3 "no direction index" "SELECT COUNT(*), SUM(amount) FROM ledger_entries WHERE direction = 'DEBIT';"

banner "7C - CREATE INDEX on direction"
$PSQL -c "\timing on" -c "CREATE INDEX idx_le_direction ON ledger_entries (direction);" 2>&1
$PSQL -c "ANALYZE ledger_entries;" 2>&1
$PSQL -c "SELECT pg_size_pretty(pg_relation_size('idx_le_direction')) AS wasted_index_size;" 2>&1

banner "7D - after the index (expect the planner to ignore it)"
repeat3 "with direction index" "SELECT COUNT(*), SUM(amount) FROM ledger_entries WHERE direction = 'DEBIT';"

banner "7E - confirming the index was never used"
$PSQL -c "SELECT indexrelname, idx_scan AS times_used, pg_size_pretty(pg_relation_size(indexrelid)) AS size FROM pg_stat_user_indexes WHERE relname='ledger_entries' ORDER BY idx_scan;" 2>&1

banner "7F - the same column IS useful when combined with a selective one"
cat <<EOF
direction is not useless in principle - it is useless ALONE. As the trailing
column of a selective composite index it becomes worthwhile.
EOF
$PSQL -q -c "CREATE INDEX idx_le_account_direction ON ledger_entries (account_id, direction);"
$PSQL -q -c "ANALYZE ledger_entries;"
repeat3 "account+direction composite" "SELECT COUNT(*), SUM(amount) FROM ledger_entries WHERE account_id = $MID_WALLET AND direction = 'DEBIT';"
$PSQL -q -c "DROP INDEX idx_le_account_direction;"
} > "$OUT/exp7-unhelpful-index.txt" 2>&1
echo "exp7 done"

echo ""
echo "All experiments complete. Plans written to $OUT/"
ls -la "$OUT/"
