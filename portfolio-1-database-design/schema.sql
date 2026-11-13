-- =====================================================================
-- KineticsPay - Digital Payment and Wallet Management Platform
-- Portfolio 1: Database Design and Modelling
-- Target DBMS: PostgreSQL 16
--
-- MIT 8103 Advanced Database Systems - Continuous Assessment
-- Biliaminu Abdulfarid (301918844)
--
-- Run with:  psql -U postgres -d kineticspay -f schema.sql
-- =====================================================================

-- ---------------------------------------------------------------------
-- 0. Clean slate (idempotent re-runs during development)
-- ---------------------------------------------------------------------
DROP VIEW  IF EXISTS account_balances   CASCADE;
DROP VIEW  IF EXISTS wallets            CASCADE;
DROP TABLE IF EXISTS audit_logs         CASCADE;
DROP TABLE IF EXISTS ledger_entries     CASCADE;
DROP TABLE IF EXISTS transactions       CASCADE;
DROP TABLE IF EXISTS accounts           CASCADE;
DROP TABLE IF EXISTS customers          CASCADE;
DROP TABLE IF EXISTS currencies         CASCADE;

DROP TYPE IF EXISTS entry_direction_t    CASCADE;
DROP TYPE IF EXISTS account_type_t       CASCADE;
DROP TYPE IF EXISTS account_status_t     CASCADE;
DROP TYPE IF EXISTS transaction_type_t   CASCADE;
DROP TYPE IF EXISTS transaction_status_t CASCADE;
DROP TYPE IF EXISTS customer_status_t    CASCADE;
DROP TYPE IF EXISTS kyc_tier_t           CASCADE;
DROP TYPE IF EXISTS channel_t            CASCADE;

-- ---------------------------------------------------------------------
-- 1. Enumerated domains
--
-- Modelled as native ENUM types rather than free-text columns so that
-- invalid states are rejected by the engine, not by application code.
-- ---------------------------------------------------------------------
CREATE TYPE entry_direction_t    AS ENUM ('DEBIT', 'CREDIT');
CREATE TYPE account_type_t       AS ENUM ('CUSTOMER_WALLET', 'BANK_SETTLEMENT',
                                          'FEE_REVENUE', 'SUSPENSE');
CREATE TYPE account_status_t     AS ENUM ('ACTIVE', 'FROZEN', 'CLOSED');
CREATE TYPE transaction_type_t   AS ENUM ('DEPOSIT', 'WITHDRAWAL', 'TRANSFER',
                                          'FEE', 'REVERSAL');
CREATE TYPE transaction_status_t AS ENUM ('PENDING', 'COMPLETED', 'FAILED', 'REVERSED');
CREATE TYPE customer_status_t    AS ENUM ('ACTIVE', 'SUSPENDED', 'CLOSED');
CREATE TYPE kyc_tier_t           AS ENUM ('TIER_0', 'TIER_1', 'TIER_2', 'TIER_3');
CREATE TYPE channel_t            AS ENUM ('MOBILE_APP', 'WEB', 'USSD', 'API', 'INTERNAL');

-- ---------------------------------------------------------------------
-- 2. currencies
--
-- Reference table. minor_unit records how many decimal places the
-- currency actually uses (NGN/USD = 2, JPY = 0). Monetary columns are
-- declared NUMERIC(20,4) throughout: exact decimal arithmetic, never
-- FLOAT/REAL, which would introduce binary rounding error into balances.
-- ---------------------------------------------------------------------
CREATE TABLE currencies (
    currency_code   CHAR(3)      PRIMARY KEY,
    currency_name   VARCHAR(60)  NOT NULL UNIQUE,
    minor_unit      SMALLINT     NOT NULL DEFAULT 2,
    is_active       BOOLEAN      NOT NULL DEFAULT TRUE,

    CONSTRAINT currencies_code_format_chk
        CHECK (currency_code ~ '^[A-Z]{3}$'),
    CONSTRAINT currencies_minor_unit_chk
        CHECK (minor_unit BETWEEN 0 AND 4)
);

