# Normalisation of the KineticsPay Schema

**MIT 8103 — Advanced Database Systems | Portfolio 1**
**Student:** Biliaminu Abdulfarid (301918844)

This document traces the KineticsPay schema from an unnormalised starting point
through to Boyce–Codd Normal Form, states the functional dependencies at each
step, and then argues one deliberate departure from full normalisation.

---

## 1. The unnormalised starting point (UNF)

The natural starting point is the artefact the business already produces: a
customer wallet statement. Captured as a single relation it looks like this.

**WALLET_STATEMENT** (unnormalised)

| Attribute | Example |
|---|---|
| customer_reference | CUS-000001 |
| customer_name | Amaka Nwosu |
| customer_email | amaka.nwosu@example.com |
| customer_phone | +2348031234501 |
| wallet_reference | WAL-CUS-000001-NGN |
| currency_code | NGN |
| currency_name | Nigerian Naira |
| minor_unit | 2 |
| balance | 19950.00 |
| **{ transaction_reference, type, status, channel, amount, counterparty_wallet, counterparty_name, fee, narration, initiated_at, settled_at }** | *repeating group — many transactions per wallet* |

Three defects are visible immediately:

1. **A repeating group.** One wallet row holds many transactions, so the
   relation is not even in 1NF.
2. **Update anomaly.** A customer who changes phone number must be updated on
   every statement row that carries their details.
3. **Insertion anomaly.** A newly opened wallet with no transactions cannot be
   represented without null transaction attributes.
4. **Deletion anomaly.** Deleting a customer's only transaction would discard
   the currency's name and minor unit if that currency were used nowhere else.

---

## 2. First Normal Form (1NF)

> *Every attribute holds a single atomic value; no repeating groups.*

The repeating group is flattened so that each row represents one transaction
line for one wallet.

**WALLET_TRANSACTION_1NF**
`(wallet_reference, transaction_reference, customer_reference, customer_name,
customer_email, customer_phone, currency_code, currency_name, minor_unit,
type, status, channel, amount, counterparty_wallet, counterparty_name, fee,
narration, initiated_at, settled_at)`

Composite primary key: **(wallet_reference, transaction_reference)**

The derived `balance` attribute is dropped at this point. It is not a fact
about any single row; it is an aggregate over many. Section 5 revisits whether
it should be reintroduced.

1NF is satisfied, but the composite key creates partial dependencies.

---

## 3. Second Normal Form (2NF)

> *1NF, and every non-key attribute is fully functionally dependent on the
> whole primary key — no partial dependencies.*

Functional dependencies present in `WALLET_TRANSACTION_1NF`:

```
FD1  wallet_reference      -> customer_reference, customer_name,
                              customer_email, customer_phone,
                              currency_code, currency_name, minor_unit
FD2  transaction_reference -> type, status, channel, narration,
                              initiated_at, settled_at
FD3  (wallet_reference, transaction_reference) -> amount, fee, counterparty_wallet
```

FD1 and FD2 are **partial dependencies**: each determines attributes from only
one half of the composite key. Decomposing on them yields:

**WALLET_2NF** `(wallet_reference, customer_reference, customer_name,
customer_email, customer_phone, currency_code, currency_name, minor_unit)`

**TRANSACTION_2NF** `(transaction_reference, type, status, channel, narration,
initiated_at, settled_at)`

**POSTING_2NF** `(wallet_reference, transaction_reference, amount, fee,
counterparty_wallet)`

The update anomaly on customer contact details is now gone: a phone number is
stored once per wallet rather than once per transaction.

---

## 4. Third Normal Form (3NF)

> *2NF, and no non-key attribute is transitively dependent on the primary key.*

Two transitive dependencies remain in `WALLET_2NF`:

```
FD4  wallet_reference -> customer_reference -> customer_name,
                                               customer_email,
                                               customer_phone
FD5  wallet_reference -> currency_code      -> currency_name, minor_unit
```

