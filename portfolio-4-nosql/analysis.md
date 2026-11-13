# NoSQL and Advanced Data Models — Analysis

**MIT 8103 — Advanced Database Systems | Portfolio 4**
**Student:** Biliaminu Abdulfarid (301918844)
**Case study:** KineticsPay — Digital Payment and Wallet Management Platform
**Document store:** MongoDB document model, executed against mongomock 4.3.0

---

## 1. A statement about the evidence, before anything else

A real `mongod` could not be installed in the environment this was built in.
`fastdl.mongodb.org`, `repo.mongodb.org` and GitHub release downloads are all
blocked by the network policy; `apt` has no MongoDB package.

Rather than submit a design with no execution evidence, the document model is
executed against **mongomock 4.3.0**, an in-memory implementation of the pymongo
API. What that does and does not license:

| | |
|---|---|
| ✅ Real | Documents, queries, indexes and aggregation pipelines genuinely execute. Every figure in `evidence/mongo-output.txt` is produced output |
| ✅ Portable | The same code runs unchanged against a real server — swap `mongomock.MongoClient()` for `pymongo.MongoClient(ATLAS_URI)`. Equivalent `mongosh` scripts are in [`mongosh/`](mongosh/) |
| ❌ Not evidence of performance | mongomock has no storage engine and no query planner. **Nothing here says anything about MongoDB speed**, and no timing claims are made |
| ❌ Not `$jsonSchema` | mongomock does not implement server-side validation, so validation is run with the `jsonschema` library against equivalent rules. Arguably stronger evidence: every document is checked, not only those a server rejects |
| ❌ Not transactions | No replica sets, no sessions. Section 5's transaction discussion is argued from MongoDB's documented semantics, with the untestable parts marked |

`mongosh/03-transactions.js` exists precisely to run the part that could not be
run here, on a single-node replica set or an Atlas free-tier cluster.

---

## 2. What goes in the document store, and what must not

The central design question is **not** "how do I model KineticsPay in
MongoDB". It is "which parts of KineticsPay belong in a document store at all".

| Data | Home | Why |
|---|---|---|
| **Ledger** (`ledger_entries`) | **PostgreSQL** | Double-entry invariants, multi-row atomicity, append-only enforcement. Section 5 shows what happens without them |
| **Accounts, customers** | **PostgreSQL** | Referential integrity; the lock anchor Portfolio 3 depends on |
| **Transaction events** | **MongoDB** | Sparse, schema-variable operational metadata. Section 3 |
| **Wallet snapshots** | **MongoDB** | Denormalised read model; one document serves a whole screen |

This is **polyglot persistence**, and the split is not a compromise — it is the
design. A payment platform has one body of data that must never be wrong and
another that must never be rigid, and no single engine is best at both.

---

## 3. Why these documents justify a document store

The weak version of this argument is "payment metadata is flexible". The strong
version is measurable. Field presence across the 50,000 exported events:

| field path | documents | % |
|---|---|---|
| `latency_ms` | 49,111 | 98.2% |
| `metadata.device` | 39,989 | 80.0% |
| `metadata.network` | 29,055 | 58.1% |
| `metadata.three_d_secure` | 10,934 | 21.9% |
| `metadata.risk` | 9,169 | 18.3% |
| `metadata.ussd` | 7,019 | 14.0% |
| `metadata.api` | 2,991 | 6.0% |
| `metadata.failure` | 2,632 | 5.3% |
| `metadata.compliance` | 634 | 1.3% |

**20% of documents have no `device` block at all** — USSD has no app and no
device, and an API call has a client ID instead. These are not missing values;
the concept does not exist for those channels.

The relational alternatives are all unattractive:

1. **Nullable columns on `transactions`** — roughly 25 columns, most null on
   most rows, and every new channel or risk signal is a migration against a
   250,000-row table.
2. **A side table per metadata type** — eight joins to reconstruct one event,
   and a schema change per new signal type.
3. **An EAV table** — queryable only with pain, and no type safety at all.
4. **A JSONB column in PostgreSQL** — genuinely viable, and the honest
   competitor. Postgres has GIN indexes and `->>` operators. What MongoDB adds
   is the aggregation framework over those documents, and sparse/multikey
   indexes as first-class citizens rather than bolt-ons. The gap is narrower
   than MongoDB marketing suggests, and for this workload either would work.

So the conclusion is not "relational cannot do this". It is that this
particular shape of data — high write volume, sparse heterogeneous fields,
queried analytically, with no cross-record invariants — is the one shape where
the document model is clearly comfortable and the normalised relational model
clearly is not.

---

## 4. Schema flexibility is not the absence of schema

