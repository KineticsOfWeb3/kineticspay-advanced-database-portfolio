# Transactions and Concurrency — Analysis

**MIT 8103 — Advanced Database Systems | Portfolio 3**
**Student:** Biliaminu Abdulfarid (301918844)
**Case study:** KineticsPay — Digital Payment and Wallet Management Platform
**DBMS:** PostgreSQL 16.15

---

## 1. The scenario

Identical in every phase:

> Wallet `WAL-TEST-A-NGN` holds **₦50,000**.
> Session A withdraws **₦35,000**. Session B withdraws **₦35,000**, concurrently.
> Total attempted: **₦70,000**. Available: **₦50,000**.

Exactly one withdrawal should succeed. Each phase applies a different control
and reports what actually happened.

These are two **independent `psql` processes** against the live database, not a
simulation. Interleaving is made deterministic with `pg_sleep()` and a
staggered start, so the same failure reproduces on every run instead of
depending on luck.

Raw output: [`evidence/concurrency-output.txt`](evidence/concurrency-output.txt).

---

## 2. Phase 0 — Commit, rollback and savepoints

Before concurrency, the baseline. A withdrawal posted and rolled back leaves no
trace: balance unchanged at ₦50,000, entry count unchanged. **Atomicity.**

With a savepoint, a transaction posts ₦10,000, sets `SAVEPOINT after_first`,
posts another ₦10,000, then `ROLLBACK TO SAVEPOINT after_first` and commits.
Final balance **₦40,000** — the first posting kept, the second discarded.
Atomicity is not all-or-nothing at the statement level; a transaction can
contain nested units of work.

---

## 3. Phase 1 — The race, unprotected

Each session does what an unprotected application does: read the authoritative
balance, decide, post.

```
A| NOTICE:  read balance = 50000.0000
A| NOTICE:  DECISION: sufficient funds -> POSTED 35000
B| NOTICE:  read balance = 50000.0000
B| NOTICE:  DECISION: sufficient funds -> POSTED 35000

balance after: -20000.0000
```

**The platform just lent ₦20,000 it never agreed to lend.**

Two things make this worth dwelling on.

**The balance was never stale.** Both sessions read the authoritative ledger,
correctly, at a moment when the answer genuinely was ₦50,000. Portfolio 2's
conclusion that authorising a debit must read the ledger rather than a cache
was right but insufficient — freshness was never the problem. The **check** was
unserialised.

**The ledger still balances.** Global debits equal credits exactly:

```
 global_imbalance
------------------
           0.0000
```

Every Portfolio 1 integrity constraint held throughout. Double-entry guarantees
that value is conserved — that money is neither created nor destroyed — and it
delivered that guarantee perfectly while the customer went ₦20,000 overdrawn.
**Accounting integrity and business-rule integrity are different properties**,
and satisfying the first says nothing about the second.

---

## 4. Phase 2 — Is a constraint enough on its own?

The natural instinct: add a constraint forbidding a negative wallet balance and
let the database enforce it. Since the balance is derived, it must be a
`DEFERRABLE INITIALLY DEFERRED` constraint trigger evaluated at commit.

### 2A — staggered by 0.4s

```
A| DECISION: sufficient funds -> POSTED 35000
A| DO
B| DECISION: sufficient funds -> POSTED 35000
B| ERROR:  Overdraft refused on WAL-TEST-A-NGN: balance would be -20000.0000

balance after: 15000.0000
```

It worked. B's deferred check ran *after* A had committed, so it computed
−₦20,000 and refused.

### 2B — the same code, no stagger

```
A| DECISION: sufficient funds -> POSTED 35000
A| DO
B| DECISION: sufficient funds -> POSTED 35000
B| DO

balance after: -20000.0000
```

**The same constraint, the same two sessions, the opposite outcome.** Both
commits landed close enough together that neither transaction's deferred check
saw the other's postings — each computed ₦15,000 and passed.

### Why this is the most important result in the activity

A control whose effectiveness depends on commit timing **is not a control**. It
is a race with better odds.

The failure is not that the constraint is wrong. The constraint is correct: it
rejects exactly the states it should, given what it can see. The problem is
what it can see. Each transaction evaluates it against its own snapshot plus
whatever has committed by then, and under concurrent commits neither has
visibility of the other.

This also makes Phase 2A actively dangerous as evidence. Tested once, with any
natural delay between sessions, the constraint looks like it works. It would
pass a test suite, ship, and fail in production under exactly the load that
makes failure most expensive. **A single passing concurrency test proves
nothing** — the test has to be run at the timing that would break it.

Correctness constraints and concurrency controls solve different problems. The
constraint is still worth keeping as a backstop, but something else has to make
the outcome deterministic.

---

## 5. Phase 3 — `SELECT ... FOR UPDATE`

