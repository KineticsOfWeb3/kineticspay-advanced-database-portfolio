# Performance Analysis

**MIT 8103 — Advanced Database Systems | Portfolio 2**
**Student:** Biliaminu Abdulfarid (301918844)
**Case study:** KineticsPay — Digital Payment and Wallet Management Platform
**Dataset:** 528,647 ledger entries · 250,010 transactions · 5,510 accounts · 5,006 customers

---

## 1. Method

Seven experiments were run against PostgreSQL 16.15 on the dataset described in
[`generate_data.py`](generate_data.py). Every measured query was run **three
times warm**, and Experiment 1 additionally includes a **cold run taken
immediately after a server restart**, so cache effects are visible rather than
assumed.

All figures below are medians of three runs, taken from
[`execution-plans/`](execution-plans/). Buffer counts are quoted alongside
timings because buffers are hardware-independent: on a shared container, *how
many 8 KB pages the engine touched* is more trustworthy evidence than
milliseconds.

**Why the dataset is skewed.** A uniform 500,000 rows would have made these
experiments meaningless — every lookup would have identical selectivity and the
planner's decision would never change. Transaction volume per wallet follows a
power law instead:

| | postings | % of table |
|---|---|---|
| Busiest wallet (2415) | 56,297 | 10.65% |
| Bank settlement account (1) | 115,724 | 21.89% |
| Median wallet | 8 | 0.0015% |
| Quiet wallet (13) | 6 | 0.0011% |

The top 1% of wallets hold 63.7% of all postings. That spread is what makes
Experiment 3 possible.

---

## 2. Experiment 1 — Sequential scan versus index scan

Query: every posting for one mid-volume wallet (694 rows, 0.13% of the table).

| | plan node | cold | warm (median) | buffers |
|---|---|---|---|---|
| No secondary index | Parallel Seq Scan | 28.9 ms | **25.5 ms** | 5,361 shared |
| `idx_le_account` | Bitmap Heap Scan → Bitmap Index Scan | 5.8 ms | **1.55 ms** | 703 shared |

**~16× faster warm, ~5× cold, and 7.6× fewer buffers touched.**

The buffer count is the real story. Without the index the engine reads the
entire 42 MB heap to find 694 rows. With it, the bitmap index scan identifies
the matching pages first and the heap scan touches only those.

The cold/warm gap also shows why single measurements mislead: the same indexed
query is 3.8× slower on its first execution, purely because the pages are not
yet in shared buffers. Index creation cost 291.8 ms and 3,736 kB.

---

## 3. Experiment 2 — Single-column versus composite index

Query: the wallet-statement query a mobile app actually issues — most recent 50
postings, newest first.

| index available | plan | median |
|---|---|---|
| `(account_id)` | Bitmap Heap Scan → **Sort** → Limit | 1.44 ms |
| `(account_id, posted_at DESC)` | **Index Scan** → Limit | **0.28 ms** |

**5.1× faster, and the `Sort` node disappears entirely.**

The single-column index finds the right rows but the engine must then sort all
694 of them to answer `ORDER BY posted_at DESC LIMIT 50`. The composite index
stores them *already in that order*, so the engine walks the index, takes the
first 50 and stops. It never reads row 51.

The same composite index also served a date-range predicate at 0.42 ms.

### Where the composite index does not help

```sql
SELECT COUNT(*) FROM ledger_entries WHERE posted_at >= '2026-10-28';
```

→ **Parallel Seq Scan, 33.5 ms.** The index is ordered by `account_id` first.
With no predicate on the leading column there is no contiguous range to scan,
so the index is useless here. A B-tree composite index is usable only on a
**leading prefix** of its columns — which is why column order in a composite
index is a design decision, not an arbitrary one.

---

## 4. Experiment 3 — Selectivity and the planner's crossover

The same query shape against accounts of very different volume, with every
index already in place.

