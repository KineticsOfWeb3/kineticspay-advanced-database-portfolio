# Portfolio 4 — NoSQL and Advanced Data Models

**MIT 8103 — Advanced Database Systems | Continuous Assessment (7 marks)**
**Student:** Biliaminu Abdulfarid (301918844)
**Case study:** KineticsPay — Digital Payment and Wallet Management Platform
**Model:** MongoDB document store, alongside the PostgreSQL ledger

---

## What this activity delivers

| Required evidence | Where it is |
|---|---|
| NoSQL model on the same case study | [`export_documents.py`](export_documents.py) — documents built from the real 528k-entry ledger |
| Document example | `transaction_events`, `wallet_snapshots` — [`data/`](data/) |
| Implementation evidence | [`evidence/mongo-output.txt`](evidence/mongo-output.txt) — validation, indexes, 8 pipelines, concurrency demo |
| Explanation of suitability | [`analysis.md`](analysis.md) |
| Server-side scripts | [`mongosh/`](mongosh/) — runs unchanged on Atlas or a local replica set |

Portfolios 1–3 are **unchanged**.

---

## Read this first: which engine this ran against

A real `mongod` **could not be installed** in the environment this was built
in. `fastdl.mongodb.org`, `repo.mongodb.org` and GitHub release downloads are
all blocked by the network policy, and `apt` carries no MongoDB package.

Rather than submit a design with no execution evidence, the model is executed
against **mongomock 4.3.0**, an in-memory implementation of the pymongo API.

| | |
|---|---|
| ✅ **Real** | Documents, queries, indexes and aggregation pipelines genuinely execute. Everything in `evidence/` is produced output |
| ✅ **Portable** | Same code against a real server — swap `mongomock.MongoClient()` for `pymongo.MongoClient(ATLAS_URI)` |
| ❌ **Not performance evidence** | No storage engine, no query planner. **No timing claims are made anywhere in this activity** |
| ❌ **Not `$jsonSchema`** | Validation run with the `jsonschema` library against equivalent rules — every document checked, not only those a server rejects |
| ❌ **Not transactions** | No replica sets. [`mongosh/03-transactions.js`](mongosh/03-transactions.js) exists to run exactly this part on Atlas |

**To reproduce on a real server:** load `data/*.json` with `mongoimport`, then
run the three `mongosh/` scripts. `03-transactions.js` needs a replica set —
Atlas free tier is one already.

---

## The split

The design question was never "how do I model KineticsPay in MongoDB". It was
**which parts belong in a document store at all**.

| Data | Home | Why |
|---|---|---|
| Ledger, accounts, customers | **PostgreSQL** | Double-entry invariants, multi-row atomicity, the lock anchor Portfolio 3 needs |
| Transaction event metadata | **MongoDB** | Sparse, schema-variable, queried analytically, no cross-record invariants |
| Wallet read model | **MongoDB** | One document serves a whole screen |

Polyglot persistence, and the split is the design rather than a compromise.

---

## Does the data actually justify a document store?

Measured across the 50,000 exported events, not asserted:

| field path | documents | % |
|---|---|---|
| `metadata.device` | 39,989 | 80.0% |
| `metadata.network` | 29,055 | 58.1% |
| `metadata.three_d_secure` | 10,934 | 21.9% |
| `metadata.risk` | 9,169 | 18.3% |
| `metadata.ussd` | 7,019 | 14.0% |
| `metadata.api` | 2,991 | 6.0% |
| `metadata.failure` | 2,632 | 5.3% |
| `metadata.compliance` | 634 | 1.3% |

**20% of documents carry no `device` block at all** — USSD has no app, an API
call has a client ID instead. These are not missing values; the concept does
not exist for those channels.

The honest competitor is a JSONB column in PostgreSQL, not a wide nullable
table. `analysis.md` §3 argues that case rather than ducking it.

---

## Schema validation

`validationLevel: "strict"`, `validationAction: "error"` — the server refuses
non-conforming writes. MongoDB is schema-**flexible**, not schema-less.

```
documents validated : 50,000
violations          : 0

Negative control:
  malformed _id                    -> REJECTED  (fails ^KP-[0-9]{4}-[0-9]{6}$)
  unknown type 'TELEPORT'          -> REJECTED  (not in enum)
  negative amount + bad channel    -> REJECTED  (2 violations)
```

