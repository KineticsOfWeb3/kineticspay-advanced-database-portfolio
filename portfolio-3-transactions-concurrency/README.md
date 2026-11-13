# Portfolio 3 — Transactions and Concurrency

**MIT 8103 — Advanced Database Systems | Continuous Assessment (7 marks)**
**Student:** Biliaminu Abdulfarid (301918844)
**Case study:** KineticsPay — Digital Payment and Wallet Management Platform
**DBMS:** PostgreSQL 16.15

---

## What this activity delivers

| Required evidence | Where it is |
|---|---|
| Transaction examples: commit, rollback | Phase 0 — [`evidence/concurrency-output.txt`](evidence/concurrency-output.txt) |
| Isolation levels | Phases 4 and 5 |
| Concurrency issue | Phases 1, 2 and 6 — a real overdraft and a real deadlock |
| Control mechanism | Phase 3 and [`safe-transfer.sql`](safe-transfer.sql) |
| Output evidence | [`evidence/`](evidence/) — four captured runs |
| Analysis | [`analysis.md`](analysis.md) |

Portfolios 1 and 2 are **unchanged**.

---

## The scenario

> Wallet holds **₦50,000**. Two sessions each withdraw **₦35,000**,
> concurrently. Total attempted **₦70,000**; available **₦50,000**.

Two independent `psql` processes against the live database — not simulated, not
sequential. `pg_sleep()` and a staggered start make the interleaving
deterministic, so the same failure reproduces every run rather than depending
on luck.

---

## Results

| phase | control | outcome |
|---|---|---|
| 0 | — | Rollback leaves no trace; savepoint discards part of a transaction |
| 1 | None | ❌ **Overdraft of ₦20,000** |
| 2A | Deferred constraint, staggered 0.4s | ✅ Rejected — **by luck of timing** |
| 2B | Deferred constraint, simultaneous | ❌ **Overdraft of ₦20,000 again** |
| 3 | `SELECT ... FOR UPDATE` | ✅ Correct, deterministic |
| 4 | `SERIALIZABLE` | ✅ Correct, via `SQLSTATE 40001` |
| 5 | Read phenomena | Non-repeatable read and phantoms demonstrated across levels |
| 6A | Opposing locks, no ordering | ❌ **Deadlock, `SQLSTATE 40P01`** |
| 6B | Ascending lock order | ✅ Both succeed |

---

## The finding that matters

Phase 2 ran the **same constraint and the same two sessions twice**, differing
only in a 0.4-second stagger.

```
2A (staggered)      balance after: 15000.0000     ← rejected correctly
2B (simultaneous)   balance after: -20000.0000    ← both committed
```

A control whose effectiveness depends on commit timing **is not a control**.

This is also why Phase 2A is dangerous as evidence. Tested once, with any
natural delay between sessions, the deferred constraint looks like it works. It
would pass a test suite, ship, and fail in production under exactly the load
that makes failure most expensive. **A single passing concurrency test proves
nothing** — it has to be run at the timing that would break it.

## And one that reframes Portfolio 1

In Phase 1 the customer went ₦20,000 overdrawn while the ledger stayed
perfectly balanced:

```
 global_imbalance
------------------
           0.0000
```

Every Portfolio 1 constraint held. Double-entry guarantees value is conserved,
and it delivered that guarantee flawlessly while the business rule was
violated. **Accounting integrity and business-rule integrity are different
properties.** It also settles the question Portfolio 2 left open: the balance
was never stale — both sessions read the authoritative ledger correctly — the
*check* was unserialised. Freshness and concurrency control are independent
problems.

---

## A defect in my own fix

Verifying against the full Portfolio 2 dataset surfaced something the small
test wallets could not. That dataset holds **2,087 wallets with negative
balances**, generated before any overdraft rule existed, the worst at
−₦1,059,612.

```
ERROR:  Overdraft refused on WAL-CUS-001052-NGN: balance would be -854579.1600
```

That was a **deposit**. The constraint blocked the only action that would
repair the account — a customer in overdraft could not pay their way out of it.

