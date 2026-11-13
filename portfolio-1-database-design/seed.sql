-- =====================================================================
-- KineticsPay - Representative seed data
-- Portfolio 1: Database Design and Modelling
--
-- Identity columns are GENERATED ALWAYS, so no surrogate key is ever
-- written literally. Rows are related to one another through their
-- natural business keys (customer_reference, account_reference,
-- transaction_reference), which keeps the script re-runnable and keeps
-- the identity sequences from drifting.
--
-- Run with:  psql -U postgres -d kineticspay -f seed.sql
-- =====================================================================

BEGIN;

-- ---------------------------------------------------------------------
-- 1. Reference data
-- ---------------------------------------------------------------------
INSERT INTO currencies (currency_code, currency_name, minor_unit) VALUES
    ('NGN', 'Nigerian Naira',        2),
    ('USD', 'United States Dollar',  2),
    ('GHS', 'Ghanaian Cedi',         2);

-- ---------------------------------------------------------------------
-- 2. Internal control accounts
--
-- Every customer deposit and withdrawal needs a counterparty inside the
-- ledger. Without these, a deposit would have nowhere to debit from and
-- the double-entry rule could not hold.
-- ---------------------------------------------------------------------
INSERT INTO accounts (account_reference, account_type, customer_id,
                      currency_code, normal_balance) VALUES
    ('ACC-BANK-NGN', 'BANK_SETTLEMENT', NULL, 'NGN', 'DEBIT'),
    ('ACC-BANK-USD', 'BANK_SETTLEMENT', NULL, 'USD', 'DEBIT'),
    ('ACC-FEES-NGN', 'FEE_REVENUE',     NULL, 'NGN', 'CREDIT'),
    ('ACC-SUSP-NGN', 'SUSPENSE',        NULL, 'NGN', 'CREDIT');

-- ---------------------------------------------------------------------
-- 3. Customers
-- ---------------------------------------------------------------------
INSERT INTO customers (customer_reference, first_name, last_name, email,
                       phone, date_of_birth, kyc_tier) VALUES
    ('CUS-000001', 'Amaka',   'Nwosu',     'amaka.nwosu@example.com',    '+2348031234501', '1994-03-12', 'TIER_2'),
    ('CUS-000002', 'Tunde',   'Bakare',    'tunde.bakare@example.com',   '+2348031234502', '1989-07-29', 'TIER_3'),
    ('CUS-000003', 'Zainab',  'Ibrahim',   'zainab.ibrahim@example.com', '+2348031234503', '1997-11-05', 'TIER_2'),
    ('CUS-000004', 'Chidi',   'Okonkwo',   'chidi.okonkwo@example.com',  '+2348031234504', '1992-01-18', 'TIER_3'),
    ('CUS-000005', 'Fatima',  'Yusuf',     'fatima.yusuf@example.com',   '+2348031234505', '2000-05-22', 'TIER_1'),
    ('CUS-000006', 'Emeka',   'Adeyemi',   'emeka.adeyemi@example.com',  '+2348031234506', '1986-09-30', 'TIER_3');

-- ---------------------------------------------------------------------
-- 4. Customer wallets
--
-- normal_balance is CREDIT for every wallet: a wallet is a liability,
-- money the platform owes the customer.
-- ---------------------------------------------------------------------
INSERT INTO accounts (account_reference, account_type, customer_id,
                      currency_code, normal_balance)
SELECT 'WAL-' || c.customer_reference || '-NGN', 'CUSTOMER_WALLET',
       c.customer_id, 'NGN', 'CREDIT'
FROM customers c;

-- A second, foreign-currency wallet for two customers.
INSERT INTO accounts (account_reference, account_type, customer_id,
                      currency_code, normal_balance)
SELECT 'WAL-' || c.customer_reference || '-USD', 'CUSTOMER_WALLET',
       c.customer_id, 'USD', 'CREDIT'
FROM customers c
WHERE c.customer_reference IN ('CUS-000004', 'CUS-000006');

-- ---------------------------------------------------------------------
-- 5. Transactions and their ledger postings
--
-- A small helper keeps the postings readable. It resolves accounts by
-- their business reference and inserts one side of a transaction.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_post_entry(
    p_transaction_reference VARCHAR,
    p_account_reference     VARCHAR,
    p_direction             entry_direction_t,
    p_amount                NUMERIC
) RETURNS VOID
LANGUAGE sql
AS $fn$
    INSERT INTO ledger_entries (transaction_id, account_id, currency_code,
                                direction, amount)
    SELECT t.transaction_id, a.account_id, a.currency_code,
           p_direction, p_amount
    FROM transactions t
    CROSS JOIN accounts a
    WHERE t.transaction_reference = p_transaction_reference
      AND a.account_reference     = p_account_reference;
