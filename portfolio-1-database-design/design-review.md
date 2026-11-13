# Design Review — Portfolio 1

**MIT 8103 — Advanced Database Systems**
**Student:** Biliaminu Abdulfarid (301918844)
**Date:** 13 November 2026

---

## Why this document exists

The first version of this schema passed all twelve of its own integrity tests.
That is weaker evidence than it looks: a test suite written alongside a schema
tends to test what the author already thought of.

This review deliberately attacked the design looking for states the database
*should* reject but did not. Four probes were run against the live database.
**All four found a real hole.** Raw output is in
[`evidence/design-review-probes.txt`](evidence/design-review-probes.txt).

---

## Gap 1 — A settled transaction could post nothing

**Severity: high**

`trg_ledger_entries_balanced` is an `AFTER INSERT` trigger on `ledger_entries`.
If no entry is ever inserted, the trigger never fires. A transaction row with
`status = 'COMPLETED'` and zero postings therefore committed without complaint.

This is the flaw that matters most, because the broken state is invisible: a
payment is recorded as settled, no money moved, and reconciliation against the
partner bank cannot detect it — there is no posting to reconcile.

**Fix.** A second deferred constraint trigger, this time on `transactions`
rather than on `ledger_entries`, so the check runs even when no posting is
attempted:

```sql
CREATE CONSTRAINT TRIGGER trg_transactions_posting_matches_status
    AFTER INSERT OR UPDATE ON transactions
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION fn_assert_transaction_posted();
```

The function also enforces the converse, which the original schema never
stated: a `PENDING` or `FAILED` transaction **must not** have posted to the
ledger. A failed transfer that moved value is as serious as a completed one
that did not.

**General lesson.** A trigger guards the table it sits on. If the invariant is
*"every transaction in state X has property Y"*, the trigger belongs on
`transactions`, not on the child table — otherwise the empty case escapes.

---

## Gap 2 — Append-only was bypassable

**Severity: high**

PostgreSQL suppresses ordinary user triggers when a session sets
`session_replication_role = 'replica'`. Two statements were enough to rewrite a
committed financial posting:

```sql
SET session_replication_role = 'replica';
UPDATE ledger_entries SET amount = 999999.00 WHERE entry_id = 1;   -- UPDATE 1
```

The "immutable ledger" claim in the original documentation was overstated.

**Fix, in two layers.**

1. `ALTER TABLE ledger_entries ENABLE ALWAYS TRIGGER trg_ledger_entries_no_update;`
   — `ENABLE ALWAYS` makes the trigger fire in replica mode too.

2. A least-privilege role. `kineticspay_app` is granted `SELECT` and `INSERT`
   on `ledger_entries` and is never granted `UPDATE` or `DELETE` at all.

The second layer matters more than the first. **A trigger is a control against
mistakes, not against privilege**: the table owner or any superuser can disable
or drop it. The durable control is that the application never connects as the
owner, so the restriction survives even if every trigger were dropped. Test 19
verifies the grants directly rather than taking them on trust.

**Honest limitation.** A superuser can still do anything, including re-granting
privileges. Nothing inside the database prevents that. Beyond this point the
controls are operational — separation of duties, audited administrative access,
write-ahead log archiving to immutable storage — and are out of scope for this
portfolio. Claiming otherwise would be false.

---

## Gap 3 — Currency precision was unenforced

**Severity: medium**

`amount` is `NUMERIC(20,4)` while NGN declares `minor_unit = 2`. Nothing
connected the two, so a posting of `100.00019` was silently rounded to
`100.0002` and stored. The resulting balance cannot be settled: no payment rail
moves two ten-thousandths of a naira.

The four decimal places exist for intermediate percentage-fee arithmetic, not
for stored postings — but the schema never said so, and therefore never
enforced it.

**Fix.** `trg_ledger_entries_amount_precision` validates each posting against
its own currency's `minor_unit`, which makes the `currencies.minor_unit` column
load-bearing instead of decorative.

