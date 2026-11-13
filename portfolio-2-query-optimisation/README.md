# Portfolio 2 — Query Processing and Optimisation

**MIT 8103 — Advanced Database Systems | Continuous Assessment (7 marks)**
**Student:** Biliaminu Abdulfarid (301918844)
**Case study:** KineticsPay — Digital Payment and Wallet Management Platform
**DBMS:** PostgreSQL 16.15

---

## What this activity delivers

| Required evidence | Where it is |
|---|---|
| SQL queries | [`queries.sql`](queries.sql) — eight analytical queries |
| Query results | [`evidence/query-results.txt`](evidence/query-results.txt) |
| Execution plans | [`execution-plans/`](execution-plans/) — seven experiments |
| Indexing / optimisation evidence | [`indexes.sql`](indexes.sql) |
| Performance analysis | [`performance-analysis.md`](performance-analysis.md) |
| Environment record | [`evidence/environment.txt`](evidence/environment.txt) |

Portfolio 1 is **unchanged**. This activity builds on `schema.sql` and
`seed.sql` exactly as they were frozen.

---

## Headline results

| # | Experiment | Result |
|---|---|---|
| 1 | Sequential vs index scan | **16× faster** warm (25.5 ms → 1.55 ms), 7.6× fewer buffers |
| 2 | Composite vs single-column | **5.1× faster** (1.44 ms → 0.28 ms); `Sort` node eliminated |
| 3 | Selectivity | Crossover found at **21.9% → 35.3%**, far later than expected |
| 4 | Pagination | Keyset **~160× faster** than `OFFSET` at depth 50,000, and flat |
| 5 | Derived vs materialised balance | **344× read win** against measurable staleness and ~400 ms refresh |
| 6 | Index write overhead | **5.9× slower** inserts; indexes are 123.7% of heap size |
| 7 | Deliberately unhelpful index | Ignored entirely at `n_distinct = 2`; useful only as a trailing column |

---

## The dataset

528,647 ledger entries across 250,010 transactions, 5,510 accounts and 5,006
customers, spanning nine months.

**Deliberately not uniform.** A uniform half-million rows would have made every
experiment meaningless: identical selectivity everywhere means the planner's
decision never changes. [`generate_data.py`](generate_data.py) produces a power
law instead —

| | postings | % of table |
|---|---|---|
| Busiest wallet | 56,297 | 10.65% |
| Bank settlement account | 115,724 | 21.89% |
| Median wallet | 8 | 0.0015% |
| Quietest wallet | 1 | 0.0002% |

— with the top 1% of wallets holding 63.7% of all postings, log-normal amounts,
skewed statuses, and business-hour and weekday timestamp bias. `random.seed(8103)`
is fixed, so re-running produces byte-identical output.

---

## How to run it

```bash
# 1. Build the Portfolio 1 base (unchanged)
createdb kineticspay
psql -d kineticspay -f ../portfolio-1-database-design/schema.sql
psql -d kineticspay -f ../portfolio-1-database-design/seed.sql

# 2. Generate and load the benchmark dataset (~1 min to generate)
python3 generate_data.py --out ./data
psql -d kineticspay -f load_data.sql

# 3. Run the seven experiments (~3 min; restarts the server twice)
./run-benchmarks.sh

# 4. Run the analytical queries
psql -d kineticspay -f queries.sql

# 5. Apply the recommended index set
psql -d kineticspay -f indexes.sql
```

---

## How it was measured

- **Three warm runs** per measured query; reported figures are medians.
- **A cold run after a server restart** in Experiment 1, so disk reads are
  distinguishable from shared-buffer hits. The same indexed query is 3.8×
  slower on its first execution.
- **`EXPLAIN (ANALYZE, BUFFERS)`** throughout. Buffer counts are quoted
  alongside timings because they are hardware-independent — on a shared
  container, how many 8 KB pages the engine touched is better evidence than
  milliseconds.
- **`VACUUM ANALYZE`** after loading. Without current statistics the planner
  makes poor choices for reasons unrelated to indexing, which would invalidate
  every experiment.

### Bulk loading and why the triggers were suspended

Portfolio 1 attached four integrity triggers, two of them deferred constraint
triggers that run a subquery per row at commit. For 528,647 rows that would be
528,647 aggregate queries.

The triggers are therefore disabled for the `COPY` and re-enabled immediately
afterwards — which means the loaded data is unvalidated at that moment. So
[`load_data.sql`](load_data.sql) §6 re-checks **every invariant the triggers
would have enforced**, against the whole table: trial balance per currency,
per-transaction balance, status-versus-postings consistency, currency
precision, non-positive amounts, currency mismatches, and that the append-only
protection is active again afterwards. All pass.
([`evidence/load-output.txt`](evidence/load-output.txt))