In both cases a non-key attribute determines other non-key attributes. The
practical consequence of FD5 is that the name of the naira would be repeated on
every wallet row, and could be spelled inconsistently across them.

Decomposing on FD4 and FD5 produces the three relations that survive into the
final schema:

**CUSTOMERS** `(customer_id, customer_reference, first_name, last_name, email,
phone, date_of_birth, kyc_tier, status, …)`

**CURRENCIES** `(currency_code, currency_name, minor_unit, is_active)`

**ACCOUNTS** `(account_id, account_reference, account_type, customer_id,
currency_code, normal_balance, status, …)`

Every non-key attribute now depends on the key, the whole key, and nothing but
the key.

---

## 5. Beyond 3NF: the posting relation is still wrong

`POSTING_2NF` passes the mechanical normal-form tests, but it encodes a false
assumption about the business: that every transaction has exactly two parties
and at most one fee.

That assumption breaks on the very first real transfer. Transaction
`KP-2026-000004` moves ₦30,000 from Amaka to Tunde and charges a ₦50 fee. Three
accounts are affected:

| Account | Direction | Amount |
|---|---|---|
| Amaka's wallet | DEBIT | 30,050.00 |
| Tunde's wallet | CREDIT | 30,000.00 |
| Fee revenue | CREDIT | 50.00 |

A relation with `counterparty_wallet` and `fee` columns cannot represent this
without either nullable columns that mean different things in different rows,
or a second row that duplicates the transaction's identity. Both are symptoms
of modelling a **many-to-many** relationship (transactions ↔ accounts) as if it
were binary.

The correct resolution is the standard one: introduce an associative relation.

**LEDGER_ENTRIES** `(entry_id, transaction_id, account_id, currency_code,
direction, amount, posted_at)`

Each row is one side of one posting. `direction` carries the sign, so `amount`
is always positive. A transaction with any number of participating accounts is
now representable, and the accounting invariant becomes a property the database
can check:

```
for every transaction:  SUM(debits) = SUM(credits)
```

This is enforced by `trg_ledger_entries_balanced`, a `DEFERRABLE INITIALLY
DEFERRED` constraint trigger. Deferral is essential: an immediate trigger would
fire after the first `INSERT`, when only one side of the entry exists, and
reject every legitimate transaction.

### Wallets are not a separate table

A second structural decision: customer wallets and the platform's internal
control accounts (bank settlement, fee revenue, suspense) share one `accounts`
relation, discriminated by `account_type`.

The alternative — separate `wallets` and `system_accounts` tables — would force
`ledger_entries` to hold a **polymorphic reference**: two nullable foreign keys
plus a `CHECK` ensuring exactly one is populated. That cannot be enforced by a
single declarative constraint, it defeats referential integrity on the column
that matters most, and it complicates every join. One table with a subtype
discriminator keeps `ledger_entries.account_id` a single, simple foreign key.

Customer-facing code is unaffected: a `wallets` **view** projects the
`CUSTOMER_WALLET` subtype with owner details attached.

---

## 6. Boyce–Codd Normal Form (BCNF)

> *For every non-trivial functional dependency X → Y, X is a superkey.*

Checking each final relation:

| Relation | Determinants | Superkey? | BCNF |
|---|---|---|---|
| `currencies` | `currency_code` | Yes (PK) | ✅ |
| `customers` | `customer_id`, `customer_reference`, `email`, `phone` | All PK or UNIQUE | ✅ |
| `accounts` | `account_id`, `account_reference`, `(customer_id, currency_code)` partial | All PK or UNIQUE | ✅ |
| `transactions` | `transaction_id`, `transaction_reference`, `reverses_transaction` | All PK or UNIQUE | ✅ |
| `ledger_entries` | `entry_id`, `(transaction_id, account_id, direction)` | Both PK or UNIQUE | ✅ |
| `audit_logs` | `audit_id` | Yes (PK) | ✅ |

