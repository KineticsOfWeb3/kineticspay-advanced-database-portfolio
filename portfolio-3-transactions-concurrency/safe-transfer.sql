-- =====================================================================
-- KineticsPay - concurrency-safe money movement
-- Portfolio 3: Transactions and Concurrency
--
-- MIT 8103 Advanced Database Systems
-- Biliaminu Abdulfarid (301918844)
--
-- The fix, informed by what the experiments in run-concurrency.sh
-- actually showed:
--
--   Phase 1  No control            -> overdraft of NGN 20,000
--   Phase 2A Deferred constraint   -> caught it, but only because one
--                                     session committed first
--   Phase 2B Deferred constraint   -> SAME CODE, simultaneous commits,
--                                     overdraft of NGN 20,000 again
--   Phase 3  SELECT ... FOR UPDATE -> correct, deterministically
--   Phase 4  SERIALIZABLE          -> correct, via SQLSTATE 40001
--
-- Phase 2 is the reason this file exists in the shape it does. A
-- correctness CONSTRAINT is not a concurrency CONTROL: whether it fired
-- depended entirely on commit timing. Both layers are therefore applied
-- here, and the lock - not the constraint - is what makes the outcome
-- deterministic.
--
-- Run with:  psql -d kineticspay -f safe-transfer.sql
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Overdraft constraint - the BACKSTOP, not the control
--
-- Deferred, because the balance is derived and can only be evaluated
-- once all of a transaction's postings exist. Phase 2B proved this
-- cannot be relied on alone. It is retained because defence in depth is
-- worth having: if a future code path forgets to take the lock, this
-- still catches the common case rather than nothing at all.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_assert_no_overdraft()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $fn$
DECLARE
    v_balance NUMERIC(20,4);
    v_type    account_type_t;
    v_normal  entry_direction_t;
    v_ref     VARCHAR;
BEGIN
    SELECT a.account_type, a.account_reference, a.normal_balance
    INTO v_type, v_ref, v_normal
    FROM accounts a WHERE a.account_id = NEW.account_id;

    -- Internal control accounts are expected to run negative: the bank
    -- settlement account is an asset that is credited on withdrawal.
    IF v_type <> 'CUSTOMER_WALLET' THEN
        RETURN NULL;
    END IF;

    -- Only postings that REDUCE the balance can cause an overdraft.
    -- A wallet is CREDIT-normal, so a CREDIT increases it.
    --
    -- This test is not cosmetic. Without it, a wallet that is already
    -- negative cannot be repaired: the deposit that would fix it is
    -- itself rejected, because the resulting balance is still below
    -- zero. The constraint would block the only action that helps.
    -- Found by testing against the Portfolio 2 dataset, which contains
    -- 2,087 wallets that went negative before any overdraft rule
    -- existed. See analysis.md section 7.
    IF NEW.direction = v_normal THEN
        RETURN NULL;
    END IF;

    SELECT balance INTO v_balance
    FROM account_balances WHERE account_id = NEW.account_id;

    IF v_balance < 0 THEN
        RAISE EXCEPTION 'Overdraft refused on %: balance would be % after a % of %',
            v_ref, v_balance, NEW.direction, NEW.amount
            USING ERRCODE = 'check_violation',
                  HINT = 'Take a row lock on the account before posting.';
    END IF;

    RETURN NULL;
END;
$fn$;

DROP TRIGGER IF EXISTS trg_ledger_entries_no_overdraft ON ledger_entries;
CREATE CONSTRAINT TRIGGER trg_ledger_entries_no_overdraft
    AFTER INSERT ON ledger_entries
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW
    EXECUTE FUNCTION fn_assert_no_overdraft();

-- ---------------------------------------------------------------------
-- 2. fn_lock_accounts - take row locks in a deterministic order
--
-- Phase 6 produced a real deadlock (SQLSTATE 40P01) when two opposing
-- transfers each locked their own wallet first and then reached for the
-- other. Phase 6B showed the cure: every writer locks accounts in
-- ascending account_id order, whichever direction the money moves. A
-- lock cycle then cannot form, because no session ever holds a higher
-- id while waiting for a lower one.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_lock_accounts(p_account_ids BIGINT[])
RETURNS VOID
LANGUAGE plpgsql
AS $fn$
DECLARE
    v_locked INTEGER;
BEGIN
    SELECT COUNT(*) INTO v_locked
    FROM (
        SELECT account_id
        FROM accounts
        WHERE account_id = ANY (p_account_ids)
        ORDER BY account_id          -- deterministic ordering prevents deadlock
        FOR UPDATE
    ) s;

    IF v_locked <> array_length(p_account_ids, 1) THEN
        RAISE EXCEPTION 'Expected to lock % accounts, locked %',
            array_length(p_account_ids, 1), v_locked
            USING ERRCODE = 'no_data_found';
    END IF;
