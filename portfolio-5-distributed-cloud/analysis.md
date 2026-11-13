# Distributed and Cloud Databases — Analysis

**MIT 8103 — Advanced Database Systems | Portfolio 5**
**Student:** Biliaminu Abdulfarid (301918844)
**Case study:** KineticsPay — Digital Payment and Wallet Management Platform
**Topology:** PostgreSQL 16 primary + hot standby, two independent clusters

---

## 1. What was actually built

A real primary and a real hot standby, two clusters on two ports:

```
primary  localhost:5432   /var/lib/pgdata     "Lagos"
standby  localhost:5433   /var/lib/pgstandby  "Abuja"
```

Built with `pg_basebackup` over a replication slot, streaming physical WAL. Not
a simulation:

```
application_name | walreceiver
state            | streaming
sync_state       | async
replay_lag       | 00:00:00.000068
```

528,763 ledger entries replicated, and the standby refuses writes:

```
ERROR:  cannot execute INSERT in a read-only transaction
```

### The honest limit

**Two ports on one host is not multi-region.** The machinery is genuine — WAL
sender, replication slot, hot standby, promotion, timeline switch — but the
*network* is loopback. There is no inter-region latency and no partial
partition. Wherever a measurement depends on network distance I say so rather
than presenting a loopback number as a regional one. The
[`deployment/docker-compose.yml`](deployment/docker-compose.yml) topology is
provided for the case where latency and partition can be injected; Docker is
unavailable here, so it is a deployment artefact, not evidence.

---

## 2. Replication lag

| | bytes behind | write_lag | flush_lag | replay_lag |
|---|---|---|---|---|
| Idle | 0 | — | — | — |
| Immediately after 20,000-row burst | 0 | 5.8 ms | 7.7 ms | **21.4 ms** |

Both nodes read 20,000 immediately afterwards — the standby had already caught
up faster than two sequential `psql` invocations.

The three lag figures are the distinction that matters. `write_lag` is WAL
received, `flush_lag` is WAL durable, `replay_lag` is WAL **visible to
queries**. A read-replica serving customer balances is governed by `replay_lag`,
not `write_lag`: data can be safely on disk at the standby and still not be
returned by a query there.

21 ms sounds negligible. Over a Lagos–Abuja link it would be that plus RTT, and
for a wallet balance that is a window in which a customer who just transferred
money can refresh and not see it. This is the same staleness Portfolio 2
measured for the materialised view, arriving from a different direction — and
it is why **authorisation reads must go to the primary** even when display
reads can go to a replica.

---

## 3. CAP, measured

Identical write, identical code, with the standby killed. Only the
`synchronous_standby_names` setting differs.

| configuration | standby | outcome | elapsed |
|---|---|---|---|
| `synchronous_standby_names = ''` (async) | **down** | ✅ write succeeded | **0.045 s** |
| `synchronous_standby_names = '*'` (sync) | **down** | ❌ write **blocked** | **682.9 s** |
| `synchronous_standby_names = '*'` (sync) | up | ✅ write succeeded | **0.035 s** |

That is CAP, as an executable experiment rather than a diagram. Under
partition:

- **Async chooses A.** The primary acknowledges a commit it cannot guarantee
  elsewhere. The system stays up; the nodes disagree.
- **Sync chooses C.** The primary refuses to acknowledge what it cannot
  guarantee on a second node. The nodes never disagree; the system stops
  serving writes.

Neither is a bug, and neither is universally right. The 0.045 s and the 682.9 s
are the same system with one setting changed.

### The finding I did not expect

**The 682.9 s was not the timeout.** The session had run
`SET statement_timeout = '10s'`. It waited 11 minutes 22 seconds, and only
completed when I restarted the standby by hand.

Captured mid-block:

```
pid             | 394
state           | active
wait_event_type | IPC
wait_event      | SyncRep
waiting_for     | 00:11:22.513938
query           | SET statement_timeout = '10s'; INSERT INTO replication_load...
```

Once a transaction has written its commit record and entered the `SyncRep`
wait, **it is already durable locally**. `statement_timeout` governs statement
execution, not the post-commit replication wait, so it cannot fire. The wait is
interruptible only by a client cancel or backend termination — and even then
**the transaction remains committed on the primary** while the client never
received an acknowledgement.