COMMENT ON TABLE currencies IS
    'ISO-4217 currency reference data. Isolated into its own relation to '
    'remove the transitive dependency currency_code -> currency_name that '
    'would otherwise sit inside accounts (3NF).';

-- ---------------------------------------------------------------------
-- 3. customers
--
-- Identity and KYC state only. Deliberately holds no balance and no
-- transaction data: a customer's financial position is derived from the
-- ledger, never stored on the customer row.
-- ---------------------------------------------------------------------
CREATE TABLE customers (
    customer_id         BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_reference  VARCHAR(20)      NOT NULL UNIQUE,
    first_name          VARCHAR(60)      NOT NULL,
    last_name           VARCHAR(60)      NOT NULL,
    email               VARCHAR(255)     NOT NULL UNIQUE,
    phone               VARCHAR(20)      NOT NULL UNIQUE,
    date_of_birth       DATE             NOT NULL,
    kyc_tier            kyc_tier_t       NOT NULL DEFAULT 'TIER_0',
    status              customer_status_t NOT NULL DEFAULT 'ACTIVE',
    created_at          TIMESTAMPTZ      NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ      NOT NULL DEFAULT now(),

    CONSTRAINT customers_reference_format_chk
        CHECK (customer_reference ~ '^CUS-[0-9]{6}$'),
    CONSTRAINT customers_email_format_chk
        CHECK (email ~ '^[^@[:space:]]+@[^@[:space:]]+\.[A-Za-z]{2,}$'),
    CONSTRAINT customers_phone_format_chk
        CHECK (phone ~ '^\+?[0-9]{10,15}$'),
    CONSTRAINT customers_adult_chk
        CHECK (date_of_birth <= CURRENT_DATE - INTERVAL '18 years')
);

COMMENT ON TABLE customers IS
    'Customer identity and KYC state. Holds no monetary value: balances '
    'are derived from ledger_entries.';

-- ---------------------------------------------------------------------
-- 4. accounts
--
-- The single account relation underpinning the double-entry ledger.
--
-- Design decision: customer wallets AND internal control accounts
-- (bank settlement, fee revenue, suspense) live in ONE table. Every
-- ledger entry can then carry a single, simple foreign key to
-- accounts.account_id. Splitting wallets and system accounts into two
-- tables would force ledger_entries into a polymorphic reference
-- (two nullable FKs plus a CHECK), which cannot be enforced
-- declaratively and is harder to join.
--
-- normal_balance encodes the accounting nature of the account:
--   asset accounts    (BANK_SETTLEMENT) increase on DEBIT
--   liability/revenue (CUSTOMER_WALLET, FEE_REVENUE) increase on CREDIT
-- A customer wallet is a liability: money KineticsPay owes the customer.
-- ---------------------------------------------------------------------
CREATE TABLE accounts (
    account_id        BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    account_reference VARCHAR(24)      NOT NULL UNIQUE,
    account_type      account_type_t   NOT NULL,
    customer_id       BIGINT           NULL
                      REFERENCES customers (customer_id) ON DELETE RESTRICT,
    currency_code     CHAR(3)          NOT NULL
                      REFERENCES currencies (currency_code) ON DELETE RESTRICT,
    normal_balance    entry_direction_t NOT NULL,
    status            account_status_t NOT NULL DEFAULT 'ACTIVE',
    opened_at         TIMESTAMPTZ      NOT NULL DEFAULT now(),
    closed_at         TIMESTAMPTZ      NULL,

    -- A customer wallet must have an owner; an internal control account
    -- must not. Enforced declaratively rather than in application code.
    CONSTRAINT accounts_ownership_chk CHECK (
        (account_type =  'CUSTOMER_WALLET' AND customer_id IS NOT NULL) OR
        (account_type <> 'CUSTOMER_WALLET' AND customer_id IS NULL)
    ),

    -- Customer wallets are liabilities of the platform, so they must
    -- carry a CREDIT normal balance.
    CONSTRAINT accounts_wallet_normal_balance_chk CHECK (
        account_type <> 'CUSTOMER_WALLET' OR normal_balance = 'CREDIT'
    ),

    CONSTRAINT accounts_closed_at_chk CHECK (
        (status = 'CLOSED' AND closed_at IS NOT NULL) OR
        (status <> 'CLOSED' AND closed_at IS NULL)
    ),

    -- Redundant-looking, but required: it lets ledger_entries declare a
    -- COMPOSITE foreign key on (account_id, currency_code), which makes
    -- it structurally impossible to post an NGN entry to a USD wallet.
    CONSTRAINT accounts_id_currency_uq UNIQUE (account_id, currency_code)
);