END;
$fn$;

-- ---------------------------------------------------------------------
-- 3. fn_safe_withdraw
--
-- The correct read-check-post sequence:
--   1. lock the wallet row (the serialisation point)
--   2. read the authoritative balance - now nobody else can post to it
--   3. decide
--   4. post, or raise
--
-- The lock is held until COMMIT. The accounts row is a LOCK ANCHOR: the
-- balance does not live there, but every writer agrees to take it, which
-- is what makes the check atomic with the posting.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_safe_withdraw(
    p_wallet_reference VARCHAR,
    p_amount           NUMERIC,
    p_narration        VARCHAR DEFAULT 'Withdrawal'
) RETURNS VARCHAR
LANGUAGE plpgsql
AS $fn$
DECLARE
    v_wallet   BIGINT;
    v_currency CHAR(3);
    v_bank     BIGINT;
    v_balance  NUMERIC(20,4);
    v_tx       BIGINT;
    v_ref      VARCHAR;
BEGIN
    IF p_amount <= 0 THEN
        RAISE EXCEPTION 'Withdrawal amount must be positive, got %', p_amount
            USING ERRCODE = 'check_violation';
    END IF;

    SELECT account_id, currency_code INTO v_wallet, v_currency
    FROM accounts WHERE account_reference = p_wallet_reference;

    IF v_wallet IS NULL THEN
        RAISE EXCEPTION 'No such wallet: %', p_wallet_reference
            USING ERRCODE = 'no_data_found';
    END IF;

    -- (1) serialisation point
    PERFORM fn_lock_accounts(ARRAY[v_wallet]);

    -- (2) authoritative balance, read under the lock
    SELECT balance INTO v_balance
    FROM account_balances WHERE account_id = v_wallet;

    -- (3) decision
    IF v_balance < p_amount THEN
        RAISE EXCEPTION 'Insufficient funds in %: balance %, requested %',
            p_wallet_reference, v_balance, p_amount
            USING ERRCODE = 'check_violation';
    END IF;

    SELECT account_id INTO v_bank
    FROM accounts
    WHERE account_type = 'BANK_SETTLEMENT' AND currency_code = v_currency;

    -- (4) post
    v_ref := 'KP-2026-' || LPAD((600000 + (random()*99999)::INT)::TEXT, 6, '0');

    INSERT INTO transactions (transaction_reference, transaction_type, status,
                              channel, currency_code, narration,
                              initiated_at, settled_at)
    VALUES (v_ref, 'WITHDRAWAL', 'COMPLETED', 'API', v_currency,
            p_narration, now(), now())
    RETURNING transaction_id INTO v_tx;

    INSERT INTO ledger_entries (transaction_id, account_id, currency_code, direction, amount)
    VALUES (v_tx, v_wallet, v_currency, 'DEBIT',  p_amount),
           (v_tx, v_bank,   v_currency, 'CREDIT', p_amount);

    RETURN v_ref;
END;
$fn$;

-- ---------------------------------------------------------------------
-- 4. fn_safe_transfer
--
-- Wallet-to-wallet with an optional fee, atomic throughout. Both wallets
-- are locked in ascending id order by fn_lock_accounts, so two opposing
-- transfers between the same pair cannot deadlock.
--
-- The sender is debited amount + fee in ONE posting, because
-- ledger_entries_tx_account_direction_uq forbids two debits to the same
-- account within one transaction - a Portfolio 1 constraint shaping the
-- implementation here.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_safe_transfer(
    p_from_reference VARCHAR,
    p_to_reference   VARCHAR,
    p_amount         NUMERIC,
    p_fee            NUMERIC DEFAULT 0,
    p_narration      VARCHAR DEFAULT 'Transfer'
) RETURNS VARCHAR
LANGUAGE plpgsql
AS $fn$
DECLARE
    v_from     BIGINT;
    v_to       BIGINT;
    v_currency CHAR(3);
    v_to_curr  CHAR(3);
    v_fees     BIGINT;
    v_balance  NUMERIC(20,4);
    v_total    NUMERIC(20,4);
    v_tx       BIGINT;
    v_ref      VARCHAR;
