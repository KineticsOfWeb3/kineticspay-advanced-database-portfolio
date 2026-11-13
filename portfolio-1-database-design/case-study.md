# Case Study Statement

**MIT 8103 — Advanced Database Systems | Continuous Assessment**
**Student:** Biliaminu Abdulfarid (301918844)

---

## Organisation

**KineticsPay** — a simulated digital payment and wallet management platform
operating in Nigeria.

KineticsPay is a simulated organisation, which Section 2 of the assessment brief
expressly permits. It is used consistently across all five portfolio activities.

## Nature of the business

KineticsPay provides multi-currency electronic wallets to retail customers. A
customer funds a wallet from a bank card or bank transfer, holds a balance,
sends value to other KineticsPay customers, and withdraws to an external bank
account. The platform earns revenue through per-transaction fees.

The platform is not a bank: it holds customer funds in a pooled settlement
account at a partner bank, and its internal ledger records what portion of that
pool belongs to each customer. Every naira on the platform is therefore a
liability owed to a customer, an asset held at the partner bank, or recognised
fee revenue — a constraint that directly shapes the database design.

## Users of the database

| User | Interaction with the database |
|---|---|
| Retail customers | Register, fund wallets, transfer value, withdraw, view statements (via the mobile app, web and USSD channels) |
| Operations staff | Investigate failed transactions, authorise reversals, freeze accounts |
| Compliance officers | Review audit trails, monitor transaction patterns, respond to NDPA data-subject requests |
| Finance team | Reconcile the internal ledger against partner-bank settlement statements |
| Merchant/partner systems | Initiate transactions programmatically through the API channel |

## Major data stored

- **Customers** — identity, contact details and KYC tier
- **Accounts** — customer wallets and the platform's internal control accounts (bank settlement, fee revenue, suspense), each denominated in a single currency
- **Transactions** — the business-level record of every deposit, withdrawal, transfer, fee and reversal, with its status and originating channel
- **Ledger entries** — the individual double-entry debit and credit postings that implement each transaction
- **Currencies** — ISO-4217 reference data
- **Audit logs** — an append-only record of significant system activity

## Key operations the database must support

1. Register a customer and open a wallet in a given currency
2. Fund a wallet from an external source (deposit)
3. Transfer value between two customer wallets, charging a fee in the same atomic operation
4. Withdraw value to an external bank account
5. Reject a transfer that would overdraw the sender, leaving no trace of value movement
6. Reverse a completed transaction without mutating the original record
7. Report a customer's current balance and transaction history
8. Produce a trial balance proving that total debits equal total credits
9. Record an immutable audit trail of who did what, when and from where

## Why this case study suits the assessment

| Portfolio activity | What KineticsPay provides |
|---|---|
| 1 — Design and modelling | Multi-entity schema with a genuine normalisation argument and a defensible denormalisation trade-off (stored vs derived balances) |
| 2 — Query and optimisation | Transaction history grows without bound; selective lookups by wallet and date range make index effects measurable at scale |
| 3 — Transactions and concurrency | Wallet transfers are the canonical ACID scenario; concurrent withdrawals against one balance produce a real lost-update and double-spend demonstration |
| 4 — NoSQL modelling | Transaction metadata (device, channel, IP, risk signals) is sparse and schema-variable — a natural document-store workload alongside the relational ledger |
| 5 — Distributed and cloud | Data residency under the NDPA motivates horizontal fragmentation by region; 24/7 payment availability motivates replication and an explicit CAP position |

A payment ledger also forces the correctness questions this course is about:
what happens when two withdrawals race for the same balance, how value is
prevented from being created or destroyed, and what guarantees must survive a
node failure.