Every determinant is a candidate key, so all relations are in BCNF.

**Higher normal forms.** No relation contains two independent multi-valued
attributes, so there are no non-trivial multi-valued dependencies and 4NF holds
trivially. No relation decomposes into smaller relations that rejoin without
loss, so 5NF holds as well.

---

## 7. Deliberate denormalisation: the balance question

The most consequential design decision in this schema is what the schema does
**not** contain: there is no `balance` column anywhere.

Every balance is derived by the `account_balances` view:

```sql
COALESCE(SUM(CASE WHEN le.direction = a.normal_balance
                  THEN le.amount ELSE -le.amount END), 0)
```

`normal_balance` makes the sign correct for both account natures: an asset
account (the bank settlement account) increases on debit, while a liability
account (a customer wallet) increases on credit.

### The trade-off

| | Derived balance (chosen) | Stored balance column |
|---|---|---|
| Correctness | Cannot drift — the balance *is* the ledger | Can silently diverge from the postings if any write path forgets to update it |
| Read cost | Aggregation over all of a wallet's history; grows without bound | Single-row read, O(1) |
| Write cost | Insert postings only | Insert postings **and** update the wallet row |
| Concurrency | No contention on a shared row | Every transaction touching a wallet serialises on that row |
| Auditability | Balance is reproducible from first principles at any point in time | Requires trusting a cached number |

For a payment ledger, correctness wins the argument outright. A balance column
that disagrees with the postings behind it is worse than a slow query: it is
money that cannot be accounted for, and under the Nigeria Data Protection Act
2023 and ordinary financial-reporting obligations it is an auditability failure,
not merely a performance characteristic.

### Where denormalisation is nonetheless justified

The read cost is real, and it grows linearly with transaction history. Once a
wallet accumulates hundreds of thousands of postings, recomputing its balance on
every mobile-app home-screen load becomes untenable.

The appropriate remedy is **not** a mutable balance column but a *controlled*
denormalisation that preserves the ledger as the source of truth:

1. **A materialised view** refreshed on a schedule, serving balance displays
   where a few seconds of staleness is acceptable, while authorisation
   decisions continue to read the ledger directly.
2. **Periodic balance snapshots** — a `balance_snapshots` relation holding each
   account's balance as at a closing date, so a current balance becomes the
   snapshot plus only the postings since. This bounds the aggregation without
   ever making the snapshot authoritative.

Both are measured in **Portfolio 2**, where the derived-balance query is
profiled against the materialised alternative with real execution plans at
scale. The outcome of that measurement, not an a priori preference, decides
what ships.

### One further accepted denormalisation

`transactions.currency_code` duplicates information already reachable through
`ledger_entries → accounts → currency_code`. It is retained because it allows a
transaction to be filtered or partitioned by currency without joining the
postings, and because it documents the intended currency of a transaction that
has not yet posted any entries (a `PENDING` row). The redundancy is contained:
the composite foreign key on `ledger_entries` independently guarantees that no
posting can reach an account of a different currency, so the duplicate cannot
produce an inconsistent state in the ledger itself.

---

## 8. Summary of the final schema

| Relation | Purpose | Normal form |
|---|---|---|
| `currencies` | ISO-4217 reference data | BCNF |
| `customers` | Identity and KYC state; holds no monetary value | BCNF |
| `accounts` | Customer wallets and internal control accounts (subtype discriminated) | BCNF |
| `transactions` | Business-level financial events; holds no amount | BCNF |
| `ledger_entries` | Double-entry postings; append-only | BCNF |
| `audit_logs` | Append-only activity trail | BCNF |
| `account_balances` | View — balances derived from the ledger | n/a (derived) |
| `wallets` | View — the `CUSTOMER_WALLET` projection | n/a (derived) |

All six base relations are in BCNF. The single deliberate redundancy
(`transactions.currency_code`) is documented above and is constrained so that it
cannot cause an inconsistency.