The validator in [`mongosh/01-setup.js`](mongosh/01-setup.js) runs at
`validationLevel: "strict"`, `validationAction: "error"` — the server refuses
non-conforming writes.

Validation results across all 50,000 documents: **0 violations.** Three
deliberately invalid documents were rejected as a negative control:

| document | outcome |
|---|---|
| `_id` of `NOT-A-REF` | ✅ rejected — fails `^KP-[0-9]{4}-[0-9]{6}$` |
| `type` of `TELEPORT` | ✅ rejected — not in the enum |
| `amount: -5.0`, `channel: SMOKE_SIGNAL` | ✅ rejected — 2 violations |

The point being that "schema-less" is a misnomer that causes real damage. A
payment event collection with no rules becomes unqueryable within a year,
because six teams will have written six spellings of the same field.

### Indexing, and a connection back to Portfolio 2

`risk_action` is a **sparse** index: only 18% of events carry a risk block, so
the index contains only those documents.

That is the same reasoning as the **partial** index on
`transactions(status) WHERE status IN ('PENDING','FAILED')` in Portfolio 2's
`indexes.sql`, reached from the opposite direction. There, Experiment 7 showed
that indexing a low-cardinality column across a whole table is useless, and the
fix was to restrict the index to the rare values. Here the index is naturally
restricted, because most documents simply lack the field.

The underlying rule is the same in both engines: **an index is worth having
when it is small relative to the table and selective for the query** — and the
way to achieve that is usually to exclude the common case rather than to index
it.

---

## 5. Concurrency: what the document model does and does not give

### 5.1 Single-document atomicity is genuinely strong

```
update_one({_id, balance: {$gte: 35000}}, {$inc: {balance: -35000}})

withdrawal 1: matched=1 modified=1 -> APPLIED, balance now 15,000.00
withdrawal 2: matched=0 modified=0 -> REFUSED (guard failed), balance now 15,000.00
```

This is the idiomatic MongoDB answer to the Portfolio 3 race, and it is a good
one. The filter and the update are a single atomic operation on a single
document: there is no window between the read and the write, because **there is
no separate read**. A competing writer cannot slip in, because nothing to slip
into exists.

Compare the shapes:

| | PostgreSQL (Portfolio 3) | MongoDB |
|---|---|---|
| Pattern | `SELECT ... FOR UPDATE`, read, decide, post | `update_one(filter+guard, $inc)` |
| Round trips | Several, inside one transaction | One |
| What serialises | An explicit lock on a lock-anchor row | The document write itself |
| Failure mode | Lock contention, waiting | `modified_count = 0`, retry or report |
| Scope | Anything within the transaction | **One document only** |

### 5.2 Where it stops

A transfer touches two documents. Executed:

```
before: A=50,000.00  B=10,000.00  total=60,000.00
step 1 debit A 20,000 : modified=1
step 2 credit B 20,000: modified=0  <-- FAILED (recipient missing)
after : A=30,000.00  B=10,000.00  total=40,000.00
NGN 20,000.00 HAS BEEN DESTROYED.
```

Step 1 committed. Step 2 failed. There is no enclosing transaction, so nothing
rolls step 1 back and the money is simply gone.

**The relational ledger cannot reach this state.** `trg_ledger_entries_balanced`
from Portfolio 1 rejects, at commit, any transaction whose debits and credits
do not sum to zero. The guarantee is not that the application is careful — it
is that the state is unrepresentable.

### 5.3 Stated accurately: MongoDB does have transactions

It would be wrong to say MongoDB has no multi-document transactions. Since 4.0
it supports multi-document ACID transactions on replica sets, and since 4.2
across sharded clusters. The accurate claims are narrower:

- **Single-document atomicity is the default and the design target.**
  Multi-document transactions are an escape hatch the data model is meant to
  make unnecessary.
- **They require a replica set.** A standalone `mongod` rejects
  `startTransaction()` outright.
- **They carry real cost** — a 60-second default runtime limit, WiredTiger
  cache pressure, and under contention a `TransientTransactionError` the
  application must retry. That is the **same retry obligation** `SERIALIZABLE`
  imposed in Portfolio 3, in a different engine.
- **mongomock implements none of it**, so this activity cannot demonstrate it.
  `mongosh/03-transactions.js` does, on a replica set.

The design conclusion survives either way. If a workload needs multi-document
transactions constantly, the document model is being used against its grain.
**A ledger is exactly such a workload**, which is why KineticsPay keeps it in
PostgreSQL.

---

## 6. Embedding versus referencing