-- One wallet per customer per currency. Partial index so that internal
-- accounts (customer_id IS NULL) are unaffected.
CREATE UNIQUE INDEX accounts_one_wallet_per_customer_currency_uq
    ON accounts (customer_id, currency_code)
    WHERE account_type = 'CUSTOMER_WALLET';

COMMENT ON COLUMN accounts.normal_balance IS
    'DEBIT for asset accounts, CREDIT for liability and revenue accounts. '
    'Used by the account_balances view to apply the correct sign.';

-- ---------------------------------------------------------------------
-- 5. transactions
--
-- One row per business event (a deposit, a transfer, a reversal).
-- Carries no amount of its own: the amount lives in ledger_entries,
-- because a single transaction may post to more than two accounts
-- (for example a transfer that also charges a fee).
-- ---------------------------------------------------------------------
CREATE TABLE transactions (
    transaction_id         BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    transaction_reference  VARCHAR(32)        NOT NULL UNIQUE,
    transaction_type       transaction_type_t NOT NULL,
    status                 transaction_status_t NOT NULL DEFAULT 'PENDING',
    channel                channel_t          NOT NULL DEFAULT 'MOBILE_APP',
    currency_code          CHAR(3)            NOT NULL
                           REFERENCES currencies (currency_code) ON DELETE RESTRICT,
    initiated_by_customer  BIGINT             NULL
                           REFERENCES customers (customer_id) ON DELETE RESTRICT,
    reverses_transaction   BIGINT             NULL
                           REFERENCES transactions (transaction_id) ON DELETE RESTRICT,
    narration              VARCHAR(255)       NULL,
    initiated_at           TIMESTAMPTZ        NOT NULL DEFAULT now(),
    settled_at             TIMESTAMPTZ        NULL,

    CONSTRAINT transactions_reference_format_chk
        CHECK (transaction_reference ~ '^KP-[0-9]{4}-[0-9]{6}$'),

    -- Only a REVERSAL may point at a prior transaction, and every
    -- REVERSAL must do so.
    CONSTRAINT transactions_reversal_chk CHECK (
        (transaction_type =  'REVERSAL' AND reverses_transaction IS NOT NULL) OR
        (transaction_type <> 'REVERSAL' AND reverses_transaction IS NULL)
    ),

    -- A settlement timestamp only makes sense once the transaction has
    -- left the PENDING state.
    CONSTRAINT transactions_settled_at_chk CHECK (
        (settled_at IS NULL     AND status = 'PENDING') OR
        (settled_at IS NOT NULL AND status <> 'PENDING')
    ),

    CONSTRAINT transactions_settled_after_initiated_chk
        CHECK (settled_at IS NULL OR settled_at >= initiated_at),

    -- A given transaction can be reversed at most once.
    CONSTRAINT transactions_single_reversal_uq UNIQUE (reverses_transaction)
);

COMMENT ON TABLE transactions IS
    'Business-level financial event. Deliberately holds no amount column: '
    'amounts belong to the individual ledger postings, which allows a '
    'single event to touch three or more accounts (e.g. transfer + fee).';