That is worse than plain unavailability. The transaction is in limbo: the client
must assume it failed, and the primary has already applied it. For a payment
platform this is the classic double-submit hazard — the customer retries, and
without an idempotency key they are debited twice. It is exactly why
`metadata.api.idempotency_key` exists in the Portfolio 4 document model, and I
had not connected those two facts until this blocked.

**The practical consequence:** you cannot bound synchronous replication's
failure mode with a statement timeout. Bounding it requires either
`synchronous_standby_names = 'ANY 1 (a, b)'` with more standbys than you need,
or an external supervisor that demotes to async when a standby is lost — a
deliberate automated choice of A over C, not something the database does for
you.

### What I could *not* measure honestly

Throughput cost of synchronous commit: 2,000 inserts took 0.050 s async and
0.046 s sync. **Those numbers are meaningless** and I am not claiming
synchronous replication is free. Two reasons: the inserts were one transaction,
so there was one commit and one replication round trip rather than 2,000; and
loopback has no network latency, which is the entire cost being measured. A
real figure needs separate transactions across a real link. The compose
topology exists for that.

---

## 4. Failover, and the data loss async permits

The concrete cost of choosing AP:

1. A marker row committed with the standby connected.
2. Standby killed — the partition.
3. **Three rows committed and acknowledged** to the client while the standby
   could not receive them.
4. Primary killed. Standby promoted.

```
rows on the old primary at the moment it died : 24007
rows on the promoted node (minus the 1 new)   : 24004
acknowledged commits LOST                     : 3

lost_rows_found      | 0     ← the three "LOST" markers are gone
before_partition_row | 1     ← the pre-partition marker survived
```

**Three transactions the platform told its customers had succeeded no longer
exist.** For KineticsPay those are transfers confirmed in the app and absent
from the ledger — the reconciliation break that a finance team discovers days
later.

The promoted node is writable and on a **new timeline**:

```
promoted node timeline: 2
```

The timeline bump is why failover is not reversible by simply restarting the
old primary as a standby. Its WAL diverged at the moment of promotion, so
rejoining requires `pg_rewind` or a fresh base backup. In a real incident that
is hours of resynchronisation on a 42 GB cluster, during which the platform runs
on a single node with no redundancy — the window in which a second failure is
unrecoverable.

### What KineticsPay should actually do

Neither pure async nor pure sync:

| | configuration | why |
|---|---|---|
| Ledger writes | `synchronous_standby_names = 'ANY 1 (abuja, lagos_replica)'` | Two candidate standbys, require one. Survives losing either without blocking, and bounds data loss to zero for acknowledged commits |
| Event metadata (Portfolio 4) | async | Operational telemetry; losing seconds of it on failover is acceptable |
| Display reads | replica, async | 21 ms staleness is invisible |
| Authorisation reads | **primary only** | Portfolio 3 showed the check must be serialised; a replica cannot take the row lock |

The cost is a third node. For a payment ledger that is the correct price.

---

## 5. Fragmentation for NDPA 2023 data residency

The Nigeria Data Protection Act 2023 restricts transfers of personal data
outside Nigeria unless the destination affords adequate protection. A platform
operating across West Africa therefore cannot place records wherever capacity
happens to be.

**Horizontal fragmentation** is the structural answer: split by rows on a region
key, so Nigerian data subjects' postings physically reside in Nigerian
infrastructure. Vertical fragmentation would not help — every column-wise
fragment still contains rows belonging to every data subject.

Declarative `PARTITION BY LIST (region)`, loading the real ledger in **1.6 s**:

| fragment | rows | % | size |
|---|---|---|---|
| `ledger_ng_lagos` | 311,859 | 59.0% | 40 MB |
| `ledger_ng_abuja` | 188,462 | 35.6% | 24 MB |
| `ledger_gh_accra` | 28,442 | 5.4% | 3,760 kB |
| `ledger_other` (DEFAULT) | 0 | — | 16 kB |

The `DEFAULT` partition holding zero rows is deliberate and worth keeping: a
posting whose region is unrecognised lands somewhere visible rather than being
rejected at write time or silently misfiled into a jurisdiction it does not
belong to. An empty default partition is a compliance alarm.