$fn$;

-- --- 5.1 Deposits -----------------------------------------------------
INSERT INTO transactions (transaction_reference, transaction_type, status,
                          channel, currency_code, initiated_by_customer,
                          narration, initiated_at, settled_at)
SELECT 'KP-2026-000001', 'DEPOSIT', 'COMPLETED', 'MOBILE_APP', 'NGN',
       c.customer_id, 'Card funding', now() - INTERVAL '20 days', now() - INTERVAL '20 days' + INTERVAL '4 minutes'
FROM customers c WHERE c.customer_reference = 'CUS-000001';

SELECT fn_post_entry('KP-2026-000001', 'ACC-BANK-NGN',        'DEBIT',  50000.00);
SELECT fn_post_entry('KP-2026-000001', 'WAL-CUS-000001-NGN',  'CREDIT', 50000.00);

INSERT INTO transactions (transaction_reference, transaction_type, status,
                          channel, currency_code, initiated_by_customer,
                          narration, initiated_at, settled_at)
SELECT 'KP-2026-000002', 'DEPOSIT', 'COMPLETED', 'WEB', 'NGN',
       c.customer_id, 'Bank transfer funding', now() - INTERVAL '18 days', now() - INTERVAL '18 days' + INTERVAL '4 minutes'
FROM customers c WHERE c.customer_reference = 'CUS-000002';

SELECT fn_post_entry('KP-2026-000002', 'ACC-BANK-NGN',        'DEBIT',  120000.00);
SELECT fn_post_entry('KP-2026-000002', 'WAL-CUS-000002-NGN',  'CREDIT', 120000.00);

INSERT INTO transactions (transaction_reference, transaction_type, status,
                          channel, currency_code, initiated_by_customer,
                          narration, initiated_at, settled_at)
SELECT 'KP-2026-000003', 'DEPOSIT', 'COMPLETED', 'USSD', 'NGN',
       c.customer_id, 'Agent deposit', now() - INTERVAL '15 days', now() - INTERVAL '15 days' + INTERVAL '4 minutes'
FROM customers c WHERE c.customer_reference = 'CUS-000003';

SELECT fn_post_entry('KP-2026-000003', 'ACC-BANK-NGN',        'DEBIT',  75500.50);
SELECT fn_post_entry('KP-2026-000003', 'WAL-CUS-000003-NGN',  'CREDIT', 75500.50);

-- --- 5.2 Wallet-to-wallet transfer, with a fee ------------------------
--
-- Three postings in one transaction. This is precisely why the amount
-- lives on ledger_entries rather than on transactions: the sender is
-- debited 30,050.00 while the recipient receives 30,000.00 and fee
-- revenue takes 50.00. Debits (30,050.00) equal credits (30,050.00).
INSERT INTO transactions (transaction_reference, transaction_type, status,
                          channel, currency_code, initiated_by_customer,
                          narration, initiated_at, settled_at)
SELECT 'KP-2026-000004', 'TRANSFER', 'COMPLETED', 'MOBILE_APP', 'NGN',
       c.customer_id, 'Transfer to Tunde Bakare', now() - INTERVAL '12 days', now() - INTERVAL '12 days' + INTERVAL '4 minutes'
FROM customers c WHERE c.customer_reference = 'CUS-000001';

SELECT fn_post_entry('KP-2026-000004', 'WAL-CUS-000001-NGN', 'DEBIT',  30050.00);
SELECT fn_post_entry('KP-2026-000004', 'WAL-CUS-000002-NGN', 'CREDIT', 30000.00);
SELECT fn_post_entry('KP-2026-000004', 'ACC-FEES-NGN',       'CREDIT',    50.00);

-- --- 5.3 Withdrawal ---------------------------------------------------
INSERT INTO transactions (transaction_reference, transaction_type, status,
                          channel, currency_code, initiated_by_customer,
                          narration, initiated_at, settled_at)
SELECT 'KP-2026-000005', 'WITHDRAWAL', 'COMPLETED', 'MOBILE_APP', 'NGN',
       c.customer_id, 'Payout to bank account', now() - INTERVAL '9 days', now() - INTERVAL '9 days' + INTERVAL '4 minutes'
FROM customers c WHERE c.customer_reference = 'CUS-000002';

SELECT fn_post_entry('KP-2026-000005', 'WAL-CUS-000002-NGN', 'DEBIT',  20000.00);
SELECT fn_post_entry('KP-2026-000005', 'ACC-BANK-NGN',       'CREDIT', 20000.00);