BEGIN
    IF p_amount <= 0 THEN
        RAISE EXCEPTION 'Transfer amount must be positive, got %', p_amount
            USING ERRCODE = 'check_violation';
    END IF;

    SELECT account_id, currency_code INTO v_from, v_currency
    FROM accounts WHERE account_reference = p_from_reference;
    SELECT account_id, currency_code INTO v_to, v_to_curr
    FROM accounts WHERE account_reference = p_to_reference;

    IF v_from IS NULL OR v_to IS NULL THEN
        RAISE EXCEPTION 'Unknown wallet in transfer % -> %',
            p_from_reference, p_to_reference USING ERRCODE = 'no_data_found';
    END IF;
    IF v_from = v_to THEN
        RAISE EXCEPTION 'Cannot transfer to the same wallet'
            USING ERRCODE = 'check_violation';
    END IF;
    IF v_currency <> v_to_curr THEN
        RAISE EXCEPTION 'Currency mismatch: % is %, % is %',
            p_from_reference, v_currency, p_to_reference, v_to_curr
            USING ERRCODE = 'check_violation';
    END IF;

    -- Ascending-id lock order: the Phase 6B fix.
    PERFORM fn_lock_accounts(ARRAY[v_from, v_to]);

    v_total := p_amount + COALESCE(p_fee, 0);

    SELECT balance INTO v_balance
    FROM account_balances WHERE account_id = v_from;

    IF v_balance < v_total THEN
        RAISE EXCEPTION 'Insufficient funds in %: balance %, needed % (amount % + fee %)',
            p_from_reference, v_balance, v_total, p_amount, COALESCE(p_fee, 0)
            USING ERRCODE = 'check_violation';
    END IF;

    v_ref := 'KP-2026-' || LPAD((500000 + (random()*99999)::INT)::TEXT, 6, '0');

    INSERT INTO transactions (transaction_reference, transaction_type, status,
                              channel, currency_code, narration,
                              initiated_at, settled_at)
    VALUES (v_ref, 'TRANSFER', 'COMPLETED', 'API', v_currency,
            p_narration, now(), now())
    RETURNING transaction_id INTO v_tx;

    -- Sender debited once for amount + fee (see note above).
    INSERT INTO ledger_entries (transaction_id, account_id, currency_code, direction, amount)
    VALUES (v_tx, v_from, v_currency, 'DEBIT',  v_total),
           (v_tx, v_to,   v_currency, 'CREDIT', p_amount);

    IF COALESCE(p_fee, 0) > 0 THEN
        SELECT account_id INTO v_fees
        FROM accounts
        WHERE account_type = 'FEE_REVENUE' AND currency_code = v_currency;

        IF v_fees IS NULL THEN
            RAISE EXCEPTION 'No fee revenue account for currency %', v_currency
                USING ERRCODE = 'no_data_found';
        END IF;

        INSERT INTO ledger_entries (transaction_id, account_id, currency_code, direction, amount)
        VALUES (v_tx, v_fees, v_currency, 'CREDIT', p_fee);
    END IF;

    RETURN v_ref;
END;
$fn$;

-- ---------------------------------------------------------------------
-- 5. Retry guidance for SERIALIZABLE callers
--
-- Phase 4 showed SERIALIZABLE also prevents the overdraft, by aborting
-- one transaction with SQLSTATE 40001. That is an EXPECTED outcome, not
-- an error condition: the contract is that the application retries.
--
-- PL/pgSQL cannot retry its own aborted transaction, because the failure
-- cancels the whole transaction including this block. The retry must sit
-- in the application. Shape of it:
--
--     attempts = 0
--     loop:
--         attempts += 1
--         try:
--             BEGIN ISOLATION LEVEL SERIALIZABLE
--             SELECT fn_safe_transfer(...)
--             COMMIT
--             break
--         except SQLSTATE in ('40001', '40P01'):     -- serialization failure, deadlock
--             ROLLBACK
--             if attempts >= 5: raise
--             sleep(random exponential backoff)
--             continue
--
-- 40P01 (deadlock) belongs in the same handler: both are transient and
-- both are resolved by retrying.
--
-- This schema uses explicit locking rather than SERIALIZABLE as its
-- primary control. The reasons are in analysis.md section 6: under
-- contention the lock makes callers WAIT, while SERIALIZABLE makes them
-- FAIL and retry, and a payment API that returns a retryable error under
-- load is worse operationally than one that queues briefly.
-- ---------------------------------------------------------------------

-- ---------------------------------------------------------------------
-- 6. Verification
-- ---------------------------------------------------------------------
\echo ''
\echo '=== safe-transfer.sql installed ==='
SELECT p.proname AS function, pg_get_function_arguments(p.oid) AS arguments
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.proname IN ('fn_safe_withdraw','fn_safe_transfer','fn_lock_accounts','fn_assert_no_overdraft')
ORDER BY p.proname;

SELECT tgname AS trigger_name,
       CASE tgenabled WHEN 'O' THEN 'enabled' WHEN 'A' THEN 'ENABLE ALWAYS'
                      WHEN 'D' THEN 'DISABLED' ELSE tgenabled::text END AS state
FROM pg_trigger
WHERE tgrelid = 'ledger_entries'::regclass AND NOT tgisinternal
ORDER BY tgname;