### Partition pruning works

| query | plan |
|---|---|
| `WHERE region = 'NG_LAGOS'` | `Parallel Seq Scan on ledger_ng_lagos` — **one fragment** |
| no region predicate | `Parallel Append` across **all fragments** |

Pruning is what makes fragmentation pay. The corollary is the cost: a
cross-jurisdiction compliance report has no region predicate and must touch
every fragment. **Fragmentation optimises the regional case and penalises the
global one** — which is the right trade for a platform whose regulator cares
about the regional case.

---

## 6. Cross-node sharding with `postgres_fdw`

Partitions on one node are not sharding. The Abuja fragment was moved to node B
and exposed on node A as a foreign table.

| query | plan | time |
|---|---|---|
| `COUNT(*), SUM(amount)` on the remote shard | `Foreign Scan`, **aggregate pushed down** | 32.7 ms |
| Join remote shard to local `accounts` | `Foreign Scan` pulling **188,462 rows** across the boundary | **296.2 ms** |

The pushdown is visible in the plan:

```
Remote SQL: SELECT count(*), sum(amount) FROM public.ledger_abuja_remote
```

That is the whole game. When the aggregate executes **on** the shard, one row
crosses the boundary. When a join forces rows to be shipped, 188,462 cross it —
**9× slower here, and this is loopback**. Over a real regional link, dominated
by transfer time rather than computation, the gap would be far larger.

The design rule: **shard on the key your queries filter by.** A cross-shard
join is not a slow query to be optimised later; it is a signal that the shard
key is wrong for that access pattern.

### An honest anomaly

`COUNT(*)` on the remote shard measured **14–20 ms** against **27–34 ms** for
the equivalent local partition — the remote was *faster*. Not because FDW is
free: the remote table is a standalone relation with a primary-key index that
`count(*)` can satisfy with an index-only scan, while the local partition does a
parallel sequential scan. And there is no network between them.

**Do not read this as "remote is as fast as local."** It is an artefact of
loopback plus a different physical layout, and I am reporting it because
suppressing an inconvenient measurement would be worse than explaining it.

---

## 7. Two-phase commit

A transfer whose sender is in Lagos and recipient in Abuja must be atomic across
both nodes.

```
PREPARE TRANSACTION 'xfer_lagos_001';   -- node A
PREPARE TRANSACTION 'xfer_abuja_001';   -- node B
→ row visible on node A? 0              -- prepared is not committed
COMMIT PREPARED 'xfer_lagos_001';
COMMIT PREPARED 'xfer_abuja_001';
→ node A sees 1, node B sees 1
```

It works, and atomicity across nodes is real.

### The blocking problem

Node A prepares; the coordinator then dies before deciding. The prepared
transaction survives — including across a restart, which is the point of it —
and holds its locks with **no backend to own them**:

```
   locktype    |          rel           |       mode       | granted | pid
---------------+------------------------+------------------+---------+-----
 relation      | ledger_entries_sharded | RowExclusiveLock | t       |
 relation      | ledger_ng_lagos        | RowExclusiveLock | t       |
 transactionid |                        | ExclusiveLock    | t       |
```

`pid` is empty. Nothing will time out, because nothing is running.

| operation attempted against the orphan | result |
|---|---|
| Conflicting `INSERT` on the same primary key | **blocked 5.04 s** until `lock_timeout` — *"while inserting index tuple in relation ledger_ng_lagos_pkey"* |
| `TRUNCATE` on the partition | **blocked 5.05 s** until `lock_timeout` |
| After `ROLLBACK PREPARED` | same `INSERT` succeeds in **0.04 s** |

It also pins the transaction horizon, so `VACUUM` cannot reclaim dead tuples
anywhere in the database for as long as it exists. An orphan left over a weekend
is a bloat incident as well as a locking one.

**A correction worth recording.** My first attempt to demonstrate this ran a
`DELETE` against the prepared row and reported `DELETE 0`. That proved nothing —
the prepared row is not committed, so a new session cannot see it, finds nothing
to delete, and never touches the orphan's locks. The test had to conflict on the
*index* or demand a stronger table lock. I had written a test that passed
without testing anything, which is the same mistake Portfolio 1's original
twelve tests made.

