# Portfolio 5 — Distributed and Cloud Database Exercise

**MIT 8103 — Advanced Database Systems | Continuous Assessment (6 marks)**
**Student:** Biliaminu Abdulfarid (301918844)
**Case study:** KineticsPay — Digital Payment and Wallet Management Platform
**Topology:** PostgreSQL 16 primary + hot standby

---

## What this activity delivers

| Required evidence | Where it is |
|---|---|
| Replication | Real primary + streaming hot standby — [`setup-replication.sh`](setup-replication.sh) |
| Sharding | Horizontal fragmentation by region + cross-node FDW — [`sharding-2pc.sh`](sharding-2pc.sh) |
| Availability | Failover with measured data loss — [`cap-experiments.sh`](cap-experiments.sh) |
| Consistency | CAP as an executed experiment, sync vs async |
| Deployment evidence | [`deployment/`](deployment/), [`replication-config/`](replication-config/) |
| Analysis | [`analysis.md`](analysis.md) |

Portfolios 1–4 are **unchanged**.

---

## What was really built

```
primary  localhost:5432   /var/lib/pgdata     "Lagos"
standby  localhost:5433   /var/lib/pgstandby  "Abuja"
```

Built with `pg_basebackup` over a physical replication slot. Genuinely
streaming:

```
application_name | walreceiver
state            | streaming
sync_state       | async
replay_lag       | 00:00:00.000068
```

528,763 ledger entries replicated; the standby refuses writes with
`ERROR: cannot execute INSERT in a read-only transaction`.

**The honest limit:** two ports on one host is not multi-region. The machinery
is real — WAL sender, slot, hot standby, promotion, timeline switch — but the
network is loopback, so there is no inter-region latency and no partial
partition. Wherever a number depends on network distance, the analysis says so
instead of passing a loopback figure off as a regional one.

---

## CAP, as an experiment rather than a diagram

Identical write, identical code, standby killed. Only one setting differs.

| configuration | standby | outcome | elapsed |
|---|---|---|---|
| async | **down** | ✅ succeeded | **0.045 s** |
| synchronous | **down** | ❌ **blocked** | **682.9 s** |
| synchronous | up | ✅ succeeded | **0.035 s** |

Async chooses **availability** — the primary acknowledges what it cannot
guarantee elsewhere. Synchronous chooses **consistency** — it refuses to. Same
system, one setting.

### The finding that surprised me

**That 682.9 s was not the timeout.** The session had `statement_timeout = '10s'`
set. It waited 11 minutes 22 seconds and only completed when I restarted the
standby by hand. Captured mid-block:

```
wait_event_type | IPC
wait_event      | SyncRep
waiting_for     | 00:11:22.513938
query           | SET statement_timeout = '10s'; INSERT INTO ...
```

Once a transaction enters the `SyncRep` wait it is **already durable locally**.
`statement_timeout` governs statement execution, not the post-commit
replication wait, so it never fires — and even cancelling leaves the
transaction **committed on the primary** with the client never acknowledged.

That is worse than unavailability: the transaction is in limbo. The client must
assume failure; the primary has applied it. For a payment platform that is the
double-submit hazard, and it is exactly why `metadata.api.idempotency_key`
exists in the Portfolio 4 document model — a connection I had not made until
this blocked.

---

## Failover lost acknowledged commits

Marker row committed with the standby up → standby killed → **three rows
committed and acknowledged** → primary killed → standby promoted:

```
rows on the old primary at the moment it died : 24007
rows on the promoted node (minus the 1 new)   : 24004
acknowledged commits LOST                     : 3

lost_rows_found      | 0     ← the three markers are gone
before_partition_row | 1     ← the pre-partition marker survived
```

**Nothing errored.** Three transfers the platform confirmed to customers simply
no longer exist. The promoted node is on **timeline 2**, which is why the old
primary cannot rejoin as a standby without `pg_rewind` or a fresh base backup.

---

## Fragmentation for NDPA 2023

The Nigeria Data Protection Act restricts transfers of personal data outside
Nigeria without adequate protection in the destination. Horizontal
fragmentation is the structural answer — split by rows on a region key so
Nigerian data subjects' postings sit in Nigerian infrastructure. Vertical
fragmentation would not help: every column-wise fragment still holds rows for
every data subject.

Real ledger loaded into fragments in **1.6 s**:

| fragment | rows | % | size |
|---|---|---|---|
| `ledger_ng_lagos` | 311,859 | 59.0% | 40 MB |
| `ledger_ng_abuja` | 188,462 | 35.6% | 24 MB |
| `ledger_gh_accra` | 28,442 | 5.4% | 3,760 kB |
| `ledger_other` (DEFAULT) | 0 | — | 16 kB |

Pruning confirmed: a region predicate scans **one** fragment; no predicate gives
`Parallel Append` across all. The empty `DEFAULT` partition is deliberate — an
unrecognised region lands somewhere visible rather than being silently misfiled
into the wrong jurisdiction.

---

## Sharding: pushdown is everything

| query | plan | time |
|---|---|---|
| Aggregate on the remote shard | `Foreign Scan`, **pushed down** | 32.7 ms |
| Join remote shard to local `accounts` | ships **188,462 rows** across the boundary | **296.2 ms** |

```
Remote SQL: SELECT count(*), sum(amount) FROM public.ledger_abuja_remote
```