| | mean doc | max doc | reads for the home screen |
|---|---|---|---|
| `wallet_snapshots` (embedded recent activity) | 829 B | 902 B | **1** |
| `transaction_events` (referenced) | 767 B | 963 B | 1 query, N documents |

The embedded read model collapses what the relational schema needs three
relations for — the `wallets` view aggregating `ledger_entries`, a join to
`customers`, and a top-5 postings lookup — into a single document fetched by
`_id`.

### Why `recent_activity` is capped at 5

The busiest wallet has **56,297 postings**. Embedding all of them would produce
a document of roughly **6.4 MB**, against MongoDB's hard **16 MB** limit — and
every balance read would transfer the lot.

This is the unbounded-array anti-pattern, and it is the single most common way
a document model goes wrong. The rule applied here: **embed what is read
together and is bounded; reference what grows.**

It also connects directly to Portfolio 2. The materialised view there was 344×
faster than deriving balances from the ledger, at the cost of staleness.
`wallet_snapshots` is the same trade in a different engine — a precomputed read
model, fast, and wrong the moment the ledger moves. The authority stays in
PostgreSQL in both cases.

---

## 7. A modelling gap this activity exposed

Pipeline 4.3 ranks decline reasons:

```
{"n": 458, "retryable": 280, "value_lost": 0.0, "_id": "CARD_EXPIRED"}
{"n": 457, "retryable": 247, "value_lost": 0.0, "_id": "ISSUER_UNAVAILABLE"}
{"n": 455, "retryable": 260, "value_lost": 0.0, "_id": "SUSPECTED_FRAUD"}
```

`value_lost` is **0.00 for every decline reason**, which is obviously wrong as
a business answer — those were real attempted payments.

It is not a bug in the pipeline. It follows from a correct decision taken in
Portfolio 1 and enforced in Portfolio 3: a `FAILED` transaction **must post
nothing to the ledger**. The amount of a transaction lives only in
`ledger_entries`, so a failed transaction has no amount anywhere.

That is right for the ledger — a failed payment moved no value, and recording
one would be a lie. But it means **KineticsPay cannot currently answer "how
much value did we lose to expired cards last month"**, which is a question any
payments team asks weekly.

The fix is not to weaken the ledger. It is to record the *attempted* amount on
the transaction row (or on the event document) as distinct from the *posted*
amount in the ledger. Attempted value and settled value are different facts and
the schema currently conflates them by omission.

I would not have found this by inspecting the relational schema. It surfaced
only because building a second model forced a question the first model had
quietly never been asked.

---

## 8. Comparison with the alternatives

The brief allows document, key-value, column-family or graph. Why document:

| model | fit for KineticsPay | verdict |
|---|---|---|
| **Document** (MongoDB) | Sparse heterogeneous event metadata; aggregation over it; denormalised read models | ✅ **chosen** |
| **Key-value** (Redis) | Excellent for the balance cache, idempotency keys, rate limiting. But no querying by value — you cannot ask "which events were declined for an expired card" | Complementary, not a substitute |
| **Column-family** (Cassandra) | Built for exactly this write volume and for multi-region writes. But its query model demands the partition key up front, so the ad-hoc analytics above would each need their own table. Worth revisiting in Portfolio 5, where multi-region is the subject | Premature here |
| **Graph** (Neo4j) | The natural fit for fraud-ring detection — "find customers within three hops of a known mule account". A real use case, but a different one from this activity's | Future work |

---

## 9. Summary

| question | answer |
|---|---|
| What moves to MongoDB? | Transaction event metadata and the wallet read model. **Not the ledger** |
| Does the data justify it? | Yes, measurably — 9 optional field paths, 20% of documents with no device block |
| Is the schema enforced? | Yes — `$jsonSchema`, strict, 0 violations across 50,000 documents, negative controls rejected |
| Does it solve the Portfolio 3 race? | For one document, elegantly. Across two documents, it destroyed ₦20,000 |
| Does MongoDB have transactions? | Yes, since 4.0 on replica sets — with cost, limits and a retry obligation |
| Should the ledger move? | **No.** A workload that needs multi-document transactions constantly is the wrong fit for the document model |

### What I would not have predicted

1. **The single-document guard is genuinely better than the relational pattern
   for its narrow case.** One round trip, no lock, no window. I expected the
   document store to be strictly weaker here and it is not.
2. **The failure is silent.** The ₦20,000 did not raise an error. `modified=1`
   then `modified=0`, both "successful" calls, and the money was gone.
3. **Building the second model found a bug in the first.** The missing attempted
   amount in section 7 had been sitting in the relational schema since Portfolio
   1, invisible until a different model asked a question the first could not
   answer.
