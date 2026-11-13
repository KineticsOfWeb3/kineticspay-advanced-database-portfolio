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

\echo ''
\echo '=============================================================='
\echo 'TEST 13 NEGATIVE - a COMPLETED transaction with NO postings'
\echo '        (the gap found in design review: a settled payment'
\echo '         that moved no money used to commit successfully)'
\echo '=============================================================='
BEGIN;
INSERT INTO transactions (transaction_reference, transaction_type, status,
                          currency_code, narration, settled_at)
VALUES ('KP-2026-999005', 'TRANSFER', 'COMPLETED', 'NGN', 'Empty but completed', now());
SET CONSTRAINTS ALL IMMEDIATE;
ROLLBACK;

\echo ''
\echo '=============================================================='
\echo 'TEST 14 NEGATIVE - a FAILED transaction must not post value'
\echo '=============================================================='
BEGIN;
INSERT INTO transactions (transaction_reference, transaction_type, status,
                          currency_code, narration, settled_at)
VALUES ('KP-2026-999006', 'TRANSFER', 'FAILED', 'NGN', 'Failed yet posted', now());
SELECT fn_post_entry('KP-2026-999006', 'WAL-CUS-000001-NGN', 'DEBIT',  1000.00);
SELECT fn_post_entry('KP-2026-999006', 'WAL-CUS-000002-NGN', 'CREDIT', 1000.00);
SET CONSTRAINTS ALL IMMEDIATE;
ROLLBACK;

\echo ''
\echo '=============================================================='
\echo 'TEST 15 NEGATIVE - replica mode must not bypass append-only'
\echo '        (session_replication_role previously suppressed the'
\echo '         trigger and allowed a committed posting to be edited)'
\echo '=============================================================='
BEGIN;
SET LOCAL session_replication_role = 'replica';
UPDATE ledger_entries SET amount = 999999.00 WHERE entry_id = 1;
ROLLBACK;

\echo ''
\echo '=============================================================='
\echo 'TEST 16 NEGATIVE - sub-kobo precision must be rejected'
\echo '        (NGN declares minor_unit = 2)'
\echo '=============================================================='
BEGIN;
INSERT INTO transactions (transaction_reference, transaction_type, status,
                          currency_code, narration, settled_at)
VALUES ('KP-2026-999007', 'DEPOSIT', 'COMPLETED', 'NGN', 'Sub-kobo amount', now());
SELECT fn_post_entry('KP-2026-999007', 'ACC-BANK-NGN', 'DEBIT', 100.00019);
ROLLBACK;

\echo ''
\echo '=============================================================='
\echo 'TEST 17 NEGATIVE - a reversal must mirror its original'
\echo '        (debits unrelated accounts for an unrelated amount)'
\echo '=============================================================='
BEGIN;
UPDATE transactions SET status = 'REVERSED'
WHERE transaction_reference = 'KP-2026-000001';
INSERT INTO transactions (transaction_reference, transaction_type, status, currency_code,
                          reverses_transaction, narration, settled_at)
SELECT 'KP-2026-999008', 'REVERSAL', 'COMPLETED', 'NGN', t.transaction_id,
       'Bogus reversal', now()
FROM transactions t WHERE t.transaction_reference = 'KP-2026-000001';
SELECT fn_post_entry('KP-2026-999008', 'WAL-CUS-000002-NGN', 'DEBIT',  7.00);
SELECT fn_post_entry('KP-2026-999008', 'ACC-FEES-NGN',       'CREDIT', 7.00);
SET CONSTRAINTS ALL IMMEDIATE;
ROLLBACK;

\echo ''
\echo '=============================================================='
\echo 'TEST 18 POSITIVE - a correctly mirrored reversal is accepted'
\echo '=============================================================='
BEGIN;
UPDATE transactions SET status = 'REVERSED'
WHERE transaction_reference = 'KP-2026-000005';
INSERT INTO transactions (transaction_reference, transaction_type, status, currency_code,
                          reverses_transaction, narration, settled_at)
SELECT 'KP-2026-999009', 'REVERSAL', 'COMPLETED', 'NGN', t.transaction_id,
       'Correct mirror of KP-2026-000005', now()
FROM transactions t WHERE t.transaction_reference = 'KP-2026-000005';
-- original was: DEBIT wallet 20,000 / CREDIT bank 20,000  -> mirror swaps both
SELECT fn_post_entry('KP-2026-999009', 'WAL-CUS-000002-NGN', 'CREDIT', 20000.00);
SELECT fn_post_entry('KP-2026-999009', 'ACC-BANK-NGN',       'DEBIT',  20000.00);
SET CONSTRAINTS ALL IMMEDIATE;
\echo '>>> accepted (no error above)'
ROLLBACK;

\echo ''
\echo '=============================================================='
\echo 'TEST 19 Privilege check - kineticspay_app cannot UPDATE/DELETE'
\echo '        the ledger even if every trigger were dropped'
\echo '=============================================================='
SELECT privilege_type,
       has_table_privilege('kineticspay_app', 'ledger_entries', privilege_type) AS granted
FROM (VALUES ('SELECT'), ('INSERT'), ('UPDATE'), ('DELETE')) AS p(privilege_type);

\echo ''
\echo '=============================================================='
\echo 'TEST 20 NEGATIVE - the same transaction cannot be reversed twice'
\echo '        (this schema does not support partial reversals; a'
\echo '         second correction would double-count)'
\echo '=============================================================='
BEGIN;
UPDATE transactions SET status = 'REVERSED'
WHERE transaction_reference = 'KP-2026-000005';
INSERT INTO transactions (transaction_reference, transaction_type, status, currency_code,
                          reverses_transaction, narration, settled_at)
SELECT 'KP-2026-999010', 'REVERSAL', 'COMPLETED', 'NGN', t.transaction_id,
       'First reversal', now()
FROM transactions t WHERE t.transaction_reference = 'KP-2026-000005';
SELECT fn_post_entry('KP-2026-999010', 'WAL-CUS-000002-NGN', 'CREDIT', 20000.00);
SELECT fn_post_entry('KP-2026-999010', 'ACC-BANK-NGN',       'DEBIT',  20000.00);
-- a second reversal of the same original must be refused
INSERT INTO transactions (transaction_reference, transaction_type, status, currency_code,
                          reverses_transaction, narration, settled_at)
SELECT 'KP-2026-999011', 'REVERSAL', 'COMPLETED', 'NGN', t.transaction_id,
       'Second reversal of the same original', now()
FROM transactions t WHERE t.transaction_reference = 'KP-2026-000005';
ROLLBACK;

\echo ''
\echo '=============================================================='
\echo 'TEST 21 NEGATIVE - a zero-value posting is rejected'
\echo '        (amount > 0, not amount >= 0: a zero posting carries'
\echo '         no accounting meaning and would pass the balance check)'
\echo '=============================================================='
BEGIN;
INSERT INTO transactions (transaction_reference, transaction_type, status,
                          currency_code, narration, settled_at)
VALUES ('KP-2026-999012', 'DEPOSIT', 'COMPLETED', 'NGN', 'Zero posting', now());
SELECT fn_post_entry('KP-2026-999012', 'ACC-BANK-NGN', 'DEBIT', 0.00);
ROLLBACK;