| account | matching rows | % of table | plan chosen | median |
|---|---|---|---|---|
| 13 | 6 | 0.001% | Bitmap Heap Scan | 0.15 ms |
| 3547 | 694 | 0.13% | Bitmap Heap Scan | 1.07 ms |
| 2415 | 56,297 | 10.65% | Bitmap Heap Scan | 21.5 ms |
| 1 | 115,724 | 21.89% | Bitmap Heap Scan | 33.2 ms |

### The finding I did not expect

**The planner never chose a sequential scan — not even at 21.89% selectivity.**
My initial hypothesis, that an index becomes unattractive somewhere around 5–10%
of a table, was wrong, and the reason is instructive.

PostgreSQL has a middle option between Index Scan and Seq Scan: the **Bitmap
Heap Scan**. It collects all matching row locations from the index, sorts them
into *physical page order*, and then reads the heap in a mostly sequential
sweep. It therefore avoids the random I/O that makes a plain Index Scan
collapse at scale, and stays viable far longer.

Forcing a plain Index Scan at 21.89% confirms it: **63.0 ms**, against 33.2 ms
for the bitmap plan and ~40 ms for a sequential scan. The planner was right.

So I widened the predicate to find the true crossover:

| selectivity | plan chosen | median |
|---|---|---|
| 21.9% | Bitmap Heap Scan | 40.1 ms |
| **35.3%** | **Parallel Seq Scan** | 40.3 ms |
| 50.0% | Parallel Seq Scan | 51.1 ms |
| 77.5% | Parallel Seq Scan | 75.3 ms |

**The crossover sits between 21.9% and 35.3%** on this table and this hardware.
It is not a universal constant: it depends on `random_page_cost` (4 here),
`effective_cache_size`, row width, and physical correlation between index order
and heap order. The lesson is that the planner's cost model, not a rule of
thumb, decides — and that it is usually right.

---

## 5. Experiment 4 — Pagination depth

Statement pagination over the busiest wallet (56,297 postings), using the
composite index.

| | plan | median |
|---|---|---|
| `LIMIT 50 OFFSET 0` | Index Scan | 0.31 ms |
| `LIMIT 50 OFFSET 500` | Index Scan | 2.26 ms |
| `LIMIT 50 OFFSET 5000` | Index Scan | 7.70 ms |
| `LIMIT 50 OFFSET 50000` | Bitmap Heap Scan → **Sort** | 54.4 ms |
| **Keyset at the same depth** | **Index Scan** | **0.34 ms** |

**Keyset pagination is ~160× faster at depth 50,000 — and flat.**

`OFFSET` does not skip work. The engine must walk and discard every row before
the offset, so cost grows linearly with page depth. At `OFFSET 50000` the
planner even abandoned the index: once nearly all of the account's rows must be
read anyway, a bitmap scan plus an explicit sort is cheaper than an index walk.

Keyset pagination replaces `OFFSET` with a predicate on the last row seen:

```sql
WHERE account_id = 2415 AND posted_at < :last_seen
ORDER BY posted_at DESC LIMIT 50
```

The index seeks straight to that position. Cost is identical at page 1 and page
1,000. For a transaction history that grows without bound, this is the
difference between a statement screen that stays usable and one that degrades
as a customer transacts.

---

## 6. Experiment 5 — Derived balance versus materialised view

Portfolio 1 deliberately stores no balance anywhere, and
[`normalisation.md`](../portfolio-1-database-design/normalisation.md) §7
promised the cost would be measured rather than assumed. This is that
measurement.

| query | derived from ledger | materialised view | ratio |
|---|---|---|---|
| One mid-volume account | 1.40 ms | 0.12 ms | 12× |
| One busy account (56,297 postings) | 41.3 ms | 0.12 ms | **344×** |
| All 5,510 account balances | 364.8 ms | 1.05 ms | **347×** |

Refresh cost: **383.8 ms** and **456.9 ms** (`REFRESH MATERIALIZED VIEW
CONCURRENTLY`). Storage: **2,480 kB**, against 93 MB for the ledger — 2.6%
overhead.

