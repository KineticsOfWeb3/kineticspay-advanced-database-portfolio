# Portfolio 1 — Database Design and Modelling

**MIT 8103 — Advanced Database Systems | Continuous Assessment (7 marks)**
**Student:** Biliaminu Abdulfarid (301918844)
**Case study:** KineticsPay — Digital Payment and Wallet Management Platform
**DBMS:** PostgreSQL 16

---

## What this activity delivers

| Required evidence | Where it is |
|---|---|
| Chosen case study description | [`case-study.md`](case-study.md) |
| ER diagram | [`diagrams/er-diagram.png`](diagrams/er-diagram.png) (source: `er-diagram.mmd`) |
| Relational schema | [`schema.sql`](schema.sql) |
| Keys | [`relationships.md`](relationships.md) §2–3 |
| Constraints | [`relationships.md`](relationships.md) §4 |
| Normalisation explanation | [`normalisation.md`](normalisation.md) |
| Execution evidence | [`evidence/verify-output.txt`](evidence/verify-output.txt) |

---

## The design in one paragraph

KineticsPay is modelled as a **double-entry ledger**. Customer wallets and the
platform's internal control accounts share a single `accounts` relation
discriminated by `account_type`. A `transactions` row records a business event
and carries no amount; the amounts live in `ledger_entries`, one row per debit
or credit, so a single transfer can move value between two wallets *and* charge
a fee in one atomic, balanced event. **No balance is stored anywhere** — every
balance is derived from the ledger by the `account_balances` view, which makes
it impossible for a balance to disagree with the postings behind it.

---

## How to run it

```bash
# 1. Create the database
createdb kineticspay

# 2. Build the schema (tables, types, constraints, triggers, views)
psql -d kineticspay -f schema.sql

# 3. Load representative data
psql -d kineticspay -f seed.sql

# 4. Run the verification suite
psql -d kineticspay -f verify.sql
```

To regenerate the ER diagram from source:

```bash
npm install -g @mermaid-js/mermaid-cli
mmdc -i diagrams/er-diagram.mmd -o diagrams/er-diagram.png -b white -w 1800
```

Tested against PostgreSQL 16.10 on Linux. `schema.sql` is idempotent — it drops
and recreates every object, so it can be re-run during development.

---

## How it was tested

`verify.sql` contains twelve tests. Three are positive (balances compute
correctly, the trial balance nets to zero, each transaction balances) and nine
are **negative** — each one attempts an operation that must fail, and the
captured output shows the database rejecting it.

The negative tests matter more than the positive ones. They demonstrate that
the integrity rules are enforced by the **engine**, not by application code
that a future developer could bypass.

### Results

| Test | Assertion | Outcome |
|---|---|---|
| 1 | Wallet balances derive correctly from the ledger | ✅ |
| 2 | Trial balance per currency: NGN 315,550.50 debits = 315,550.50 credits; USD 1,500.00 = 1,500.00 | ✅ **PASS** |
| 3 | All ten transactions balance to zero | ✅ |
| 4 | Unbalanced transaction (5,000 debit vs 4,000 credit) | ✅ rejected — *"Transaction 15 is unbalanced by 1000.0000"* |
| 5 | Single-sided posting | ✅ rejected — *"has only 1 ledger entry; double-entry requires at least two"* |
| 6 | NGN amount posted to a USD wallet | ✅ rejected — composite FK violation |
| 7 | `UPDATE` on `ledger_entries` | ✅ rejected — *"ledger_entries is append-only"* |
| 8 | `DELETE` on `ledger_entries` | ✅ rejected |
| 9 | Internal account given a customer owner | ✅ rejected — `accounts_ownership_chk` |
| 10 | Second NGN wallet for the same customer | ✅ rejected — partial unique index |
| 11 | Negative posting amount | ✅ rejected — `ledger_entries_amount_positive_chk` |
| 12 | Reversal: original and correction both persist, net ledger effect zero | ✅ |

### A note on Test 4 and Test 5

The balanced-transaction trigger is `DEFERRABLE INITIALLY DEFERRED`, so it
normally fires at `COMMIT`. An early version of these tests ended in `ROLLBACK`,
which meant the trigger never ran and the tests appeared to pass without
proving anything. They now issue `SET CONSTRAINTS ALL IMMEDIATE` to force the
check inside the script, so the rejection is visible in the captured output.

---

## Key design decisions

**1. Double-entry ledger rather than a mutable balance column.**
A `wallets.balance` column can silently drift from the transactions that
produced it. Deriving the balance makes that class of bug unrepresentable. The
performance cost is real and is measured in Portfolio 2, where the materialised
alternative is profiled at scale. See `normalisation.md` §7.

**2. Money as `NUMERIC(20,4)`, never floating point.**
Binary floating point cannot represent 0.10 exactly. In a ledger that error
accumulates and the books stop balancing.

**3. One `accounts` table, not separate wallet and system-account tables.**
Separate tables would force `ledger_entries` into a polymorphic foreign key —
two nullable columns and a `CHECK` — which cannot be enforced declaratively. A
`wallets` view provides the customer-facing projection.

**4. Currency enforced by composite foreign key.**
`ledger_entries(account_id, currency_code)` references
`accounts(account_id, currency_code)`, making a cross-currency posting
structurally impossible rather than merely discouraged.

**5. The ledger is append-only.**
`UPDATE` and `DELETE` on `ledger_entries` raise an exception. Corrections are
posted as compensating `REVERSAL` transactions, preserving the full history —
which is what an auditor, and the Nigeria Data Protection Act 2023, require.

**6. No secondary indexes.**
`schema.sql` creates only the indexes implied by `PRIMARY KEY` and `UNIQUE`.
This is deliberate: Portfolio 2 measures query performance against this
baseline and then introduces indexes, so the before/after execution plans
compare against an honest unindexed starting point.

---

## Files

```
portfolio-1-database-design/
├── README.md               this file
├── case-study.md           organisation, users, data, operations
├── schema.sql              DDL: types, tables, constraints, triggers, views
├── seed.sql                representative data (6 customers, 10 transactions)
├── verify.sql              12-test integrity suite
├── normalisation.md        UNF → 1NF → 2NF → 3NF → BCNF, plus denormalisation
├── relationships.md        keys, foreign keys, constraint inventory
├── diagrams/
│   ├── er-diagram.mmd      Mermaid source
│   └── er-diagram.png      rendered diagram
└── evidence/
    └── verify-output.txt   captured psql output of all 12 tests
```

---

## Carried forward

| To | What |
|---|---|
| Portfolio 2 | Profile the derived-balance query at scale; measure the materialised-view and snapshot alternatives; index `ledger_entries(account_id, posted_at)` |
| Portfolio 3 | Demonstrate the insufficient-funds race on a wallet; the schema deliberately has no overdraft check yet, so the failure is reproducible before the fix |
| Portfolio 4 | Model `audit_logs.details` and transaction metadata as MongoDB documents and argue the fit |
| Portfolio 5 | Fragment `ledger_entries` by region for NDPA data residency; replicate for availability |