One subtlety found doing this: `ALTER TABLE ... ENABLE TRIGGER USER` resets
`ENABLE ALWAYS` triggers to ordinary enabled state, silently undoing the
replica-mode protection added in Portfolio 1. The load script reinstates it
explicitly, and validation V8 confirms it.

---

## A defect found in my own experiment

Experiment 4's keyset cursor used `posted_at` alone. That is **wrong** when two
postings share a timestamp — and in this schema they structurally do, because
both sides of a transfer are written with the same `settled_at`. The dataset
contains 4 colliding `(account_id, posted_at)` groups, the worst holding 6 rows.

Demonstrated: on that account the broken cursor skipped all six tied rows and
jumped to a row twelve days earlier. The fix is a row-value comparison with a
unique tie-breaker, `(posted_at, entry_id) < (:ts, :id)`, measured at 0.41 ms
median — still ~134× faster than `OFFSET`, and now correct.

The original query was fast and wrong, which is the worse of the two failure
modes.

## Two findings I did not expect

**The planner never chose a sequential scan, even at 21.89% selectivity.** I
expected an index to lose somewhere around 5–10% of a table. PostgreSQL has a
middle option — the **Bitmap Heap Scan** — which collects matching row
locations from the index, sorts them into physical page order, then reads the
heap in a mostly sequential sweep. Forcing a plain index scan at that
selectivity cost 63.0 ms against 33.2 ms for the bitmap plan, so the planner
was right. The true crossover sits between **21.9% and 35.3%**.

**`idx_scan` cannot be read naively.** Experiment 7 recorded `idx_scan = 0` for
the deliberately unhelpful index, but later in the same session the counter
read 58 — which looks like a contradiction. It is not: the counter is
cumulative, increments once per *parallel worker*, and includes plans forced
with `enable_seqscan = off` in Experiment 3B. Re-running that forced query
moved it from 58 to 61. Documented in
[`performance-analysis.md`](performance-analysis.md) §8.

---

## The balance question from Portfolio 1, answered

`normalisation.md` §7 promised that the cost of deriving balances rather than
storing them would be measured, not assumed. Experiment 5:

| | derived | materialised view |
|---|---|---|
| One busy account | 41.3 ms | 0.12 ms |
| All 5,510 accounts | 364.8 ms | 1.05 ms |
| Correct after a new posting | ✅ immediately | ❌ stale by exactly the posting |

Refresh costs ~400 ms; storage overhead is 2.6% of the ledger.

**The Portfolio 1 decision stands, with a qualification.** The two are not
substitutes — they answer different questions. Displaying a balance in an app
can read the materialised view, because a few seconds of staleness is invisible
and costs 344× less. Authorising a debit cannot.

But reading the ledger is **necessary and not sufficient**, and an earlier draft
of this README overstated it. Two concurrent withdrawals can each read a
perfectly fresh ₦50,000 balance, each conclude ₦35,000 is affordable, and both
commit — the balance was never stale, the *check* was unserialised. Freshness
and concurrency control are independent problems and this activity only
addressed the first. The second is Portfolio 3.

---

## Files

```
portfolio-2-query-optimisation/
├── README.md                   this file
├── generate_data.py            fixed-seed, power-law dataset generator
├── load_data.sql               bulk load + full post-load validation
├── run-benchmarks.sh           the seven experiments
├── queries.sql                 eight analytical queries
├── indexes.sql                 recommended index set, with rejected candidates
├── performance-analysis.md     full analysis and interpretation
├── execution-plans/
│   ├── exp1-seqscan-vs-index.txt
│   ├── exp2-composite-index.txt
│   ├── exp3-selectivity.txt
│   ├── exp4-pagination.txt
│   ├── exp5-balance-vs-matview.txt
│   ├── exp6-write-overhead.txt
│   └── exp7-unhelpful-index.txt
└── evidence/
    ├── environment.txt         PostgreSQL version, planner settings, host
    ├── generation-summary.txt  dataset shape and skew check
    ├── load-output.txt         load timings and 10 validation checks
    ├── query-results.txt       output of all eight analytical queries
    └── index-set.txt           final indexes with sizes and usage counts
```

`data/` holds the generated CSVs (73 MB) and is gitignored — it is
reproducible from `generate_data.py` with the fixed seed.

---

## Carried forward

| To | What |
|---|---|
| Portfolio 3 | The concurrency question this activity could not answer: two simultaneous withdrawals against one balance. The schema still has no overdraft check, so the race is reproducible before the fix |
| Portfolio 5 | `idx_le_account_posted` is the index a sharded deployment would need to replicate per shard; the 123.7% index-to-heap ratio is a real cost in a distributed setup |
| Future work | Periodic balance snapshots — bounding the aggregation without making the cached figure authoritative |