### The freshness cost, measured

After posting ₦5,000 to a wallet and querying both sources in the same session:

```
      source       |   balance
-------------------+--------------
 derived (view)    | 1628893.6400
 materialised view | 1623893.6400
```

The derived view is correct immediately. The materialised view is wrong by
exactly the amount of the new posting until it is refreshed.

### What I conclude

The derived-balance decision from Portfolio 1 **stands**, but it needs
qualifying rather than defending unconditionally:

- **344× is not a rounding error.** On the busiest wallet the derived balance
  takes 41 ms. At even modest concurrency, that query becomes the platform's
  bottleneck, and it gets worse every time the customer transacts, because the
  aggregate scans their entire history.
- **But the two are not substitutes.** They answer different questions. The
  derived balance is authoritative; the materialised view is a cache that is
  measurably wrong between refreshes.

So the right architecture is not one or the other:

| use | source | why |
|---|---|---|
| Authorising a debit | derived from the ledger | Must be correct. Spending money on a stale balance is how a platform permits an overdraft it never agreed to |
| Displaying a balance in the app | materialised view | A few seconds of staleness is invisible to a user and costs 344× less |
| Reconciliation and reporting | derived from the ledger | Must be reproducible from first principles |

The refresh cost (~400 ms) bounds how fresh the cache can be: refreshing every
second would consume ~40% of a core continuously. A 30-second refresh cycle
costs ~1.3% and is invisible to users.

The 2.6% storage overhead is negligible and not a factor in the decision.

**A third option** — periodic balance snapshots, so a current balance is the
last snapshot plus only the postings since — would bound the aggregation
without ever making the cached figure authoritative. It is the better long-term
answer and is noted here as future work rather than implemented, to keep this
activity within scope.

---

## 7. Experiment 6 — What indexes cost on write

Measured on a copy of the ledger structure without the Portfolio 1 triggers, so
the figures isolate index maintenance rather than trigger cost.

| inserting 100,000 rows | time | index storage |
|---|---|---|
| Unindexed table | **91.8 ms** | 0 bytes |
| Three indexes | **544.3 ms** | 7,184 kB |

**5.9× slower to write, and the indexes occupy 90% of the heap size.**

On the real ledger the position is worse: 42 MB heap against **51 MB of
indexes — 123.7% of the table itself**. Every index is paid for on every
insert, forever.

Index usage after the benchmark run:

| index | size | times used |
|---|---|---|
| `ledger_entries_tx_account_direction_uq` | 20 MB | 38 |
| `idx_le_account_posted` | 16 MB | 35 |
| `ledger_entries_pkey` | 11 MB | 1 |
| `idx_le_account` | 3,736 kB | 42 |

This reframes indexing as a trade, not an optimisation. A payment ledger is
**insert-heavy by nature** — it is append-only by design — so index maintenance
is on the hot path of every single transaction. The 5.9× write penalty is the
price of the 16× and 344× read wins elsewhere, and it is only worth paying for
indexes that are actually used.

Note that `idx_le_account` is largely redundant once
`idx_le_account_posted` exists: a composite index serves queries on its leading
prefix. Dropping it would reclaim 3.7 MB and remove one index from every
insert. It is retained here only because Experiments 1 and 2 need to compare
the two.

---

## 8. Experiment 7 — An index that does not help

Included deliberately. Showing an index that **fails** demonstrates why indexes
work in a way that a collection of successes does not.

`direction` has exactly two distinct values across 528,647 rows:

| direction | rows | % |
|---|---|---|
| CREDIT | 296,032 | 56.0% |
| DEBIT | 232,617 | 44.0% |

| | plan | median |
|---|---|---|
| Before index | Parallel Seq Scan | 48.3 ms |
| After index on `direction` | **Parallel Seq Scan** | 58.4 ms |

