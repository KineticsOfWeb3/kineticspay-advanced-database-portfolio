-- =====================================================================
-- KineticsPay - Design verification script
-- Portfolio 1: Database Design and Modelling
--
-- Demonstrates that the integrity rules described in normalisation.md
-- are enforced by the DATABASE and not by application code. Each
-- negative test is wrapped in its own savepoint so that the expected
-- failure does not abort the remainder of the script.
--
-- Run with:
--   psql -U postgres -d kineticspay -f verify.sql
-- =====================================================================

\echo '=============================================================='
\echo 'TEST 1  Derived wallet balances (no balance column is stored)'
\echo '=============================================================='
SELECT wallet_reference, customer_name, currency_code,
       TO_CHAR(balance, 'FM999,999,990.00') AS balance, entry_count
FROM wallets
ORDER BY wallet_reference;

\echo ''
\echo '=============================================================='
\echo 'TEST 2  Trial balance - total debits must equal total credits'
\echo '=============================================================='
SELECT currency_code,
       SUM(amount) FILTER (WHERE direction = 'DEBIT')  AS total_debits,
       SUM(amount) FILTER (WHERE direction = 'CREDIT') AS total_credits,
       SUM(CASE WHEN direction = 'DEBIT' THEN amount ELSE -amount END) AS imbalance,
       CASE WHEN SUM(CASE WHEN direction = 'DEBIT' THEN amount ELSE -amount END) = 0
            THEN 'PASS' ELSE 'FAIL' END AS result
FROM ledger_entries
GROUP BY currency_code
ORDER BY currency_code;

\echo ''
\echo '=============================================================='
\echo 'TEST 3  Every individual transaction balances'
\echo '=============================================================='
SELECT t.transaction_reference, t.transaction_type, t.status,
       COUNT(le.entry_id) AS entries,
       COALESCE(SUM(CASE WHEN le.direction = 'DEBIT'
                         THEN le.amount ELSE -le.amount END), 0) AS imbalance
FROM transactions t
LEFT JOIN ledger_entries le ON le.transaction_id = t.transaction_id
GROUP BY t.transaction_id, t.transaction_reference, t.transaction_type, t.status
ORDER BY t.transaction_reference;

\echo ''
\echo '=============================================================='
\echo 'TEST 4  NEGATIVE - an unbalanced transaction must be rejected'
\echo '        (debit 5,000 against a credit of 4,000)'
\echo '=============================================================='
BEGIN;
INSERT INTO transactions (transaction_reference, transaction_type, status,
                          currency_code, narration, settled_at)
VALUES ('KP-2026-999001', 'TRANSFER', 'COMPLETED', 'NGN', 'Unbalanced test', now());
SELECT fn_post_entry('KP-2026-999001', 'WAL-CUS-000001-NGN', 'DEBIT',  5000.00);
SELECT fn_post_entry('KP-2026-999001', 'WAL-CUS-000002-NGN', 'CREDIT', 4000.00);
-- The balanced-transaction trigger is DEFERRABLE INITIALLY DEFERRED, so it
-- normally fires at COMMIT. Forcing it to IMMEDIATE here makes the rejection
-- visible inside the script instead of only on a failed COMMIT.
SET CONSTRAINTS ALL IMMEDIATE;
ROLLBACK;

\echo ''
\echo '=============================================================='
\echo 'TEST 5  NEGATIVE - a single-sided posting must be rejected'
\echo '=============================================================='
BEGIN;
INSERT INTO transactions (transaction_reference, transaction_type, status,
                          currency_code, narration, settled_at)
VALUES ('KP-2026-999002', 'DEPOSIT', 'COMPLETED', 'NGN', 'One-sided test', now());
SELECT fn_post_entry('KP-2026-999002', 'WAL-CUS-000001-NGN', 'CREDIT', 5000.00);
SET CONSTRAINTS ALL IMMEDIATE;
ROLLBACK;

\echo ''
\echo '=============================================================='
\echo 'TEST 6  NEGATIVE - currency mismatch must be rejected'
\echo '        (posting an NGN amount to a USD wallet)'
\echo '=============================================================='
BEGIN;
INSERT INTO transactions (transaction_reference, transaction_type, status,
                          currency_code, narration, settled_at)
VALUES ('KP-2026-999003', 'DEPOSIT', 'COMPLETED', 'NGN', 'Currency mismatch test', now());
INSERT INTO ledger_entries (transaction_id, account_id, currency_code, direction, amount)
SELECT t.transaction_id, a.account_id, 'NGN', 'CREDIT', 5000.00
FROM transactions t, accounts a
WHERE t.transaction_reference = 'KP-2026-999003'
  AND a.account_reference     = 'WAL-CUS-000004-USD';
ROLLBACK;

\echo ''
\echo '=============================================================='
\echo 'TEST 7  NEGATIVE - the ledger is append-only (UPDATE rejected)'
\echo '=============================================================='
BEGIN;
UPDATE ledger_entries SET amount = 999999.00 WHERE entry_id = 1;
ROLLBACK;

\echo ''
\echo '=============================================================='
\echo 'TEST 8  NEGATIVE - the ledger is append-only (DELETE rejected)'
\echo '=============================================================='
BEGIN;
DELETE FROM ledger_entries WHERE entry_id = 1;
ROLLBACK;

\echo ''
\echo '=============================================================='
\echo 'TEST 9  NEGATIVE - an internal account may not have an owner'
\echo '=============================================================='
BEGIN;
INSERT INTO accounts (account_reference, account_type, customer_id,
                      currency_code, normal_balance)
SELECT 'ACC-BAD-001', 'FEE_REVENUE', c.customer_id, 'NGN', 'CREDIT'
FROM customers c WHERE c.customer_reference = 'CUS-000001';
ROLLBACK;

\echo ''
\echo '=============================================================='
\echo 'TEST 10 NEGATIVE - a customer may not hold two NGN wallets'
\echo '=============================================================='
BEGIN;
INSERT INTO accounts (account_reference, account_type, customer_id,
                      currency_code, normal_balance)
SELECT 'WAL-CUS-000001-NGN-2', 'CUSTOMER_WALLET', c.customer_id, 'NGN', 'CREDIT'
FROM customers c WHERE c.customer_reference = 'CUS-000001';
ROLLBACK;

\echo ''
\echo '=============================================================='
\echo 'TEST 11 NEGATIVE - a negative posting amount must be rejected'
\echo '=============================================================='
BEGIN;
INSERT INTO transactions (transaction_reference, transaction_type, status,
                          currency_code, narration, settled_at)
VALUES ('KP-2026-999004', 'DEPOSIT', 'COMPLETED', 'NGN', 'Negative amount test', now());
SELECT fn_post_entry('KP-2026-999004', 'WAL-CUS-000001-NGN', 'CREDIT', -5000.00);
ROLLBACK;

\echo ''
\echo '=============================================================='
\echo 'TEST 12 Reversal integrity - original and correction both survive'
\echo '=============================================================='
SELECT orig.transaction_reference AS original,
       orig.status                AS original_status,
       rev.transaction_reference  AS reversal,
       SUM(CASE WHEN le.direction = 'CREDIT' THEN le.amount ELSE -le.amount END)
           AS net_effect_on_ledger
FROM transactions rev
JOIN transactions orig ON orig.transaction_id = rev.reverses_transaction
JOIN ledger_entries le ON le.transaction_id IN (orig.transaction_id, rev.transaction_id)
GROUP BY orig.transaction_reference, orig.status, rev.transaction_reference;