-- ---------------------------------------------------------------------
-- 6. ledger_entries
--
-- The double-entry postings. Each row is one side of one transaction.
-- amount is always POSITIVE; direction carries the sign. For every
-- transaction, SUM(debits) must equal SUM(credits) - enforced below by
-- a deferred constraint trigger so that both sides can be inserted
-- within the same transaction before the check fires at COMMIT.
-- ---------------------------------------------------------------------
CREATE TABLE ledger_entries (
    entry_id        BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    transaction_id  BIGINT            NOT NULL
                    REFERENCES transactions (transaction_id) ON DELETE RESTRICT,
    account_id      BIGINT            NOT NULL,
    currency_code   CHAR(3)           NOT NULL,
    direction       entry_direction_t NOT NULL,
    amount          NUMERIC(20,4)     NOT NULL,
    posted_at       TIMESTAMPTZ       NOT NULL DEFAULT now(),

    CONSTRAINT ledger_entries_amount_positive_chk CHECK (amount > 0),

    -- Composite FK: the entry's currency must match the account's
    -- currency. Enforced by the engine, not by application logic.
    CONSTRAINT ledger_entries_account_currency_fk
        FOREIGN KEY (account_id, currency_code)
        REFERENCES accounts (account_id, currency_code) ON DELETE RESTRICT,

    -- An account may not be both debited and credited twice for the
    -- same side of the same transaction.
    CONSTRAINT ledger_entries_tx_account_direction_uq
        UNIQUE (transaction_id, account_id, direction)
);

COMMENT ON TABLE ledger_entries IS
    'Immutable double-entry postings. Append-only by policy: corrections '
    'are made by posting a REVERSAL transaction, never by UPDATE or DELETE, '
    'which preserves a complete audit trail.';

-- ---------------------------------------------------------------------
-- 7. audit_logs
--
-- Append-only record of significant system activity. details is JSONB
-- because the payload shape varies by action - a deliberate, contained
-- use of semi-structured data inside an otherwise normalised schema.
-- ---------------------------------------------------------------------
CREATE TABLE audit_logs (
    audit_id      BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    actor_type    VARCHAR(20)  NOT NULL DEFAULT 'SYSTEM',
    actor_id      BIGINT       NULL,
    action        VARCHAR(60)  NOT NULL,
    entity_table  VARCHAR(60)  NOT NULL,
    entity_id     BIGINT       NULL,
    details       JSONB        NULL,
    ip_address    INET         NULL,
    created_at    TIMESTAMPTZ  NOT NULL DEFAULT now(),

    CONSTRAINT audit_logs_actor_type_chk
        CHECK (actor_type IN ('CUSTOMER', 'STAFF', 'SYSTEM'))
);

-- ---------------------------------------------------------------------
-- 8. Integrity trigger: every transaction must balance
--
-- Declared as a DEFERRABLE INITIALLY DEFERRED constraint trigger. The
-- check runs once at COMMIT, after both the debit and the credit rows
-- exist. A row-level immediate trigger would fire after the first
-- INSERT and reject every legitimate transaction.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_assert_transaction_balanced()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $fn$
DECLARE
    v_imbalance   NUMERIC(20,4);
    v_entry_count INTEGER;
BEGIN
    SELECT
        COALESCE(SUM(CASE WHEN le.direction = 'DEBIT'
                          THEN le.amount ELSE -le.amount END), 0),
        COUNT(*)
    INTO v_imbalance, v_entry_count
    FROM ledger_entries le
    WHERE le.transaction_id = NEW.transaction_id;

    IF v_entry_count < 2 THEN
        RAISE EXCEPTION
            'Transaction % has only % ledger entry/entries; double-entry '
            'requires at least two.', NEW.transaction_id, v_entry_count
            USING ERRCODE = 'check_violation';
    END IF;

    IF v_imbalance <> 0 THEN
        RAISE EXCEPTION
            'Transaction % is unbalanced by %; total debits must equal '
            'total credits.', NEW.transaction_id, v_imbalance
            USING ERRCODE = 'check_violation';
    END IF;

    RETURN NULL;