-- --- 5.4 A failed transaction ----------------------------------------
--
-- A FAILED transaction is recorded for audit purposes but posts NOTHING
-- to the ledger. The balanced-transaction trigger is never invoked
-- because no entries exist, which is the correct outcome: a failed
-- transfer must not move value.
INSERT INTO transactions (transaction_reference, transaction_type, status,
                          channel, currency_code, initiated_by_customer,
                          narration, initiated_at, settled_at)
SELECT 'KP-2026-000006', 'TRANSFER', 'FAILED', 'API', 'NGN',
       c.customer_id, 'Declined: insufficient funds', now() - INTERVAL '7 days', now() - INTERVAL '7 days' + INTERVAL '4 minutes'
FROM customers c WHERE c.customer_reference = 'CUS-000005';

-- --- 5.5 A deposit that is later reversed -----------------------------
INSERT INTO transactions (transaction_reference, transaction_type, status,
                          channel, currency_code, initiated_by_customer,
                          narration, initiated_at, settled_at)
SELECT 'KP-2026-000007', 'DEPOSIT', 'REVERSED', 'WEB', 'NGN',
       c.customer_id, 'Card funding (later charged back)', now() - INTERVAL '5 days', now() - INTERVAL '5 days' + INTERVAL '4 minutes'
FROM customers c WHERE c.customer_reference = 'CUS-000003';

SELECT fn_post_entry('KP-2026-000007', 'ACC-BANK-NGN',       'DEBIT',  10000.00);
SELECT fn_post_entry('KP-2026-000007', 'WAL-CUS-000003-NGN', 'CREDIT', 10000.00);

-- The correction is a NEW transaction with mirrored postings. The
-- original entries are never updated or deleted.
INSERT INTO transactions (transaction_reference, transaction_type, status,
                          channel, currency_code, initiated_by_customer,
                          reverses_transaction, narration, initiated_at, settled_at)
SELECT 'KP-2026-000008', 'REVERSAL', 'COMPLETED', 'INTERNAL', 'NGN',
       c.customer_id, t.transaction_id,
       'Reversal of KP-2026-000007 (chargeback)', now() - INTERVAL '4 days', now() - INTERVAL '4 days' + INTERVAL '4 minutes'
FROM customers c
CROSS JOIN transactions t
WHERE c.customer_reference = 'CUS-000003'
  AND t.transaction_reference = 'KP-2026-000007';

SELECT fn_post_entry('KP-2026-000008', 'WAL-CUS-000003-NGN', 'DEBIT',  10000.00);
SELECT fn_post_entry('KP-2026-000008', 'ACC-BANK-NGN',       'CREDIT', 10000.00);

-- --- 5.6 Multi-currency deposit --------------------------------------
INSERT INTO transactions (transaction_reference, transaction_type, status,
                          channel, currency_code, initiated_by_customer,
                          narration, initiated_at, settled_at)
SELECT 'KP-2026-000009', 'DEPOSIT', 'COMPLETED', 'API', 'USD',
       c.customer_id, 'Inbound USD settlement', now() - INTERVAL '3 days', now() - INTERVAL '3 days' + INTERVAL '4 minutes'
FROM customers c WHERE c.customer_reference = 'CUS-000004';

SELECT fn_post_entry('KP-2026-000009', 'ACC-BANK-USD',       'DEBIT',  1500.00);
SELECT fn_post_entry('KP-2026-000009', 'WAL-CUS-000004-USD', 'CREDIT', 1500.00);

-- --- 5.7 A pending transaction ---------------------------------------
INSERT INTO transactions (transaction_reference, transaction_type, status,
                          channel, currency_code, initiated_by_customer,
                          narration)
SELECT 'KP-2026-000010', 'WITHDRAWAL', 'PENDING', 'MOBILE_APP', 'NGN',
       c.customer_id, 'Awaiting bank confirmation'
FROM customers c WHERE c.customer_reference = 'CUS-000001';

-- ---------------------------------------------------------------------
-- 6. Audit trail
-- ---------------------------------------------------------------------
INSERT INTO audit_logs (actor_type, actor_id, action, entity_table,
                        entity_id, details, ip_address)
SELECT 'CUSTOMER', t.initiated_by_customer, 'TRANSACTION_INITIATED',
       'transactions', t.transaction_id,
       jsonb_build_object('reference', t.transaction_reference,
                          'type',      t.transaction_type,
                          'channel',   t.channel),
       '198.51.100.24'::INET
FROM transactions t;

COMMIT;
