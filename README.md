# KineticsPay — Advanced Database Systems Portfolio

**MIT 8103 — Advanced Database Systems**
**Miva Open University · School of Postgraduate Studies · Master of Information Technology**
**2026/2027 Academic Session · First Semester Continuous Assessment (40 marks)**

**Student:** Biliaminu Abdulfarid
**Student ID:** 301918844

---

## Case study

**KineticsPay** — a simulated digital payment and wallet management platform
operating in Nigeria. Customers hold multi-currency electronic wallets, fund
them from bank cards and transfers, send value to one another, and withdraw to
external bank accounts. The platform earns per-transaction fee revenue.

The same case study is used across all five portfolio activities, as required
by Section 2 of the assessment brief. Full statement:
[`portfolio-1-database-design/case-study.md`](portfolio-1-database-design/case-study.md).

**Why a payment platform.** It forces the correctness questions this course is
about. What happens when two withdrawals race for the same balance? How is
value prevented from being created or destroyed? What guarantees must survive a
node failure? A ledger makes these concrete rather than hypothetical.

---

## Technical architecture

| Layer | Technology | Used for |
|---|---|---|
| Relational store | PostgreSQL 16 | Schema design, SQL, transactions, concurrency control, indexing, query optimisation |
| Document store | MongoDB | Transaction metadata and payment event documents (Portfolio 4) |
| Orchestration | Docker Compose | Reproducible environments; primary–replica replication (Portfolio 5) |
| Data generation | Python 3 | Synthetic transaction volume for realistic query plans |
| Version control | Git / GitHub | Progressive evidence of development |

The stack is deliberately small. Each technology earns its place by producing
evidence a portfolio activity requires; nothing is included for breadth alone.

### The central design decision

KineticsPay is modelled as a **double-entry ledger**. No balance is stored
anywhere — every balance is derived from the postings in `ledger_entries`,
which makes it structurally impossible for a balance to disagree with the
transactions that produced it. The performance consequences of that choice are
not assumed away; they are measured in Portfolio 2.

---

## Portfolio status

| # | Activity | Marks | Status |
|---|---|---|---|
| 1 | [Database Design and Modelling](portfolio-1-database-design/) | 7 | ✅ Complete |
| 2 | [Query Processing and Optimisation](portfolio-2-query-optimisation/) | 7 | ⬜ Not started |
| 3 | [Transactions and Concurrency](portfolio-3-transactions-concurrency/) | 7 | ⬜ Not started |
| 4 | [NoSQL and Advanced Data Models](portfolio-4-nosql/) | 7 | ⬜ Not started |
| 5 | [Distributed and Cloud Database Exercise](portfolio-5-distributed-cloud/) | 6 | ⬜ Not started |
| — | [Final Documentation](final-documentation/) | 6 | ⬜ Not started |

---

## Repository structure

```
kineticspay-advanced-database-portfolio/
│
├── README.md
│
├── portfolio-1-database-design/
│   ├── README.md
│   ├── case-study.md
│   ├── schema.sql              DDL: types, tables, constraints, triggers, views
│   ├── seed.sql                representative data
│   ├── verify.sql              12-test integrity suite
│   ├── normalisation.md        UNF → 1NF → 2NF → 3NF → BCNF + denormalisation
│   ├── relationships.md        keys, foreign keys, constraint inventory
│   ├── diagrams/
│   └── evidence/
│
├── portfolio-2-query-optimisation/
│   ├── execution-plans/
│   └── evidence/
│
├── portfolio-3-transactions-concurrency/
│   └── evidence/
│
├── portfolio-4-nosql/
│   └── evidence/
│
├── portfolio-5-distributed-cloud/
│   ├── replication-config/
│   └── evidence/
│
└── final-documentation/
```

---

## Reproducing the work

Every portfolio directory contains a README stating exactly how that activity
was implemented and how to re-run it. For Portfolio 1:

```bash
createdb kineticspay
psql -d kineticspay -f portfolio-1-database-design/schema.sql
psql -d kineticspay -f portfolio-1-database-design/seed.sql
psql -d kineticspay -f portfolio-1-database-design/verify.sql
```

Verified against PostgreSQL 16.10 on Linux.

---

## Academic integrity

This is individual work. The database design, SQL, analysis and conclusions are
my own. All external sources, libraries and datasets are referenced in
`final-documentation/`, which also carries the AI Use Declaration required by
Section 11 of the assessment brief.