```
A| NOTICE:  acquired row lock on account 5511
A| NOTICE:  read balance = 50000.0000
A| NOTICE:  DECISION: sufficient funds -> POSTED 35000
B| NOTICE:  acquired row lock on account 5511
B| NOTICE:  read balance = 15000.0000
B| NOTICE:  DECISION: insufficient funds -> REJECTED

balance after: 15000.0000
```

Correct, and correct **deterministically** rather than by luck. B blocked at
the lock until A committed, then read a balance that already included A's
withdrawal.

### The lock anchor

Worth being precise about what is locked. The balance does not live in
`accounts` — it is derived from `ledger_entries`, and locking a row in
`accounts` does not lock anything in `ledger_entries`.

`accounts` is acting as a **lock anchor**: an agreed rendezvous point. The
serialisation comes from every writer taking the same lock before reading and
posting. The lock does not physically protect the data; it coordinates the
writers who participate.

That is also its weakness. **A writer who skips the lock is not blocked by it.**
The protection holds only while every code path honours the convention, which
is why the deferred constraint from Phase 2 is retained as a backstop and why
`fn_safe_withdraw` exists as the single sanctioned entry point.

---

## 6. Phase 4 — `SERIALIZABLE`

No explicit locks. Both sessions run at `SERIALIZABLE` and read the ledger.

```
A| COMMIT
B| ERROR:  could not serialize access due to read/write dependencies among transactions
B| DETAIL:  Reason code: Canceled on identification as a pivot, during write.
B| HINT:  The transaction might succeed if retried.

balance after: 15000.0000
```

Also correct, by a completely different mechanism. PostgreSQL's Serializable
Snapshot Isolation tracked the read-write dependency between the two
transactions and identified B as a **pivot** — a transaction whose commit would
produce a result unreachable from any serial ordering — and aborted it with
`SQLSTATE 40001`.

### Pessimistic or optimistic?

| | `FOR UPDATE` | `SERIALIZABLE` |
|---|---|---|
| Strategy | Pessimistic: prevent the conflict | Optimistic: detect it afterwards |
| Loser's experience | **Waits**, then gets a correct answer | **Fails** with 40001, must retry |
| Application burden | Remember to take the lock | Implement retry on every transaction |
| Behaviour under load | Queues; latency rises | Abort rate rises; wasted work |
| Scope of protection | Only the writers who take the lock | Every transaction, automatically |
| Risk | A code path that forgets the lock | Retry storms; unhandled 40001 |

**KineticsPay uses explicit locking as its primary control.** The reasoning is
operational rather than theoretical: under contention a lock makes callers
*wait*, while `SERIALIZABLE` makes them *fail and retry*. A payment API that
returns a retryable error under load is worse than one that queues briefly —
and worse still, an unhandled 40001 in a client that was never written to
expect it looks exactly like a failed payment.

`SERIALIZABLE` has the real advantage that it protects transactions whose
authors never thought about concurrency at all, which is the opposite of the
lock's weakness. The honest position is that it is the better default for a
system where you cannot audit every write path; here, with one sanctioned
entry point, the lock is the better fit. Retry guidance for callers who do want
`SERIALIZABLE` is in [`safe-transfer.sql`](safe-transfer.sql) §5.

---

## 7. A defect in my own overdraft rule

Running the verification against the full Portfolio 2 dataset surfaced
something the small test wallets never would have.

That dataset contains **2,087 wallets with negative balances** — generated
before any overdraft rule existed, the worst at −₦1,059,612. Adding a
constraint does not retroactively repair data that already violates it.

Testing a deposit into one of them:

```
ERROR:  Overdraft refused on WAL-CUS-001052-NGN: balance would be -854579.1600
```

**The constraint blocked the only action that would repair the account.** A
customer whose wallet is negative could not deposit money to fix it, because
the resulting balance was still below zero. The rule meant to protect them
trapped them.

The fix is to check only postings that *reduce* the balance. A wallet is
`CREDIT`-normal, so a credit increases it and can never cause an overdraft:

```sql
IF NEW.direction = v_normal THEN
    RETURN NULL;       -- this posting increases the balance
END IF;
```

Verified both ways afterwards: a ₦100 deposit into the same negative wallet now
commits, and a further ₦100 debit is still refused.
([`evidence/overdraft-defect.txt`](evidence/overdraft-defect.txt))

The general lesson is about where the bug came from. The logic was obviously
correct against a clean test fixture, and obviously wrong against real data
with pre-existing violations. **A constraint added to a populated table has two
behaviours — one for new data, one for data that already breaks it — and only
the first is usually tested.**

---

## 8. Phase 5 — Read phenomena

PostgreSQL never permits dirty reads at any isolation level, so the classic
four-phenomena table does not map onto it directly. What can be demonstrated is
the difference between the levels that are available.

| | first read | second read | |
|---|---|---|---|
| **READ COMMITTED** | 50,000.00 | **45,000.00** | Non-repeatable read: a concurrent commit is visible mid-transaction |
| **REPEATABLE READ** | 50,000.00 | **50,000.00** | Snapshot stable; the write exists but is not in this transaction's view |
| **Phantom rows (RC)** | 18 rows | **19 rows** | A new row appeared matching the same predicate |

