-- =====================================================================
-- KineticsPay - concurrency test fixtures
-- Portfolio 3: Transactions and Concurrency
--
-- MIT 8103 Advanced Database Systems
-- Biliaminu Abdulfarid (301918844)
--
-- Creates two test customers with wallets funded to a known balance, and
-- a helper that posts a withdrawal. Re-runnable: each run resets the test
-- wallets to a clean state by posting compensating entries rather than
-- deleting, because the ledger is append-only.
--
-- Run with:  psql -d kineticspay -f setup.sql
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Test customers and wallets
-- ---------------------------------------------------------------------
INSERT INTO customers (customer_reference, first_name, last_name, email,
                       phone, date_of_birth, kyc_tier)
VALUES ('CUS-900001', 'Concurrency', 'TestA', 'conc.a@example.com',
        '+2348090000001', '1990-01-01', 'TIER_3'),
       ('CUS-900002', 'Concurrency', 'TestB', 'conc.b@example.com',
        '+2348090000002', '1990-01-01', 'TIER_3')
ON CONFLICT (customer_reference) DO NOTHING;

INSERT INTO accounts (account_reference, account_type, customer_id,
                      currency_code, normal_balance)
SELECT 'WAL-TEST-A-NGN', 'CUSTOMER_WALLET', c.customer_id, 'NGN', 'CREDIT'
FROM customers c WHERE c.customer_reference = 'CUS-900001'
ON CONFLICT (account_reference) DO NOTHING;

INSERT INTO accounts (account_reference, account_type, customer_id,
                      currency_code, normal_balance)
SELECT 'WAL-TEST-B-NGN', 'CUSTOMER_WALLET', c.customer_id, 'NGN', 'CREDIT'
FROM customers c WHERE c.customer_reference = 'CUS-900002'
ON CONFLICT (account_reference) DO NOTHING;

-- ---------------------------------------------------------------------
-- 2. fn_reset_test_wallet - bring a test wallet to an exact balance
--
-- The ledger is append-only, so "resetting" means posting a balanced
-- correction, not deleting history. Internally this is a deposit or a
-- withdrawal against the bank settlement account for whatever difference
-- is required.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_reset_test_wallet(
    p_wallet_reference VARCHAR,
    p_target_balance   NUMERIC
) RETURNS NUMERIC
LANGUAGE plpgsql
AS $fn$
DECLARE
    v_wallet  BIGINT;
    v_current NUMERIC(20,4);
    v_delta   NUMERIC(20,4);
    v_tx      BIGINT;
    v_ref     VARCHAR;
BEGIN
    SELECT account_id INTO v_wallet
    FROM accounts WHERE account_reference = p_wallet_reference;

    SELECT balance INTO v_current
    FROM account_balances WHERE account_id = v_wallet;

    v_delta := p_target_balance - v_current;
    IF v_delta = 0 THEN
        RETURN v_current;
    END IF;

    v_ref := 'KP-2026-' || LPAD((900000 + (random()*99999)::INT)::TEXT, 6, '0');

    INSERT INTO transactions (transaction_reference, transaction_type, status,
                              channel, currency_code, narration,
                              initiated_at, settled_at)
    VALUES (v_ref,
            CASE WHEN v_delta > 0 THEN 'DEPOSIT'::transaction_type_t ELSE 'WITHDRAWAL'::transaction_type_t END,
            'COMPLETED', 'INTERNAL', 'NGN',
            'Test fixture reset', now(), now())
    RETURNING transaction_id INTO v_tx;

    IF v_delta > 0 THEN
        INSERT INTO ledger_entries (transaction_id, account_id, currency_code, direction, amount)
        VALUES (v_tx, 1,        'NGN', 'DEBIT',  v_delta),
               (v_tx, v_wallet, 'NGN', 'CREDIT', v_delta);
    ELSE
        INSERT INTO ledger_entries (transaction_id, account_id, currency_code, direction, amount)
        VALUES (v_tx, v_wallet, 'NGN', 'DEBIT',  -v_delta),
               (v_tx, 1,        'NGN', 'CREDIT', -v_delta);
    END IF;

    RETURN p_target_balance;
END;
$fn$;

-- ---------------------------------------------------------------------
-- 3. fn_post_withdrawal - post a withdrawal WITHOUT any safety check
--
-- Deliberately unsafe. It posts whatever it is told to post. Every
-- control mechanism tested in this activity is applied OUTSIDE this
-- function, so that the thing being compared is the control, not the
-- posting logic.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_post_withdrawal(
    p_wallet_reference VARCHAR,
    p_amount           NUMERIC,
    p_narration        VARCHAR DEFAULT 'Concurrency test withdrawal'
) RETURNS VARCHAR
LANGUAGE plpgsql
AS $fn$
DECLARE
    v_wallet BIGINT;
    v_tx     BIGINT;
    v_ref    VARCHAR;
BEGIN
    SELECT account_id INTO v_wallet
    FROM accounts WHERE account_reference = p_wallet_reference;

    v_ref := 'KP-2026-' || LPAD((800000 + (random()*99999)::INT)::TEXT, 6, '0');

    INSERT INTO transactions (transaction_reference, transaction_type, status,
                              channel, currency_code, narration,
                              initiated_at, settled_at)
    VALUES (v_ref, 'WITHDRAWAL', 'COMPLETED', 'API', 'NGN',
            p_narration, now(), now())
    RETURNING transaction_id INTO v_tx;

    INSERT INTO ledger_entries (transaction_id, account_id, currency_code, direction, amount)
    VALUES (v_tx, v_wallet, 'NGN', 'DEBIT',  p_amount),
           (v_tx, 1,        'NGN', 'CREDIT', p_amount);

    RETURN v_ref;
END;
$fn$;

-- ---------------------------------------------------------------------
-- 4. Fund both test wallets to 50,000.00
-- ---------------------------------------------------------------------
SELECT fn_reset_test_wallet('WAL-TEST-A-NGN', 50000.00) AS wallet_a_balance;
SELECT fn_reset_test_wallet('WAL-TEST-B-NGN', 50000.00) AS wallet_b_balance;

SELECT wallet_reference, customer_name, balance
FROM wallets WHERE wallet_reference LIKE 'WAL-TEST-%'
ORDER BY wallet_reference;
