-- =====================================================================
-- KineticsPay - recommended index set
-- Portfolio 2: Query Processing and Optimisation
--
-- MIT 8103 Advanced Database Systems
-- Biliaminu Abdulfarid (301918844)
--
-- These are the indexes the BENCHMARK justifies, not every index that
-- could plausibly be created. Each one is listed with the measurement
-- that earned it and the write cost it imposes.
--
-- Experiment 6 measured the cost side: three indexes made inserts 5.9x
-- slower, and on the real ledger the indexes already occupy 123.7% of
-- the heap. A payment ledger is append-only by design and therefore
-- insert-heavy, so an index that is not demonstrably used is a
-- permanent tax on every transaction.
--
-- Run with:  psql -d kineticspay -f indexes.sql
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. ledger_entries (account_id, posted_at DESC)   -- KEEP
--
-- Earns its place on two counts:
--   * Wallet statement (Q1, Experiment 2): 1.44 ms -> 0.28 ms, and the
--     Sort node disappears because the index already stores the rows in
--     the required order.
--   * Date-range queries on one account (Experiment 2C): 0.42 ms.
--
-- Size: 16 MB. Used 35 times during the benchmark run.
--
-- DESC matters. A statement screen always reads newest-first, and
-- matching the index's declared order lets the engine walk forward and
-- stop at LIMIT rather than scanning and reversing.
-- ---------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_le_account_posted
    ON ledger_entries (account_id, posted_at DESC);

-- ---------------------------------------------------------------------
-- 2. ledger_entries (transaction_id)   -- KEEP
--
-- Every balance assertion, every reversal mirror check and every
-- reconciliation query gathers all postings for one transaction. The
-- Portfolio 1 integrity triggers run exactly this lookup on every write,
-- so without it each insert would scan the whole ledger.
--
-- Partially covered by the existing UNIQUE constraint
-- ledger_entries_tx_account_direction_uq, whose leading column is
-- transaction_id - so this is NOT created separately. Noted here because
-- the UNIQUE constraint is doing index duty, and anyone dropping it
-- would silently remove this access path too.
-- ---------------------------------------------------------------------
-- (intentionally not created: ledger_entries_tx_account_direction_uq
--  already provides a leading-prefix index on transaction_id)

-- ---------------------------------------------------------------------
-- 3. transactions (initiated_at DESC)   -- KEEP
--
-- Q2 and Q5 aggregate by month across the whole transactions table, and
-- operational dashboards filter on recent activity. Without it those
-- queries read all 250,010 rows.
-- ---------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_tx_initiated_at
    ON transactions (initiated_at DESC);

-- ---------------------------------------------------------------------
-- 4. transactions (status) WHERE status IN ('PENDING','FAILED')  -- KEEP
--
-- A PARTIAL index. 93% of transactions are COMPLETED, so an index on
-- status as a whole would be useless for the common value - exactly the
-- Experiment 7 failure mode.
--
-- But operations only ever query the RARE values: which transfers are
-- stuck pending, which failed overnight. Restricting the index to those
-- rows makes it both selective and small - roughly 7% of the table
-- rather than 100%.
--
-- This is the direct lesson of Experiment 7 applied: low cardinality is
-- fatal for a full index and irrelevant for a partial one, because the
-- partial index never contains the common value at all.
-- ---------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_tx_unsettled
    ON transactions (status, initiated_at DESC)
    WHERE status IN ('PENDING', 'FAILED');

-- ---------------------------------------------------------------------
-- 5. accounts (customer_id)   -- KEEP
--
-- Q3, Q6 and Q7 all join customers to their wallets. Small table, small
-- index, used by every customer-facing query.
-- ---------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_accounts_customer
    ON accounts (customer_id);

-- ---------------------------------------------------------------------
-- REJECTED - indexes the measurements do NOT justify
-- ---------------------------------------------------------------------

-- ledger_entries (account_id)   -- REDUNDANT
--
-- Measured at 3,736 kB and genuinely faster than no index (Experiment 1:
-- 25.5 ms -> 1.55 ms). But idx_le_account_posted has account_id as its
-- LEADING column, and a B-tree serves any leading prefix of its columns.
-- Keeping both pays twice on every insert for one access path.
--
-- Retained in the benchmark run only so Experiments 1 and 2 could
-- compare single-column against composite. It should be dropped in
-- production:
--
--     DROP INDEX idx_le_account;

-- ledger_entries (direction)   -- HARMFUL
--
-- Experiment 7: n_distinct = 2 across 528,647 rows. The planner ignored
-- it entirely (idx_scan = 0) while it consumed 3,600 kB and added
-- maintenance to every insert. A predicate matching 44% of a table
-- cannot be served by an index - that is past the 21.9%-35.3% crossover
-- found in Experiment 3.

-- ledger_entries (currency_code)   -- HARMFUL
--
-- n_distinct = 2, and 94% of postings are NGN. Same failure mode.

-- ledger_entries (posted_at) alone   -- NOT JUSTIFIED HERE
--
-- Experiment 2D showed a bare posted_at predicate falling back to a
-- Parallel Seq Scan at 33.5 ms, which this index would improve. It is
-- omitted because no query in this workload filters on time WITHOUT also
-- filtering on an account. If a platform-wide time-series dashboard were
-- added it would become justified - the point being that the decision
-- follows the workload, not the column.

-- ---------------------------------------------------------------------
-- Refresh planner statistics after changing the index set.
-- ---------------------------------------------------------------------
ANALYZE ledger_entries;
ANALYZE transactions;
ANALYZE accounts;

-- ---------------------------------------------------------------------
-- Verification: what exists, how big, and whether it is being used.
--
-- idx_scan = 0 after a representative workload means the index is pure
-- cost. Re-check this periodically rather than treating the index set as
-- settled.
-- ---------------------------------------------------------------------
SELECT relname           AS table_name,
       indexrelname      AS index_name,
       pg_size_pretty(pg_relation_size(indexrelid)) AS size,
       idx_scan          AS times_used
FROM pg_stat_user_indexes
WHERE relname IN ('ledger_entries', 'transactions', 'accounts')
ORDER BY relname, pg_relation_size(indexrelid) DESC;