When the computation travels to the rows, one row crosses the boundary. When a
join forces rows to travel, 188,462 do — 9× slower **on loopback**, and far
worse over a real link. A cross-shard join isn't a slow query to optimise
later; it means the shard key is wrong for that access pattern.

One anomaly reported rather than hidden: `COUNT(*)` was *faster* remote
(14–20 ms) than on the local partition (27–34 ms), because the remote table has
a PK index serving an index-only scan while the partition does a parallel seq
scan — and there's no network between them. It is not evidence that FDW is free.

---

## Two-phase commit, and why it isn't used here

2PC works — `PREPARE TRANSACTION` on both nodes, row invisible until
`COMMIT PREPARED`, atomic across the pair. The problem is what happens when the
coordinator dies after preparing:

```
   locktype    |          rel           |       mode       | granted | pid
---------------+------------------------+------------------+---------+-----
 relation      | ledger_entries_sharded | RowExclusiveLock | t       |
 relation      | ledger_ng_lagos        | RowExclusiveLock | t       |
 transactionid |                        | ExclusiveLock    | t       |
```

`pid` is empty — nothing will time out because nothing is running.

| attempted against the orphan | result |
|---|---|
| Conflicting `INSERT` on the same PK | **blocked 5.04 s** until `lock_timeout` |
| `TRUNCATE` on the partition | **blocked 5.05 s** |
| After `ROLLBACK PREPARED` | same `INSERT` in **0.04 s** |

It also pins the transaction horizon, so `VACUUM` reclaims nothing database-wide
while it exists.

**A correction recorded in the analysis:** my first blocking test ran a `DELETE`
against the prepared row and reported `DELETE 0` — proving nothing, since an
uncommitted row is invisible to a new session, which therefore never touches the
orphan's locks. I had written a test that passed without testing anything. Same
mistake Portfolio 1's original twelve tests made.

KineticsPay therefore keeps transfers within one shard where possible and uses
a **saga** with compensating `REVERSAL` postings where it cannot — weaker than
2PC's atomicity, but every step is recorded and every correction is itself a
posting, which is what the Portfolio 1 design was for.

---

## Cloud deployment

**Not executed, and not claimed as evidence.** No Docker and no outbound network
to a provider in this sandbox.

Provided as artefacts: [`deployment/docker-compose.yml`](deployment/docker-compose.yml)
(same topology in containers on a bridge network so latency and partition *can*
be injected, plus a `pgbouncer` for read/write splitting), and
[`replication-config/`](replication-config/) carrying the actual
`primary_conninfo` and settings from the running pair with the password
redacted.

What a managed service changes, and what it doesn't:

| | self-managed | managed (RDS / Cloud SQL) |
|---|---|---|
| Backups, PITR, failover automation | You build it | Provided |
| **The CAP choice** | Yours | **Still yours** — a parameter you set |
| **The 3 lost commits** | Yours | **Still yours** — multi-AZ async loses them identically |

A managed service removes the operational work, not the trade-off.

---

## How to run it

```bash
# Needs the Portfolio 1 schema and ideally the Portfolio 2 dataset loaded
./setup-replication.sh      # primary + standby, ~1 min
./cap-experiments.sh        # CAP, lag, failover — WARNING: see note
./sharding-2pc.sh           # fragmentation, FDW, 2PC, ~2 min
```

**Warning on `cap-experiments.sh`:** Experiment 3 deliberately blocks a
synchronous commit with no standby. As discovered above, `statement_timeout`
does **not** release it. The run will hang until you restart the standby in
another terminal:

```bash
su postgres -c "/usr/lib/postgresql/16/bin/pg_ctl -D /var/lib/pgstandby \
  -o '-c listen_addresses=localhost -p 5433 -c hot_standby=on' start"
```

That hang is the finding, not a defect in the script.

---

## Files

```
portfolio-5-distributed-cloud/
├── README.md                     this file
├── setup-replication.sh          primary + hot standby via pg_basebackup
├── cap-experiments.sh            lag, CAP sync vs async, failover, data loss
├── sharding-2pc.sh               fragmentation, pruning, FDW, two-phase commit
├── analysis.md                   full analysis
├── deployment/
│   ├── docker-compose.yml        containerised topology (NOT executed)
│   ├── .env.example              secrets shape; .env is gitignored
│   └── init/01-replication-role.sql
├── replication-config/
│   ├── primary-postgresql.auto.conf
│   └── standby-postgresql.auto.conf   (password redacted)
└── evidence/
    ├── replication-setup.txt           streaming confirmed, standby read-only
    ├── cap-experiments.txt             all six experiments
    ├── syncrep-blocking-finding.txt    the 11m22s block, captured live
    ├── sharding-2pc.txt                fragments, pruning, pushdown, 2PC
    └── 2pc-blocking-correction.txt     the corrected blocking demonstration
```

---

## Where the portfolio now stands

| # | Activity | Marks | Status |
|---|---|---|---|
| 1 | Database Design and Modelling | 7 | ✅ Frozen — 21 tests |
| 2 | Query Processing and Optimisation | 7 | ✅ Frozen — 7 experiments |
| 3 | Transactions and Concurrency | 7 | ✅ Complete |
| 4 | NoSQL and Advanced Data Models | 7 | ✅ Complete |
| 5 | Distributed and Cloud | 6 | ✅ Complete |
| — | **Final documentation** | **6** | ⬜ **Remaining** |

The 2–3 page LMS document, GitHub link, screenshots, individual reflection,
references and AI-use declaration are what's left.