Fixed by checking only postings that *reduce* the balance, since a wallet is
`CREDIT`-normal and a credit can never cause an overdraft. Verified both ways:
deposits into negative wallets now commit, further debits are still refused.
([`evidence/overdraft-defect.txt`](evidence/overdraft-defect.txt))

A constraint added to a populated table has two behaviours — one for new data,
one for data that already breaks it — and only the first is usually tested.

---

## The final implementation

[`safe-transfer.sql`](safe-transfer.sql) applies three layers:

1. **`fn_lock_accounts`** — row locks in ascending `account_id` order. The
   Phase 6B fix; a lock cycle becomes structurally impossible.
2. **`fn_safe_withdraw` / `fn_safe_transfer`** — lock, then read the
   authoritative balance under the lock, then decide, then post. The lock is
   the control.
3. **`trg_ledger_entries_no_overdraft`** — the deferred constraint, retained as
   a **backstop**, not as the control. Phase 2B proved it cannot be relied on
   alone, but if a future code path forgets the lock it still catches the
   common case.

`accounts` acts as a **lock anchor**: the balance does not live there, but
every writer agrees to take the same lock before reading and posting. The
weakness is inherent — a writer who skips the lock is not blocked by it — which
is why the backstop is kept and why these functions are the single sanctioned
entry point.

### Verified under the conditions that defeated everything weaker

| test | result |
|---|---|
| Original race, staggered | ✅ balance ₦15,000 |
| Simultaneous commits (defeated Phase 2B) | ✅ balance ₦15,000 |
| **Five** concurrent ₦35,000 withdrawals on ₦50,000 | ✅ one succeeds, four rejected |
| Opposing transfers (deadlocked in Phase 6) | ✅ both succeed, no deadlock |
| Withdrawal of ₦999,999 | ✅ clean rejection |
| Ledger integrity afterwards | ✅ NGN and USD BALANCED |

---

## Locking or `SERIALIZABLE`?

Both prevent the overdraft. KineticsPay uses **explicit locking**, for
operational reasons rather than theoretical ones: under contention a lock makes
callers *wait*, while `SERIALIZABLE` makes them *fail and retry*. A payment API
that returns a retryable error under load is worse than one that queues
briefly, and an unhandled `40001` in a client never written to expect it looks
exactly like a failed payment.

`SERIALIZABLE` has the genuine advantage of protecting transactions whose
authors never considered concurrency — the opposite of the lock's weakness. It
is the better default where every write path cannot be audited. Retry guidance
for callers who want it is in [`safe-transfer.sql`](safe-transfer.sql) §5.

---

## How to run it

```bash
# Needs the Portfolio 1 schema; the Portfolio 2 dataset is optional but
# is what surfaced the overdraft defect above.
psql -d kineticspay -f setup.sql            # test customers, wallets, fixtures
./run-concurrency.sh                        # phases 0-6, ~40s
psql -d kineticspay -f safe-transfer.sql    # install the fix
./verify-safe.sh                            # re-test under the same races
```

---

## Files

```
portfolio-3-transactions-concurrency/
├── README.md                this file
├── setup.sql                test customers, wallets, deliberately unsafe helpers
├── run-concurrency.sh       phases 0-6, two concurrent sessions throughout
├── safe-transfer.sql        the fix: lock ordering, safe withdraw/transfer, backstop
├── verify-safe.sh           re-tests the fix under every race that broke the rest
├── analysis.md              full analysis
└── evidence/
    ├── concurrency-output.txt          all seven phases, captured
    ├── safe-transfer-verification.txt  six verifications of the final implementation
    └── overdraft-defect.txt            the defect in my own rule, before and after
```

---

## Carried forward

| To | What |
|---|---|
| Portfolio 4 | MongoDB offers no cross-document transactions by default. The same withdrawal race in a document store, and what a single-document atomic update does and does not buy |
| Portfolio 5 | Row locks are single-node. Across shards this becomes distributed consensus — two-phase commit, and the CAP trade-off made concrete |
| Known limitation | 2,087 legacy negative wallets remain. The constraint prevents new overdrafts but does not repair historical ones; remediation would be a reconciliation exercise, not a schema change |