**The planner ignored the index entirely** — `idx_scan = 0` in
`pg_stat_user_indexes` at the point of measurement. It cost 3,600 kB of
storage and adds maintenance to every insert while returning nothing.

> **Correction, found while assembling this report.** Later in the same
> session that counter read **58**, which appears to contradict the claim
> above. It does not, and the reason is worth recording. Experiment 3B runs
> `SET enable_seqscan = off` to show what the planner was avoiding; under that
> setting PostgreSQL will use *any* index it can, including this one, as a
> `Parallel Index Only Scan`. Re-running that forced query moved the counter
> from 58 to **61** — three increments for one query, because each parallel
> worker increments separately.
>
> Two lessons. First, `idx_scan` is a **cumulative session-wide counter**, so
> it includes deliberately forced plans and counts per worker rather than per
> query — it is evidence about a workload, not about a query. Second, my
> original claim was right about the thing that matters: under normal planning
> this index is never chosen. I would have missed both if I had quoted the
> counter at the end of the run instead of at the point of measurement.

The apparent 10 ms slowdown afterwards is **run-to-run variance on a shared
container, not an effect of the index**: the plans are byte-identical. Claiming
the index made reads slower would be reading noise as signal. What it *does*
slow down is writes, which Experiment 6 measures properly.

### Why it fails

`pg_stats` gives `n_distinct = 2` for `direction`, against 2,635 for
`account_id`. A predicate matching 44% of a table cannot be served efficiently
by an index: the engine would do index work *and then* read most of the heap
anyway. This is the same principle as Experiment 3's crossover — 44% sits well
past the ~22–35% boundary found there.

### But the column is not useless

```sql
WHERE account_id = 3547 AND direction = 'DEBIT'
```

With a composite index on `(account_id, direction)`: **0.84 ms.**

`direction` is not a bad column to index — it is a bad **leading** column. As
the trailing column of a selective composite index it narrows an already-small
result set. **Selectivity is a property of the predicate as a whole, not of a
column in isolation.**

---

## 9. Summary of findings

| # | Experiment | Result |
|---|---|---|
| 1 | Sequential vs index scan | 16× faster warm, 7.6× fewer buffers |
| 2 | Composite vs single-column | 5.1× faster; `Sort` node eliminated; useless without the leading column |
| 3 | Selectivity | Crossover between 21.9% and 35.3% — much later than expected, because Bitmap Heap Scan sits between the two extremes |
| 4 | Pagination | Keyset ~160× faster than `OFFSET` at depth 50,000, and flat with depth |
| 5 | Derived vs materialised balance | 344× read win against measurable staleness and ~400 ms refresh; both are needed, for different jobs |
| 6 | Write overhead | 5.9× slower inserts; indexes are 123.7% of heap size on the real ledger |
| 7 | Unhelpful index | Ignored entirely at `n_distinct = 2`; the same column is worth 0.84 ms as the trailing half of a composite |

### What changed in my understanding

Three things I would not have predicted before measuring:

1. **A bitmap heap scan keeps an index useful far longer than I assumed.** I
   expected the index to lose around 5–10% selectivity. It held to 22%.
2. **`OFFSET` pagination degrades the plan, not just the timing.** At depth
   50,000 the planner abandoned the index altogether.
3. **Index storage exceeded table storage.** 51 MB of indexes on a 42 MB table
   made the write-side cost concrete in a way the timing alone did not.
4. **`idx_scan` cannot be read naively.** It accumulates across a session,
   counts once per parallel worker, and includes plans forced with
   `enable_seqscan = off` — so "this index was used 58 times" can be true and
   still mean the planner never chose it.

The through-line is that **every one of these is a trade, not an improvement**.
Read speed is bought with write cost and storage. Balance-query speed is bought
with freshness. The only finding with no trade-off attached is keyset
pagination, which is faster *and* cheaper — and that is because it is not an
optimisation at all, but a correction to a query pattern that was wrong to
begin with.