---

## Gap 4 — A reversal need not relate to what it reverses

**Severity: high**

`transactions_reversal_chk` only required that a `REVERSAL` point at *some*
earlier transaction. Nothing tied the reversal's postings to the original's. A
"reversal" of a ₦50,000 deposit was successfully committed that debited an
unrelated customer by ₦7.00 — and the original was never marked `REVERSED`.

This undermines the whole append-only design. Reversal is the schema's only
sanctioned route for correcting the ledger. If a reversal need not mirror what
it reverses, any balance can be altered by posting a "reversal" of an unrelated
transaction, and immutability becomes decorative.

**Fix.** `trg_ledger_entries_reversal_mirrors` requires that:

- the original transaction is marked `REVERSED`, and
- every original posting has exactly one counterpart in the reversal with the
  same account, the same amount and the **opposite** direction, and vice versa.

The comparison is a `FULL OUTER JOIN` so that an orphan on either side is
caught — a reversal that omits a posting fails just as a reversal that invents
one does.

Test 18 confirms that a *correctly* mirrored reversal is still accepted, so the
constraint has not simply banned reversals.

---

## What the review did not change

Three criticisms raised during review were considered and deliberately **not**
acted on in Portfolio 1:

| Raised | Response |
|---|---|
| Transfers need sufficient-balance checks and row locking | Correct, and that is **Portfolio 3**. The schema deliberately has no overdraft check yet, so the lost-update and double-spend race is reproducible before the fix. Adding it here would remove the demonstration |
| The balance view must handle debit-normal and credit-normal accounts | Already handled via `accounts.normal_balance`, and already proven: Test 2's trial balance nets to zero across asset and liability accounts, which it could not do if the signs were wrong |
| The derived-balance query will not scale | True, and it is measured rather than assumed. Portfolio 2 profiles it at volume against materialised alternatives and lets the execution plans decide |

---

## Revised test coverage

| # | Assertion | Result |
|---|---|---|
| 1–3 | Balances derive correctly; trial balance nets to zero; each transaction balances | ✅ pass |
| 4 | Unbalanced transaction rejected | ✅ rejected |
| 5 | Single-sided posting rejected | ✅ rejected |
| 6 | Cross-currency posting rejected | ✅ rejected |
| 7–8 | Ledger `UPDATE` / `DELETE` rejected | ✅ rejected |
| 9 | Internal account with an owner rejected | ✅ rejected |
| 10 | Duplicate wallet per customer and currency rejected | ✅ rejected |
| 11 | Negative posting amount rejected | ✅ rejected |
| 12 | Reversal leaves original and correction intact, net zero | ✅ pass |
| **13** | **COMPLETED transaction with no postings rejected** | ✅ rejected |
| **14** | **FAILED transaction that posted value rejected** | ✅ rejected |
| **15** | **Replica-mode bypass of append-only rejected** | ✅ rejected |
| **16** | **Sub-minor-unit precision rejected** | ✅ rejected |
| **17** | **Non-mirroring reversal rejected** | ✅ rejected |
| **18** | **Correctly mirrored reversal accepted** | ✅ pass |
| **19** | **`kineticspay_app` holds no UPDATE/DELETE on the ledger** | ✅ verified |

Nineteen tests, fourteen of them negative. Captured output:
[`evidence/verify-output.txt`](evidence/verify-output.txt).

---

## Reflection

The useful finding here is not any individual bug. It is that **a schema's own
test suite is not evidence that the schema is correct** — it is evidence that
the author's assumptions are self-consistent. Every one of these four gaps sat
underneath a passing test run.

What exposed them was asking a different question. Not *"does the valid case
work?"* but *"what invalid state can I construct that the database will
accept?"* Gap 1 in particular came from noticing where the trigger was
*attached* rather than what it checked: an `AFTER INSERT` trigger on a child
table cannot see a parent row that has no children.