END;
$fn$;

CREATE CONSTRAINT TRIGGER trg_ledger_entries_balanced
    AFTER INSERT ON ledger_entries
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW
    EXECUTE FUNCTION fn_assert_transaction_balanced();

-- ---------------------------------------------------------------------
-- 9. Integrity trigger: the ledger is append-only
--
-- Financial history is corrected by posting a compensating REVERSAL,
-- never by mutating or deleting a prior posting.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_forbid_ledger_mutation()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $fn$
BEGIN
    RAISE EXCEPTION
        'ledger_entries is append-only; use a REVERSAL transaction instead of %',
        TG_OP
        USING ERRCODE = 'restrict_violation';
END;
$fn$;

CREATE TRIGGER trg_ledger_entries_no_update
    BEFORE UPDATE OR DELETE ON ledger_entries
    FOR EACH ROW
    EXECUTE FUNCTION fn_forbid_ledger_mutation();

-- ---------------------------------------------------------------------
-- 10. Housekeeping trigger: maintain customers.updated_at
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_touch_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $fn$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END;
$fn$;

CREATE TRIGGER trg_customers_touch_updated_at
    BEFORE UPDATE ON customers
    FOR EACH ROW
    EXECUTE FUNCTION fn_touch_updated_at();

-- ---------------------------------------------------------------------
-- 11. Derived views
--
-- account_balances computes every balance from the ledger. No balance
-- is stored anywhere in the base tables, so a balance cannot drift out
-- of step with the postings that produced it.
--
-- The performance cost of this choice, and the materialised-view
-- alternative, are analysed in portfolio-2-query-optimisation and in
-- normalisation.md (Section 5, Deliberate Denormalisation).
-- ---------------------------------------------------------------------
CREATE VIEW account_balances AS
SELECT
    a.account_id,
    a.account_reference,
    a.account_type,
    a.customer_id,
    a.currency_code,
    a.status,
    COALESCE(SUM(CASE WHEN le.direction = a.normal_balance
                      THEN le.amount ELSE -le.amount END), 0)::NUMERIC(20,4)
        AS balance,
    COUNT(le.entry_id)   AS entry_count,
    MAX(le.posted_at)    AS last_posted_at
FROM accounts a
LEFT JOIN ledger_entries le ON le.account_id = a.account_id
GROUP BY a.account_id, a.account_reference, a.account_type,
         a.customer_id, a.currency_code, a.status, a.normal_balance;

COMMENT ON VIEW account_balances IS
    'Single source of truth for balances, derived from ledger_entries. '
    'Signed using accounts.normal_balance so that asset accounts increase '
    'on debit and liability accounts increase on credit.';

-- Convenience view: customer wallets only, with owner details.
CREATE VIEW wallets AS
SELECT
    ab.account_id    AS wallet_id,
    ab.account_reference AS wallet_reference,
    c.customer_id,
    c.customer_reference,
    c.first_name || ' ' || c.last_name AS customer_name,
    ab.currency_code,
    ab.balance,
    ab.status,
    ab.entry_count,
    ab.last_posted_at
FROM account_balances ab
JOIN customers c ON c.customer_id = ab.customer_id
WHERE ab.account_type = 'CUSTOMER_WALLET';

COMMENT ON VIEW wallets IS
    'Customer-facing wallet projection. Wallets are not a separate base '
    'table: they are the CUSTOMER_WALLET subtype of accounts.';

-- ---------------------------------------------------------------------
-- NOTE ON INDEXES
--
-- This script creates ONLY the indexes implied by PRIMARY KEY and UNIQUE
-- constraints. No secondary indexes are defined here, deliberately:
-- Portfolio 2 measures query performance against this baseline and then
-- introduces indexes, so the before/after execution plans compare against
-- an honest unindexed starting point.
-- ---------------------------------------------------------------------
