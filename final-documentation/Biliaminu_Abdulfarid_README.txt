================================================================================
MIT 8103 - ADVANCED DATABASE SYSTEMS
First Semester Continuous Assessment | 2026/2027 Academic Session
Individual Practical Database Portfolio (40 marks)
================================================================================

STUDENT      : Biliaminu Abdulfarid
STUDENT ID   : 301918844
EMAIL        : a.biliaminu8844@miva.edu.ng
PROGRAMME    : MSc Information Technology

GITHUB       : https://github.com/KineticsOfWeb3/kineticspay-advanced-database-portfolio
               (public; 30 commits; all five portfolio activities)


--------------------------------------------------------------------------------
1. CASE STUDY
--------------------------------------------------------------------------------

KineticsPay - a simulated digital payment and wallet management platform
operating in Nigeria. Section 2 of the brief permits a simulated organisation,
and the same case study is used consistently across all five activities.

Customers hold multi-currency electronic wallets, fund them from bank cards and
transfers, send value to one another, and withdraw to external bank accounts.
The platform earns per-transaction fee revenue. It is not a bank: customer funds
sit in a pooled settlement account at a partner bank, and the internal ledger
records which portion belongs to whom.

The central design decision is that KineticsPay is modelled as a DOUBLE-ENTRY
LEDGER. No balance is stored anywhere; every balance is derived from the
postings in ledger_entries, so a balance cannot disagree with the transactions
that produced it. The cost of that choice is measured in Portfolio 2 rather
than assumed.


--------------------------------------------------------------------------------
2. WHAT IS IN THIS SUBMISSION
--------------------------------------------------------------------------------

  Biliaminu_Abdulfarid_Documentation.docx   the 2-3 page portfolio documentation
  Biliaminu_Abdulfarid_README.txt           this file
  portfolio/                                the full portfolio, as on GitHub

  portfolio/
    |- README.md                            repository overview
    |- portfolio-1-database-design/         schema, ERD, normalisation, 21 tests
    |- portfolio-2-query-optimisation/      7 benchmark experiments, 528,647 rows
    |- portfolio-3-transactions-concurrency/ race condition and its controls
    |- portfolio-4-nosql/                   MongoDB document model
    |- portfolio-5-distributed-cloud/       replication, sharding, CAP, 2PC
    |- final-documentation/

Every activity folder contains its own README.md stating how that activity was
implemented and how to re-run it, an analysis document, and an evidence/ folder
holding the captured output of every script.

Two directories are intentionally absent because they are regenerable and large:
portfolio-2-query-optimisation/data/ (73 MB) and portfolio-4-nosql/data/
(42 MB). Both rebuild byte-identically from their generator scripts, which use
a fixed random seed (8103).


--------------------------------------------------------------------------------
3. HOW TO RUN IT
--------------------------------------------------------------------------------

Requires PostgreSQL 16 and Python 3. Tested on PostgreSQL 16.15, Linux.

  # Portfolio 1 - schema, seed data, 21-test integrity suite
  createdb kineticspay
  psql -d kineticspay -f portfolio-1-database-design/schema.sql
  psql -d kineticspay -f portfolio-1-database-design/seed.sql
  psql -d kineticspay -f portfolio-1-database-design/verify.sql

  Expect 15 errors in that output. Every one is a deliberate rejection by a
  constraint or trigger. Fewer means a constraint is missing.

  # Portfolio 2 - benchmark dataset and seven experiments
  cd portfolio-2-query-optimisation
  python3 generate_data.py --out ./data
  psql -d kineticspay -f load_data.sql
  ./run-benchmarks.sh
  psql -d kineticspay -f queries.sql
  psql -d kineticspay -f indexes.sql

  # Portfolio 3 - concurrency
  cd ../portfolio-3-transactions-concurrency
  psql -d kineticspay -f setup.sql
  ./run-concurrency.sh
  psql -d kineticspay -f safe-transfer.sql
  ./verify-safe.sh

  # Portfolio 4 - document model
  cd ../portfolio-4-nosql
  pip install mongomock jsonschema
  python3 export_documents.py --out ./data
  python3 mongo_implementation.py

  # Portfolio 5 - replication, sharding, CAP, two-phase commit
  cd ../portfolio-5-distributed-cloud
  ./setup-replication.sh
  ./cap-experiments.sh      # see the warning below
  ./sharding-2pc.sh

WARNING on cap-experiments.sh: Experiment 3 deliberately blocks a synchronous
commit with no standby present. statement_timeout does NOT release it - that is
the finding, not a defect. The run will hang until the standby is restarted in
another terminal:

  su postgres -c "/usr/lib/postgresql/16/bin/pg_ctl -D /var/lib/pgstandby \
    -o '-c listen_addresses=localhost -p 5433 -c hot_standby=on' start"


--------------------------------------------------------------------------------
4. SUMMARY OF RESULTS
--------------------------------------------------------------------------------

