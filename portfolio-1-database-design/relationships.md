# Relationships, Keys and Constraints

**MIT 8103 — Advanced Database Systems | Portfolio 1**
**Student:** Biliaminu Abdulfarid (301918844)

---

## 1. Relationship inventory

| # | Parent | Child | Cardinality | Meaning | Delete rule |
|---|---|---|---|---|---|
| R1 | `customers` | `accounts` | 1 : 0..N | A customer owns zero or more wallets, at most one per currency | RESTRICT |
| R2 | `currencies` | `accounts` | 1 : 0..N | Every account is denominated in exactly one currency | RESTRICT |
| R3 | `currencies` | `transactions` | 1 : 0..N | Every transaction states its currency | RESTRICT |
| R4 | `customers` | `transactions` | 1 : 0..N | A transaction may be initiated by a customer (null for system-generated) | RESTRICT |
| R5 | `transactions` | `ledger_entries` | 1 : 0..N | A transaction is realised as two or more postings | RESTRICT |
| R6 | `accounts` | `ledger_entries` | 1 : 0..N | An account is debited or credited by many postings | RESTRICT |
| R7 | `transactions` | `transactions` | 0..1 : 0..1 | A transaction may be reversed by exactly one later transaction | RESTRICT |

**Why RESTRICT everywhere.** No `CASCADE` appears anywhere in this schema.
Financial records are never removed by side effect: deleting a customer must
fail while their postings exist, forcing an explicit archival decision rather
than silently destroying an audit trail.

### The many-to-many resolution

`transactions` and `accounts` stand in a many-to-many relationship: one
transaction affects several accounts, and one account participates in many
transactions. `ledger_entries` is the associative relation resolving it, and it
carries its own attributes (`direction`, `amount`, `posted_at`) rather than
being a bare junction table.

### The subtype relationship

`accounts` holds two conceptual entity types under one relation, discriminated
by `account_type`:

```
accounts
├── CUSTOMER_WALLET   → customer_id NOT NULL, normal_balance = CREDIT (liability)
├── BANK_SETTLEMENT   → customer_id NULL,     normal_balance = DEBIT  (asset)
├── FEE_REVENUE       → customer_id NULL,     normal_balance = CREDIT (revenue)
└── SUSPENSE          → customer_id NULL,     normal_balance = CREDIT
```

The rationale for single-table inheritance over separate tables is set out in
`normalisation.md`, Section 5.

---

## 2. Primary keys

Every relation uses a surrogate `BIGINT GENERATED ALWAYS AS IDENTITY` primary
key, with the business identifier carried alongside as a `UNIQUE` natural key.

| Relation | Surrogate PK | Natural key (UNIQUE) |
|---|---|---|
| `customers` | `customer_id` | `customer_reference`, also `email`, `phone` |
| `currencies` | `currency_code` *(natural PK — ISO-4217 is stable)* | `currency_name` |
| `accounts` | `account_id` | `account_reference` |
| `transactions` | `transaction_id` | `transaction_reference` |
| `ledger_entries` | `entry_id` | `(transaction_id, account_id, direction)` |
| `audit_logs` | `audit_id` | — |

`GENERATED ALWAYS` rather than `BIGSERIAL`: it is the SQL-standard form and it
forbids an application from writing an explicit key value, which prevents the
identity sequence drifting out of step with the data.

`currencies` is the single exception to the surrogate-key rule. ISO-4217 codes
are externally governed, stable and already short, so a surrogate would add a
join without adding value.

---

## 3. Foreign keys

| Child relation | Columns | References | Notes |
|---|---|---|---|
| `accounts` | `customer_id` | `customers(customer_id)` | Nullable — internal accounts have no owner |
| `accounts` | `currency_code` | `currencies(currency_code)` | |
| `transactions` | `currency_code` | `currencies(currency_code)` | |
| `transactions` | `initiated_by_customer` | `customers(customer_id)` | Nullable — system-initiated transactions |
| `transactions` | `reverses_transaction` | `transactions(transaction_id)` | Self-referencing; UNIQUE |
| `ledger_entries` | `transaction_id` | `transactions(transaction_id)` | |
| `ledger_entries` | **`(account_id, currency_code)`** | **`accounts(account_id, currency_code)`** | **Composite — see below** |

### The composite foreign key

The single most important constraint in the schema:

```sql
CONSTRAINT ledger_entries_account_currency_fk
    FOREIGN KEY (account_id, currency_code)
    REFERENCES accounts (account_id, currency_code)
```

This requires a seemingly redundant `UNIQUE (account_id, currency_code)` on
`accounts`, since `account_id` is already the primary key. The redundancy buys
something significant: it makes **posting a naira amount to a dollar wallet
structurally impossible**, enforced by the engine rather than by application
code that someone might forget to write.

`verify.sql` Test 6 demonstrates the rejection.

---

## 4. Constraint inventory

