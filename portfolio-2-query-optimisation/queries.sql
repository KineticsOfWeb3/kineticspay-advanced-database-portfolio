-- =====================================================================
-- KineticsPay - analytical queries
-- Portfolio 2: Query Processing and Optimisation
--
-- MIT 8103 Advanced Database Systems
-- Biliaminu Abdulfarid (301918844)
--
-- Eight queries a payment platform actually needs, exercising joins,
-- aggregates, common table expressions, window functions, lateral joins
-- and conditional aggregation.
--
-- Run with:  psql -d kineticspay -f queries.sql
-- =====================================================================

\timing on

-- ---------------------------------------------------------------------
-- Q1  Wallet statement
--     The single most frequently executed query on the platform: the
--     most recent postings for one account, newest first, with the
--     running balance after each one.
--
--     Uses a window function over the ordered postings. The composite
--     index (account_id, posted_at DESC) supplies both the filter and
--     the ordering, so no Sort node is needed.
--
--     NOTE on paging this query: posted_at is NOT unique within an
--     account - both sides of a transfer share settled_at. A keyset
--     cursor must therefore be a row-value comparison including a
--     unique tie-breaker:
--
--         WHERE account_id = :a
--           AND (posted_at, entry_id) < (:last_posted_at, :last_entry_id)
--         ORDER BY posted_at DESC, entry_id DESC
--         LIMIT 50
--
--     A cursor on posted_at alone silently skips tied rows. See
--     performance-analysis.md section 5.
-- ---------------------------------------------------------------------
\echo ''
\echo 'Q1  Wallet statement with running balance'
WITH statement AS (
    SELECT le.posted_at,
           t.transaction_reference,
           t.transaction_type,
           le.direction,
           le.amount,
           SUM(CASE WHEN le.direction = 'CREDIT' THEN le.amount ELSE -le.amount END)
               OVER (ORDER BY le.posted_at, le.entry_id
                     ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
               AS running_balance
    FROM ledger_entries le
    JOIN transactions t USING (transaction_id)
    WHERE le.account_id = 3547
)
SELECT posted_at, transaction_reference, transaction_type,
       direction, amount, running_balance
FROM statement
ORDER BY posted_at DESC
LIMIT 15;

-- ---------------------------------------------------------------------
-- Q2  Monthly transaction volume by type
--     Conditional aggregation to pivot statuses into columns, so the
--     result is one row per month rather than one per month-and-status.
-- ---------------------------------------------------------------------
\echo ''
\echo 'Q2  Monthly volume and value by transaction type'
SELECT DATE_TRUNC('month', t.initiated_at)::DATE          AS month,
       t.transaction_type,
       COUNT(*)                                            AS attempted,
       COUNT(*) FILTER (WHERE t.status = 'COMPLETED')      AS completed,
       COUNT(*) FILTER (WHERE t.status = 'FAILED')         AS failed,
       ROUND(100.0 * COUNT(*) FILTER (WHERE t.status = 'FAILED')
             / NULLIF(COUNT(*), 0), 2)                     AS failure_rate_pct
FROM transactions t
WHERE t.currency_code = 'NGN'
GROUP BY 1, 2
ORDER BY 1 DESC, 2
LIMIT 12;

-- ---------------------------------------------------------------------
-- Q3  Top customers by settled outbound value
--     Join across three relations with a HAVING clause, ranked by a
--     window function so ties are handled explicitly.
-- ---------------------------------------------------------------------
\echo ''
\echo 'Q3  Top 10 customers by settled outbound value'
SELECT RANK() OVER (ORDER BY SUM(le.amount) DESC) AS rank,
       c.customer_reference,
       c.first_name || ' ' || c.last_name AS customer,
       c.kyc_tier,
       COUNT(DISTINCT le.transaction_id)  AS outbound_transactions,
       ROUND(SUM(le.amount), 2)           AS total_debited
FROM ledger_entries le
JOIN accounts  a ON a.account_id  = le.account_id
JOIN customers c ON c.customer_id = a.customer_id
WHERE a.account_type = 'CUSTOMER_WALLET'
  AND le.direction   = 'DEBIT'
  AND le.currency_code = 'NGN'
GROUP BY c.customer_id, c.customer_reference, c.first_name, c.last_name, c.kyc_tier
HAVING COUNT(DISTINCT le.transaction_id) > 5
ORDER BY total_debited DESC
LIMIT 10;

-- ---------------------------------------------------------------------
-- Q4  Fee revenue recognised per month
--     Walks the fee-revenue control account rather than inferring fees
--     from transaction rows - the ledger is the authority.
-- ---------------------------------------------------------------------
\echo ''
\echo 'Q4  Fee revenue by month'
SELECT DATE_TRUNC('month', le.posted_at)::DATE AS month,
       COUNT(*)                                 AS fee_postings,
       ROUND(SUM(le.amount), 2)                 AS fee_revenue,
       ROUND(AVG(le.amount), 2)                 AS avg_fee,
       ROUND(MAX(le.amount), 2)                 AS largest_fee
FROM ledger_entries le
JOIN accounts a USING (account_id)
WHERE a.account_type = 'FEE_REVENUE'
  AND le.direction   = 'CREDIT'
GROUP BY 1
ORDER BY 1 DESC;

-- ---------------------------------------------------------------------
-- Q5  Channel performance
--     Failure rate and average value per channel, with the platform
--     average alongside each row for comparison - a window aggregate
--     with an empty OVER() clause.
-- ---------------------------------------------------------------------
\echo ''
\echo 'Q5  Channel performance against the platform average'
SELECT t.channel,
       COUNT(*)                                           AS transactions,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1) AS share_pct,
       ROUND(100.0 * COUNT(*) FILTER (WHERE t.status = 'FAILED')
             / COUNT(*), 2)                               AS failure_rate_pct,
       ROUND(100.0 * SUM(COUNT(*) FILTER (WHERE t.status = 'FAILED')) OVER ()
             / SUM(COUNT(*)) OVER (), 2)                  AS platform_failure_rate_pct