---

## The concurrency result

### Single-document atomicity works, elegantly

```
update_one({_id, balance: {$gte: 35000}}, {$inc: {balance: -35000}})

withdrawal 1: matched=1 modified=1 -> APPLIED, balance now 15,000.00
withdrawal 2: matched=0 modified=0 -> REFUSED (guard failed), balance now 15,000.00
```

One round trip, no lock, no window between read and write — because there *is*
no separate read. For its narrow case this is better than the
`SELECT ... FOR UPDATE` pattern from Portfolio 3.

### Across two documents it destroyed money

```
before: A=50,000.00  B=10,000.00  total=60,000.00
step 1 debit A 20,000 : modified=1
step 2 credit B 20,000: modified=0  <-- FAILED (recipient missing)
after : A=30,000.00  B=10,000.00  total=40,000.00
NGN 20,000.00 HAS BEEN DESTROYED.
```

No exception was raised. Two "successful" calls, and ₦20,000 gone. The
relational ledger cannot reach this state — `trg_ledger_entries_balanced`
rejects any transaction whose debits and credits do not sum to zero.

**Stated accurately:** MongoDB *does* have multi-document transactions, since
4.0 on replica sets and 4.2 on sharded clusters. They need a replica set, carry
a 60-second limit and cache cost, and impose a `TransientTransactionError`
retry obligation — the same obligation `SERIALIZABLE` imposed in Portfolio 3.
The design conclusion holds regardless: a workload that needs them constantly
is the wrong fit for the document model, and **a ledger is exactly such a
workload**.

---

## A bug in Portfolio 1, found by building Portfolio 4

Pipeline 4.3 ranks decline reasons and reports `value_lost: 0.00` for every
one — obviously wrong as a business answer.

It is not a pipeline bug. A `FAILED` transaction **must post nothing to the
ledger** (Portfolio 1's design, enforced in Portfolio 3), and the amount lives
only in `ledger_entries`. So a failed transaction has no amount anywhere, and
KineticsPay **cannot answer "how much value did we lose to expired cards last
month"**.

The ledger is right — a failed payment moved no value. The schema conflates
*attempted* value with *settled* value by omitting the first. It had been
sitting there since Portfolio 1, invisible until a second model asked a
question the first could not answer. Full write-up in `analysis.md` §7.

---

## How to run it

```bash
# 1. Build documents from the PostgreSQL ledger (needs Portfolios 1-2 loaded)
python3 export_documents.py --out ./data --limit 50000

# 2. Run the document layer (mongomock, no server needed)
pip install mongomock jsonschema
python3 mongo_implementation.py | tee evidence/mongo-output.txt

# 3. On a REAL server (local replica set or Atlas free tier)
mongoimport --uri "<conn>" --collection transaction_events \
            --file data/transaction_events.json --jsonArray
mongosh "<conn>" --file mongosh/01-setup.js
mongosh "<conn>" --file mongosh/02-aggregations.js
mongosh "<conn>" --file mongosh/03-transactions.js   # needs a replica set
```

---

## Files

```
portfolio-4-nosql/
├── README.md                  this file
├── export_documents.py        builds documents from the PostgreSQL ledger
├── mongo_implementation.py    validation, indexes, 8 pipelines, concurrency demo
├── analysis.md                suitability argument and findings
├── mongosh/
│   ├── 01-setup.js            collections, $jsonSchema validators, indexes
│   ├── 02-aggregations.js     the pipelines, plus explain()
│   └── 03-transactions.js     multi-document transactions (needs a replica set)
└── evidence/
    ├── export-summary.txt     document counts and field-presence report
    └── mongo-output.txt       full captured run
```

`data/` holds the generated JSON (42 MB) and is gitignored — reproducible from
`export_documents.py` with the fixed seed.

---

## Carried forward

| To | What |
|---|---|
| Portfolio 5 | Cassandra's column-family model is built for multi-region writes, which is Portfolio 5's subject. The sharding and replication questions raised here belong there |
| Portfolio 1 fix | Record *attempted* amount distinct from *posted* amount, so declined value is answerable. Noted rather than applied — Portfolio 1 is frozen |
| Future work | A graph model for fraud-ring detection: "customers within three hops of a known mule account" is a real question neither the relational nor the document model answers well |