### CHECK constraints

| Constraint | Relation | Rule |
|---|---|---|
| `currencies_code_format_chk` | `currencies` | Code matches `^[A-Z]{3}$` |
| `currencies_minor_unit_chk` | `currencies` | Minor unit between 0 and 4 |
| `customers_reference_format_chk` | `customers` | Reference matches `^CUS-[0-9]{6}$` |
| `customers_email_format_chk` | `customers` | Structurally valid email address |
| `customers_phone_format_chk` | `customers` | 10–15 digits, optional leading `+` |
| `customers_adult_chk` | `customers` | Customer is at least 18 years old |
| `accounts_ownership_chk` | `accounts` | Wallets have an owner; internal accounts do not |
| `accounts_wallet_normal_balance_chk` | `accounts` | Customer wallets must be CREDIT-normal (liabilities) |
| `accounts_closed_at_chk` | `accounts` | `closed_at` is set if and only if status is CLOSED |
| `transactions_reference_format_chk` | `transactions` | Reference matches `^KP-[0-9]{4}-[0-9]{6}$` |
| `transactions_reversal_chk` | `transactions` | Only a REVERSAL points at a prior transaction, and every REVERSAL does |
| `transactions_settled_at_chk` | `transactions` | `settled_at` is null if and only if status is PENDING |
| `transactions_settled_after_initiated_chk` | `transactions` | Settlement cannot precede initiation |
| `ledger_entries_amount_positive_chk` | `ledger_entries` | Amount strictly greater than zero |
| `audit_logs_actor_type_chk` | `audit_logs` | Actor is CUSTOMER, STAFF or SYSTEM |

### UNIQUE constraints and indexes

| Constraint | Rule |
|---|---|
| `accounts_id_currency_uq` | Supports the composite foreign key above |
| `accounts_one_wallet_per_customer_currency_uq` | **Partial** unique index: one wallet per customer per currency, applied only where `account_type = 'CUSTOMER_WALLET'` so internal accounts are unaffected |
| `transactions_single_reversal_uq` | A transaction can be reversed at most once |
| `ledger_entries_tx_account_direction_uq` | One account cannot be debited twice within one transaction |

### Triggers

| Trigger | Timing | Rule |
|---|---|---|
| `trg_ledger_entries_balanced` | `AFTER INSERT`, **DEFERRABLE INITIALLY DEFERRED** | Every transaction has at least two postings and total debits equal total credits. Deferred so the check runs at COMMIT, once both sides exist |
| `trg_ledger_entries_no_update` | `BEFORE UPDATE OR DELETE` | The ledger is append-only; corrections are posted as REVERSAL transactions |
| `trg_customers_touch_updated_at` | `BEFORE UPDATE` | Maintains `customers.updated_at` |

---

## 5. Data type decisions

| Decision | Rationale |
|---|---|
| `NUMERIC(20,4)` for all monetary values | Exact decimal arithmetic. `FLOAT`/`REAL` use binary floating point, which cannot represent 0.10 exactly and accumulates rounding error across a ledger. Four decimal places accommodate sub-kobo intermediate values such as percentage fees |
| `TIMESTAMPTZ`, never `TIMESTAMP` | Stores an absolute instant. A payment platform operating across regions cannot rely on an implied local time zone |
| Native `ENUM` types | Invalid states are rejected by the engine. A `VARCHAR` status column admits `'completed'`, `'Completed'` and `'complete'` as three distinct values |
| `CHAR(3)` for currency codes | ISO-4217 codes are fixed-length by definition |
| `JSONB` confined to `audit_logs.details` | The audit payload shape varies by action type. Contained, deliberate use of semi-structured data inside an otherwise fully normalised schema — the ledger itself remains strictly relational |
| `INET` for IP addresses | Native type with validation and network-aware operators, rather than a string |

---

## 6. Referential integrity verification

All of the above is demonstrated empirically in `verify.sql`, whose captured
output is in `evidence/verify-output.txt`:

| Test | Assertion | Result |
|---|---|---|
| 1 | Balances derive correctly from the ledger | ✅ |
| 2 | Trial balance: total debits = total credits, per currency | ✅ PASS |
| 3 | Every individual transaction balances to zero | ✅ |
| 4 | An unbalanced transaction is rejected | ✅ rejected |
| 5 | A single-sided posting is rejected | ✅ rejected |
| 6 | A currency mismatch is rejected | ✅ rejected |
| 7 | `UPDATE` on the ledger is rejected | ✅ rejected |
| 8 | `DELETE` on the ledger is rejected | ✅ rejected |
| 9 | An internal account with an owner is rejected | ✅ rejected |
| 10 | A duplicate wallet for one customer and currency is rejected | ✅ rejected |
| 11 | A negative posting amount is rejected | ✅ rejected |
| 12 | A reversal leaves both the original and the correction intact, net zero | ✅ |