The practical consequence for a payment platform: a reconciliation report run
at `READ COMMITTED` can produce internally inconsistent totals, because
different statements in the same report see different states of the ledger.
Reports therefore belong at `REPEATABLE READ` — one snapshot, one coherent
picture — while the derived balance used for authorisation specifically needs
the *latest* state, under a lock.

---

## 9. Phase 6 — Deadlock

A transfers to B while B transfers to A. Each locks its own wallet first, then
reaches for the other.

```
A| NOTICE:  locked A
A| NOTICE:  reaching for B...
A| ERROR:  deadlock detected
A| DETAIL:  Process 391 waits for ShareLock on transaction 1048; blocked by process 393.
A|          Process 393 waits for ShareLock on transaction 1047; blocked by process 391.
```

PostgreSQL detected the cycle and aborted one transaction with `SQLSTATE 40P01`.

### The fix is ordering, not timeouts

A longer lock timeout would not help: neither transaction can ever proceed, so
waiting longer only delays the inevitable abort. The cure is a **consistent
lock ordering**. Every writer takes locks in ascending `account_id` order,
whichever direction the money is moving:

```
A| NOTICE:  locked account 5511 (ascending order)
A| NOTICE:  locked account 5512 (ascending order)
B| NOTICE:  locked account 5511 (ascending order)
B| NOTICE:  locked account 5512 (ascending order)
```

Both succeed. A cycle becomes structurally impossible, because no session ever
holds a higher id while waiting for a lower one. This is implemented in
`fn_lock_accounts`, which every money-moving function calls.

---

## 10. Verification of the final implementation

[`safe-transfer.sql`](safe-transfer.sql) combines the lock (the control), the
ascending lock order (deadlock prevention) and the deferred constraint (the
backstop). Re-tested under the conditions that defeated every weaker approach:

| test | result |
|---|---|
| The original race, staggered | ✅ one succeeds, one rejected cleanly; balance ₦15,000 |
| **Simultaneous commits — the case that defeated Phase 2B** | ✅ one succeeds; balance ₦15,000 |
| **Five** concurrent ₦35,000 withdrawals on one ₦50,000 wallet | ✅ one succeeds, **four rejected**; balance ₦15,000 |
| Opposing transfers that deadlocked in Phase 6 | ✅ both succeed, no deadlock |
| Withdrawal of ₦999,999 | ✅ clean rejection, balance unchanged |
| Ledger integrity afterwards | ✅ NGN and USD both BALANCED |

([`evidence/safe-transfer-verification.txt`](evidence/safe-transfer-verification.txt))

---

## 11. ACID, as demonstrated rather than defined

| property | where it appears |
|---|---|
| **Atomicity** | Phase 0: rollback leaves no trace; savepoint discards part of a transaction. Phase 1: both postings of a withdrawal commit together or not at all |
| **Consistency** | Portfolio 1's constraints held throughout every phase, including the one that produced a ₦20,000 overdraft — which is exactly why consistency in the ACID sense is not the same as business correctness |
| **Isolation** | Phase 5's three levels; Phase 2B shows what insufficient isolation costs; Phase 4 shows the strongest level |
| **Durability** | Implicit here: every committed result survived the server restarts in the Portfolio 2 benchmark runs |

The most useful thing this activity taught me is how narrow the "C" in ACID
actually is. It means *the declared constraints are satisfied* — nothing more.
In Phase 1 every declared constraint was satisfied and the result was still
wrong, because the rule that mattered had not been declared, and could not have
been enforced by declaration alone.

---

## 12. Summary

| phase | control | outcome |
|---|---|---|
| 1 | None | ❌ Overdraft of ₦20,000 |
| 2A | Deferred constraint, staggered | ✅ Rejected — *by luck of timing* |
| 2B | Deferred constraint, simultaneous | ❌ Overdraft of ₦20,000 |
| 3 | `SELECT ... FOR UPDATE` | ✅ Correct, deterministic |
| 4 | `SERIALIZABLE` | ✅ Correct, via `SQLSTATE 40001` |
| 6A | Opposing locks, no ordering | ❌ Deadlock, `SQLSTATE 40P01` |
| 6B | Ascending lock order | ✅ Both succeed |
| Final | Lock + ordering + constraint | ✅ Correct under all of the above |

### What I would not have predicted

1. **The deferred constraint worked, then didn't, with no code change.** Phase
   2A and 2B differ only in a 0.4-second stagger. Had I tested once I would
   have shipped it.
2. **Double-entry integrity survived the overdraft intact.** The invariant I
   spent Portfolio 1 enforcing is orthogonal to the failure Portfolio 3 is
   about.
3. **My own fix had a bug that only real data exposed.** The overdraft rule was
   correct against a clean fixture and trapped 2,087 customers against the
   actual dataset.