### Why KineticsPay does not use 2PC for transfers

| | |
|---|---|
| Latency | Two round trips to every participant, each at inter-region RTT, on the critical path of a user-facing payment |
| Availability | Strictly worse than any single node: the transaction needs *every* participant up for *both* phases |
| Blocking | Coordinator failure leaves locks held indefinitely, requiring manual or external resolution |
| Operational burden | A durable, highly available transaction manager — itself a distributed-systems problem |

The alternative KineticsPay's design already implies: **keep a transfer within
one shard wherever possible**, by sharding on a key that puts both parties
together, and where cross-shard transfers are unavoidable use a saga — a
sequence of locally atomic steps with compensating entries. The ledger already
has the compensation mechanism: a `REVERSAL` transaction, constrained in
Portfolio 1 to mirror its original exactly.

That is not 2PC's guarantee. A saga gives eventual consistency with a
compensating audit trail instead of atomicity. For a payment ledger that is
defensible precisely *because* every step is recorded and every correction is
itself a posting — which is why the append-only, double-entry design from
Portfolio 1 matters more at this stage than it did when I built it.

---

## 8. Cloud deployment

Not executed, and I will not claim otherwise. The sandbox has no Docker and no
outbound network to a cloud provider.

Provided as artefacts:

- [`deployment/docker-compose.yml`](deployment/docker-compose.yml) — the same
  primary/standby topology in containers on a bridge network, so latency and
  partition can be injected (`docker network disconnect`). Secrets come from
  `.env`, which is gitignored; `.env.example` shows the shape.
- [`replication-config/`](replication-config/) — the actual `primary_conninfo`
  and server settings from the running pair, password redacted.
- A `pgbouncer` service, because read/write splitting and failover routing
  belong in a pooler rather than in application code.

### What a managed service changes, and what it does not

| | self-managed | managed (RDS / Cloud SQL / Aurora) |
|---|---|---|
| Base backup, WAL archiving, PITR | You build it | Provided |
| Failover | You detect and promote | Automatic, typically 60–120 s |
| **The CAP choice** | Yours | **Still yours** — `synchronous_commit` is a parameter you set |
| **The data loss in §4** | Yours | **Still yours.** Multi-AZ with async replication loses acknowledged commits on failover exactly as measured above |
| Cross-region latency | Yours | Yours |

A managed service removes the operational work, not the distributed-systems
trade-off. Every finding in this activity applies unchanged to a managed
deployment, because they are properties of replication rather than of who runs
it.

---

## 9. Summary

| # | Experiment | Result |
|---|---|---|
| 1 | Replication lag | 21.4 ms replay lag after a 20,000-row burst |
| 2 | CAP, async, standby down | Write succeeded in **0.045 s** — availability chosen |
| 3 | CAP, sync, standby down | Write **blocked 682.9 s** — consistency chosen |
| — | `statement_timeout` during `SyncRep` | **Does not fire.** Transaction in limbo: locally committed, unacknowledged |
| 4 | Failover after partition | **3 acknowledged commits lost**; new timeline 2 |
| 5 | Fragmentation by region | 311,859 / 188,462 / 28,442 across three jurisdictions |
| 6 | Partition pruning | One fragment scanned with a region predicate; all without |
| 7 | FDW aggregate pushdown | 32.7 ms pushed down vs **296.2 ms** for a cross-shard join |
| 8 | Two-phase commit | Works; orphan blocks conflicting writes **5 s+**, resolves in 0.04 s |

### What I would not have predicted

1. **`statement_timeout` cannot rescue a synchronous commit.** I wrote the
   timeout into the script expecting it to bound the experiment at 10 seconds.
   It ran for 11 minutes. The transaction was already committed locally — and
   that limbo state is a worse failure mode than the unavailability I set out
   to demonstrate.
2. **The lost commits were silent.** Nothing errored. Three transactions were
   acknowledged, the primary died, and they were simply not there afterwards.
3. **Aggregate pushdown is the whole difference between workable and unworkable
   sharding** — 32.7 ms versus 296.2 ms on the same data, decided entirely by
   whether the computation travels to the rows or the rows travel to the
   computation.