FROM transactions t
GROUP BY t.channel
ORDER BY transactions DESC;

-- ---------------------------------------------------------------------
-- Q6  Dormant wallets holding value
--     An operational and compliance question: which funded wallets have
--     seen no activity recently. LEFT JOIN against the balance view,
--     filtering on the aggregate.
-- ---------------------------------------------------------------------
\echo ''
\echo 'Q6  Funded wallets with no activity in 90 days'
SELECT w.wallet_reference,
       w.customer_name,
       w.currency_code,
       w.balance,
       w.last_posted_at::DATE AS last_activity,
       (CURRENT_DATE - w.last_posted_at::DATE) AS days_dormant
FROM wallets w
WHERE w.balance > 1000
  AND w.last_posted_at < now() - INTERVAL '90 days'
ORDER BY w.balance DESC
LIMIT 10;

-- ---------------------------------------------------------------------
-- Q7  Each customer's largest single transaction
--     LATERAL join: for every customer, run a correlated subquery that
--     the planner can push the index into. Usually far cheaper than
--     ranking every posting and filtering to rank 1.
-- ---------------------------------------------------------------------
\echo ''
\echo 'Q7  Largest single debit per customer (lateral join)'
SELECT c.customer_reference,
       c.first_name || ' ' || c.last_name AS customer,
       biggest.amount,
       biggest.posted_at::DATE AS occurred
FROM customers c
JOIN accounts a ON a.customer_id = c.customer_id
               AND a.account_type = 'CUSTOMER_WALLET'
               AND a.currency_code = 'NGN'
CROSS JOIN LATERAL (
    SELECT le.amount, le.posted_at
    FROM ledger_entries le
    WHERE le.account_id = a.account_id
      AND le.direction  = 'DEBIT'
    ORDER BY le.amount DESC
    LIMIT 1
) AS biggest
ORDER BY biggest.amount DESC
LIMIT 10;

-- ---------------------------------------------------------------------
-- Q8  Daily reconciliation
--     Proves, per day, that the ledger balanced. This is the query a
--     finance team would run every morning; a non-zero imbalance means
--     the double-entry invariant was violated somewhere.
-- ---------------------------------------------------------------------
\echo ''
\echo 'Q8  Daily reconciliation - debits must equal credits every day'
SELECT le.posted_at::DATE AS day,
       le.currency_code,
       COUNT(*)                                                     AS postings,
       ROUND(SUM(le.amount) FILTER (WHERE le.direction='DEBIT'), 2)  AS debits,
       ROUND(SUM(le.amount) FILTER (WHERE le.direction='CREDIT'), 2) AS credits,
       CASE WHEN SUM(CASE WHEN le.direction='DEBIT'
                          THEN le.amount ELSE -le.amount END) = 0
            THEN 'BALANCED' ELSE 'IMBALANCE' END                     AS result
FROM ledger_entries le
WHERE le.posted_at >= now() - INTERVAL '7 days'
GROUP BY 1, 2
ORDER BY 1 DESC, 2;

\timing off
