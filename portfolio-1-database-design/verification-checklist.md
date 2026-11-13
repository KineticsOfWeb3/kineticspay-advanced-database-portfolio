# Portfolio 1 — Personal Verification Checklist

**Student:** Biliaminu Abdulfarid (301918844)

Portfolio 1 is **frozen** as a deliverable. Nothing further will be added to it;
remaining effort goes to Portfolios 2–5.

What is not yet done is *my own* verification. The schema was built and tested
against a PostgreSQL 16 instance during development, but Section 8 of the
assessment brief makes progressive evidence and personal understanding the
basis of marking, and Section 10 states that submitting output without
demonstrating understanding will not receive full marks.

This checklist is the gap between "the code works" and "I can defend it".

---

## 1. Run it on my own machine

```bash
createdb kineticspay
psql -d kineticspay -f schema.sql
psql -d kineticspay -f seed.sql
psql -d kineticspay -f verify.sql | tee evidence/verify-output-local.txt
```

- [ ] Schema builds with no errors
- [ ] Seed loads with no errors
- [ ] All 21 tests produce the expected result
- [ ] Output saved and screenshotted on my own machine

Expected: **15 errors** in the output. Every one is a deliberate rejection. A
run with fewer errors means a constraint is missing; a run with more means
something genuinely broke.

## 2. Confirm the four reviewed gaps stay closed

Re-run the probes in `evidence/design-review-probes.txt` against the hardened
schema and confirm each is now refused:

- [ ] Probe A — `COMPLETED` transaction with no postings → rejected (Test 13)
- [ ] Probe B — `session_replication_role = 'replica'` bypass → rejected (Test 15)
- [ ] Probe C — sub-minor-unit amount → rejected (Test 16)
- [ ] Probe D — reversal that does not mirror its original → rejected (Test 17)

## 3. Break something on purpose

Understanding comes from watching a control fail, not from reading that it
exists. For each, make the change, re-run the relevant test, confirm it now
passes when it should fail, then revert:

- [ ] Remove `DEFERRABLE INITIALLY DEFERRED` from `trg_ledger_entries_balanced`
      → every legitimate transfer should now fail, because the trigger fires
      after the first posting when only one side exists
- [ ] Remove `ENABLE ALWAYS` from `trg_ledger_entries_no_update`
      → Test 15 should pass when it ought to fail
- [ ] Drop `trg_transactions_posting_matches_status`
      → Test 13 should pass when it ought to fail

## 4. Check the diagram against the real database

```sql
\d+ accounts
\d+ ledger_entries
\d+ transactions
```

- [ ] Every table, column and foreign key in the ERD exists in the database
- [ ] The composite FK on `ledger_entries` appears in `\d ledger_entries`
- [ ] No column exists in the database that is missing from the ERD

## 5. Read the documents critically

- [ ] `normalisation.md` — do I agree with the 1NF → BCNF reasoning, and can I
      restate the functional dependencies without looking?
- [ ] `design-review.md` — can I explain each gap and its fix in my own words?
- [ ] Rewrite the prose in my own voice where it does not sound like me

## 6. Verify permissions and reversal behaviour directly

```sql
SELECT privilege_type,
       has_table_privilege('kineticspay_app','ledger_entries',privilege_type)
FROM (VALUES ('SELECT'),('INSERT'),('UPDATE'),('DELETE')) AS p(privilege_type);
```

- [ ] `UPDATE` and `DELETE` return `false`
- [ ] Test 18 — a correctly mirrored reversal is still accepted
- [ ] Test 20 — a second reversal of the same original is refused

## 7. Commit my own review work

- [ ] Commits recording what I verified, what I broke and what I changed
- [ ] No manufactured history — only commits for work actually done

## 8. Publish

- [ ] Private GitHub repository created
- [ ] Assessor added as a collaborator and access confirmed
- [ ] Repository pushed and the link verified from a logged-out browser

---

## Questions I should be able to answer without notes

1. Why is the balance trigger deferred, and what happens if it is not?
2. Why does `ledger_entries` carry a composite foreign key when `account_id`
   is already unique?
3. Why is there no `balance` column, and what does that cost?
4. Why do customer wallets and internal control accounts share one table?
5. Why is `amount` always positive, with `direction` carrying the sign?
6. Why does a trigger alone not make the ledger immutable?
7. Why was the `COMPLETED`-with-no-postings gap invisible to the first twelve
   tests?
8. Why does a transfer with a fee have three postings rather than two?

---

## Deliberately out of scope for Portfolio 1

| Item | Where it belongs |
|---|---|
| Sufficient-balance check and row locking on transfers | Portfolio 3 — the race must be reproducible before it is fixed |
| Concurrent withdrawal test across two sessions | Portfolio 3 |
| Secondary indexes | Portfolio 2 — the unindexed baseline is deliberate |
| Materialised balance vs derived balance at scale | Portfolio 2 — decided by measurement |
| Partial reversals | Not supported; `transactions_single_reversal_uq` enforces one reversal per original, documented as a design limit |