PORTFOLIO 1 - Database Design and Modelling
  Six relations in BCNF. Money as NUMERIC(20,4). Currency enforced by a
  composite foreign key. Balanced-transaction rule enforced by a deferred
  constraint trigger. Append-only ledger. 21 tests, 16 negative, all passing.
  Four real integrity gaps were found by deliberately attacking the first
  version of the schema and are documented in design-review.md.

PORTFOLIO 2 - Query Processing and Optimisation
  Sequential vs index scan          25.5 ms -> 1.55 ms  (16x)
  Composite vs single-column index  1.44 ms -> 0.28 ms, Sort node eliminated
  Selectivity crossover             bitmap held to 21.9%; seq scan from 35.3%
  Pagination                        keyset ~134x faster than OFFSET at 50,000
  Derived balance vs matview        344x read win against measurable staleness
  Index write overhead              5.9x slower inserts; indexes 132% of heap
  Unhelpful index                   ignored entirely at n_distinct = 2

PORTFOLIO 3 - Transactions and Concurrency
  No control                        overdraft of NGN 20,000
  Deferred constraint, staggered    rejected - but only by luck of timing
  Deferred constraint, simultaneous overdraft of NGN 20,000 again
  SELECT ... FOR UPDATE             correct, deterministically
  SERIALIZABLE                      correct, via SQLSTATE 40001
  Opposing locks, no ordering       deadlock, SQLSTATE 40P01
  Ascending lock order              both transfers succeed

PORTFOLIO 4 - NoSQL and Advanced Data Models
  50,000 documents derived from the relational ledger. Nine optional field
  paths; 20% of events carry no device block at all. Validation passed on all
  50,000 with three invalid documents rejected as a negative control. Eight
  aggregation pipelines executed. Single-document guarded update refuses a
  second withdrawal correctly; across two documents the same approach destroyed
  NGN 20,000 with no error raised.

PORTFOLIO 5 - Distributed and Cloud Database Exercise
  Real primary + hot standby, streaming, 68 microsecond replay lag.
  CAP measured: async with standby down succeeded in 0.045 s; synchronous with
  standby down blocked for 682.9 s. Failover lost three acknowledged commits.
  Fragmentation by region for NDPA 2023: 311,859 Lagos / 188,462 Abuja /
  28,442 Accra, with partition pruning confirmed. FDW aggregate pushdown
  32.7 ms vs 296.2 ms for a cross-shard join. Two-phase commit works; an
  orphaned prepared transaction blocked conflicting writes for over 5 s.


--------------------------------------------------------------------------------
5. STATED LIMITATIONS
--------------------------------------------------------------------------------

These are recorded here and in the relevant activity READMEs rather than left
for a marker to discover.

  1. MongoDB server. A real mongod could not be installed in the environment
     used (the download hosts are blocked by network policy). Portfolio 4's
     pipelines were executed against mongomock, an in-memory pymongo-compatible
     implementation. The documents, queries, indexes and aggregation pipelines
     genuinely execute, but NO PERFORMANCE CLAIM is made anywhere in that
     activity. mongosh scripts are provided to reproduce the multi-document
     transaction behaviour on a real replica set.

  2. Multi-region replication. Portfolio 5's primary and standby are two real
     clusters on two ports of one host. The replication machinery is genuine,
     but the network is loopback: there is no inter-region latency and no
     partial partition. Any measurement that depends on network distance is
     flagged as such rather than presented as a regional figure.

  3. Synchronous replication throughput. The figures measured (0.050 s async vs
     0.046 s sync for 2,000 rows) are MEANINGLESS and no claim is drawn from
     them: the inserts were one transaction, so there was one replication round
     trip rather than 2,000, and loopback has no latency.

  4. Cloud deployment. Not executed. Docker and outbound network access to a
     cloud provider were unavailable. A docker-compose topology and the
     replication configuration from the running pair are provided as deployment
     artefacts, clearly marked as not executed.

  5. Legacy data. 2,087 wallets in the generated dataset carry negative
     balances from activity generated before any overdraft rule existed. The
     constraint added in Portfolio 3 prevents new overdrafts but does not repair
     historical ones; remediation would be a reconciliation exercise rather
     than a schema change.


--------------------------------------------------------------------------------
6. ACADEMIC INTEGRITY AND AI USE
--------------------------------------------------------------------------------

This is individual work. The full AI Use Declaration required by Section 11 of
the assessment brief is in Biliaminu_Abdulfarid_Documentation.docx, Section 7.

In summary: Claude (Anthropic) was used as a learning aid for concept
clarification, schema design review, drafting SQL and test harnesses, and
explaining execution plans. Commits co-authored with the tool are attributed as
such in the repository's git history. Every script was executed against a live
PostgreSQL 16 instance and its output captured as evidence. Claimed behaviour
was verified by negative testing rather than accepted.

Use of AI tools does not remove my responsibility for the accuracy, originality
and understanding of the submitted work.

================================================================================
