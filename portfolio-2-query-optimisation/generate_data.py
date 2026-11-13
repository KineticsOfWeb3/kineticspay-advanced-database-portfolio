#!/usr/bin/env python3
"""
KineticsPay - benchmark dataset generator
Portfolio 2: Query Processing and Optimisation

MIT 8103 Advanced Database Systems
Biliaminu Abdulfarid (301918844)

WHY THIS IS NOT 500,000 IDENTICAL ROWS
--------------------------------------
A uniformly distributed dataset makes indexing experiments produce misleading
conclusions. If every wallet has exactly the same number of transactions, every
lookup has the same selectivity, and the planner's decision never changes - so
the benchmark cannot show the one thing worth showing: that an index helps for
some queries and not others.

This generator deliberately produces a realistic shape:

  * Transaction volume per wallet follows a power law. A small number of
    high-activity wallets hold a large share of the postings, while most
    wallets have only a handful. Real payment platforms look like this, and it
    means a lookup on a busy wallet and a lookup on a quiet wallet have very
    different selectivities.
  * Statuses are skewed: most transactions complete, a few fail, fewer are
    still pending.
  * Timestamps span nine months with intra-day and weekday variation, so range
    predicates on posted_at behave realistically.
  * Amounts are log-normal, not uniform - most payments are small, a few are
    large.

REPRODUCIBILITY
---------------
random.seed(SEED) is fixed. Re-running this script produces byte-identical
CSV files.

OUTPUT
------
CSV files for COPY. Bulk loading rather than INSERT is deliberate: the
integrity triggers built in Portfolio 1 fire per row, and 500,000 deferred
trigger invocations would dominate the load time. load_data.sql disables them
for the load and then re-validates every invariant afterwards, so correctness
is proven rather than assumed.

Usage:
    python3 generate_data.py --out ./data
"""

import argparse
import csv
import math
import os
import random
from datetime import datetime, timedelta, timezone

SEED = 8103
random.seed(SEED)

# --- Scale -----------------------------------------------------------------
N_CUSTOMERS      = 5_000
USD_WALLET_SHARE = 0.10        # fraction of customers who also hold a USD wallet
N_TRANSACTIONS   = 250_000
MONTHS_SPAN      = 9

# --- Existing data from Portfolio 1 seed ------------------------------------
# schema.sql + seed.sql are loaded first and are NOT modified. The generator
# appends to them, continuing the identity sequences.
EXISTING_CUSTOMERS    = 6
EXISTING_ACCOUNTS     = 12      # 4 internal + 8 wallets
EXISTING_TRANSACTIONS = 10
EXISTING_ENTRIES      = 20

# Internal control accounts created by seed.sql, in insertion order
ACC_BANK_NGN = 1
ACC_BANK_USD = 2
ACC_FEES_NGN = 3

FIRST_NAMES = [
    "Amaka", "Tunde", "Zainab", "Chidi", "Fatima", "Emeka", "Ngozi", "Yusuf",
    "Aisha", "Obinna", "Halima", "Kelechi", "Ibrahim", "Chiamaka", "Suleiman",
    "Adaeze", "Musa", "Oluwaseun", "Hauwa", "Chukwuemeka", "Bilikisu", "Segun",
    "Rukayat", "Nnamdi", "Maryam", "Folake", "Abubakar", "Uchenna", "Sadiya",
    "Temitope", "Danladi", "Chinelo", "Kabiru", "Omolara", "Gbenga", "Hadiza",
]
LAST_NAMES = [
    "Nwosu", "Bakare", "Ibrahim", "Okonkwo", "Yusuf", "Adeyemi", "Eze", "Bello",
    "Okafor", "Lawal", "Adebayo", "Mohammed", "Chukwu", "Sanni", "Obi", "Garba",
    "Olawale", "Nwachukwu", "Usman", "Afolabi", "Danjuma", "Ogundipe", "Aliyu",
    "Balogun", "Ezeh", "Shehu", "Oyelaran", "Madu", "Tijani", "Akinyemi",
]

CHANNELS = ["MOBILE_APP", "WEB", "USSD", "API"]
CHANNEL_WEIGHTS = [0.58, 0.22, 0.14, 0.06]


def zipf_weights(n, exponent=1.15):
    """Power-law weights over n items.

    Rank 1 is the busiest wallet. With exponent 1.15 roughly the top 1% of
    wallets carry about a third of all activity, which is the shape a real
    payment platform shows.
    """
    return [1.0 / ((r + 1) ** exponent) for r in range(n)]


def lognormal_amount(median, sigma, minor_unit=2):
    """Log-normal amount: many small payments, a few large ones."""
    value = random.lognormvariate(math.log(median), sigma)
    return round(min(value, median * 400), minor_unit)


def skewed_timestamp(start, end):
    """Timestamp with weekday and business-hour bias."""
    span = (end - start).total_seconds()
    # mild recency bias: platform activity grows over the period
    frac = random.random() ** 0.82
    ts = start + timedelta(seconds=span * frac)

    # push a share of activity into business hours
    if random.random() < 0.72:
        ts = ts.replace(hour=random.choices(
            range(24),
            weights=[1, 1, 1, 1, 1, 2, 4, 7, 10, 12, 13, 12,
                     11, 12, 13, 12, 11, 9, 8, 7, 6, 4, 3, 2],
        )[0])
    # weekends quieter: shift some Saturday/Sunday rows to midweek
    if ts.weekday() >= 5 and random.random() < 0.55:
        ts -= timedelta(days=random.randint(1, 3))
    return ts


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", default="./data")
    args = parser.parse_args()
    os.makedirs(args.out, exist_ok=True)

    end_date = datetime(2026, 11, 1, tzinfo=timezone.utc)
    start_date = end_date - timedelta(days=MONTHS_SPAN * 30)

    # ---------------------------------------------------------------- customers
    customers = []
    cid = EXISTING_CUSTOMERS
    for i in range(N_CUSTOMERS):
        cid += 1
        first = random.choice(FIRST_NAMES)
        last = random.choice(LAST_NAMES)
        ref = f"CUS-{cid:06d}"
        customers.append({
            "customer_id": cid,
            "customer_reference": ref,
            "first_name": first,
            "last_name": last,
            "email": f"{first.lower()}.{last.lower()}.{cid}@example.com",
            "phone": f"+234{random.randint(7000000000, 9099999999)}",
            "date_of_birth": (datetime(2008, 1, 1)
                              - timedelta(days=random.randint(0, 365 * 42))).date(),
            "kyc_tier": random.choices(
                ["TIER_0", "TIER_1", "TIER_2", "TIER_3"],
                weights=[0.08, 0.27, 0.45, 0.20])[0],
            "status": random.choices(
                ["ACTIVE", "SUSPENDED", "CLOSED"],
                weights=[0.955, 0.03, 0.015])[0],
        })

    # ----------------------------------------------------------------- accounts
    accounts = []            # rows to write
    ngn_wallets = []         # account_ids
    usd_wallets = []
    aid = EXISTING_ACCOUNTS
    for c in customers:
        aid += 1
        accounts.append({
            "account_id": aid,
            "account_reference": f"WAL-{c['customer_reference']}-NGN",
            "account_type": "CUSTOMER_WALLET",
            "customer_id": c["customer_id"],
            "currency_code": "NGN",
            "normal_balance": "CREDIT",
            "status": "ACTIVE" if c["status"] == "ACTIVE" else "FROZEN",
        })
        ngn_wallets.append(aid)

        if random.random() < USD_WALLET_SHARE:
            aid += 1
            accounts.append({
                "account_id": aid,
                "account_reference": f"WAL-{c['customer_reference']}-USD",
                "account_type": "CUSTOMER_WALLET",
                "customer_id": c["customer_id"],
                "currency_code": "USD",
                "normal_balance": "CREDIT",
                "status": "ACTIVE",
            })
            usd_wallets.append(aid)

    # Map wallet -> owning customer, needed for transactions.initiated_by_customer
    owner_of = {a["account_id"]: a["customer_id"] for a in accounts}

    # Power-law activity weights. Shuffle so the busiest wallets are not simply
    # the lowest account_ids, which would correlate activity with physical row
    # order and flatter any index unfairly.
    ngn_pool = ngn_wallets[:]
    random.shuffle(ngn_pool)
    ngn_weights = zipf_weights(len(ngn_pool))

    usd_pool = usd_wallets[:]
    random.shuffle(usd_pool)
    usd_weights = zipf_weights(len(usd_pool))

    # ------------------------------------------------------- transactions/entries
    transactions = []
    entries = []
    tid = EXISTING_TRANSACTIONS
    eid = EXISTING_ENTRIES

    def post(transaction_id, account_id, currency, direction, amount, ts):
        nonlocal eid
        eid += 1
        entries.append({
            "entry_id": eid,
            "transaction_id": transaction_id,
            "account_id": account_id,
            "currency_code": currency,
            "direction": direction,
            "amount": f"{amount:.4f}",
            "posted_at": ts.isoformat(),
        })

    for _ in range(N_TRANSACTIONS):
        tid += 1

        is_usd = random.random() < 0.06 and usd_pool
        if is_usd:
            currency = "USD"
            wallet = random.choices(usd_pool, weights=usd_weights, k=1)[0]
            bank = ACC_BANK_USD
            median_amt = 220.0
        else:
            currency = "NGN"
            wallet = random.choices(ngn_pool, weights=ngn_weights, k=1)[0]
            bank = ACC_BANK_NGN
            median_amt = 18_500.0

        ttype = random.choices(
            ["DEPOSIT", "TRANSFER", "WITHDRAWAL"],
            weights=[0.34, 0.47, 0.19])[0]

        # Status skew. PENDING and FAILED must post NOTHING to the ledger -
        # enforced by trg_transactions_posting_matches_status from Portfolio 1.
        status = random.choices(
            ["COMPLETED", "FAILED", "PENDING"],
            weights=[0.930, 0.052, 0.018])[0]

        ts = skewed_timestamp(start_date, end_date)
        settled = ts + timedelta(seconds=random.randint(2, 900))
        amount = lognormal_amount(median_amt, 0.95)
        if amount <= 0:
            amount = 100.00

        transactions.append({
            "transaction_id": tid,
            "transaction_reference": f"KP-2026-{tid:06d}",
            "transaction_type": ttype,
            "status": status,
            "channel": random.choices(CHANNELS, weights=CHANNEL_WEIGHTS, k=1)[0],
            "currency_code": currency,
            "initiated_by_customer": owner_of[wallet],
            "reverses_transaction": "",
            "narration": f"{ttype.title()} via platform",
            "initiated_at": ts.isoformat(),
            "settled_at": "" if status == "PENDING" else settled.isoformat(),
        })

        if status != "COMPLETED":
            continue       # no postings for PENDING or FAILED

        if ttype == "DEPOSIT":
            post(tid, bank,   currency, "DEBIT",  amount, settled)
            post(tid, wallet, currency, "CREDIT", amount, settled)

        elif ttype == "WITHDRAWAL":
            post(tid, wallet, currency, "DEBIT",  amount, settled)
            post(tid, bank,   currency, "CREDIT", amount, settled)

        else:  # TRANSFER
            pool = usd_pool if is_usd else ngn_pool
            weights = usd_weights if is_usd else ngn_weights
            recipient = wallet
            for _ in range(8):                      # avoid self-transfer
                recipient = random.choices(pool, weights=weights, k=1)[0]
                if recipient != wallet:
                    break
            if recipient == wallet:
                post(tid, bank,   currency, "DEBIT",  amount, settled)
                post(tid, wallet, currency, "CREDIT", amount, settled)
                continue

            # 62% of NGN transfers carry a fee; USD transfers do not, since
            # there is no USD fee-revenue account in the seed.
            fee = 0.0
            if currency == "NGN" and random.random() < 0.62:
                fee = round(min(max(amount * 0.0045, 10.0), 250.0), 2)

            post(tid, wallet,    currency, "DEBIT",  amount + fee, settled)
            post(tid, recipient, currency, "CREDIT", amount,       settled)
            if fee > 0:
                post(tid, ACC_FEES_NGN, currency, "CREDIT", fee, settled)

    # --------------------------------------------------------------- write CSVs
    def write(name, rows, fields):
        path = os.path.join(args.out, name)
        with open(path, "w", newline="") as fh:
            w = csv.DictWriter(fh, fieldnames=fields)
            w.writerows(rows)
        return path

    write("customers.csv", customers, [
        "customer_id", "customer_reference", "first_name", "last_name",
        "email", "phone", "date_of_birth", "kyc_tier", "status"])
    write("accounts.csv", accounts, [
        "account_id", "account_reference", "account_type", "customer_id",
        "currency_code", "normal_balance", "status"])
    write("transactions.csv", transactions, [
        "transaction_id", "transaction_reference", "transaction_type", "status",
        "channel", "currency_code", "initiated_by_customer",
        "reverses_transaction", "narration", "initiated_at", "settled_at"])
    write("ledger_entries.csv", entries, [
        "entry_id", "transaction_id", "account_id", "currency_code",
        "direction", "amount", "posted_at"])

    # ------------------------------------------------------------- distribution
    counts = {}
    for e in entries:
        counts[e["account_id"]] = counts.get(e["account_id"], 0) + 1
    wallet_counts = sorted(
        (n for a, n in counts.items() if a > EXISTING_ACCOUNTS), reverse=True)
    total_wallet_entries = sum(wallet_counts) or 1
    top1 = max(1, len(wallet_counts) // 100)

    print(f"seed                 : {SEED}")
    print(f"customers            : {len(customers):,}")
    print(f"accounts             : {len(accounts):,} "
          f"({len(ngn_wallets):,} NGN, {len(usd_wallets):,} USD)")
    print(f"transactions         : {len(transactions):,}")
    print(f"ledger entries       : {len(entries):,}")
    print(f"date span            : {start_date.date()} .. {end_date.date()}")
    print()
    print("Postings per wallet (skew check)")
    print(f"  busiest wallet     : {wallet_counts[0]:,}")
    print(f"  median wallet      : {wallet_counts[len(wallet_counts)//2]:,}")
    print(f"  quietest wallet    : {wallet_counts[-1]:,}")
    print(f"  top 1% of wallets  : "
          f"{100*sum(wallet_counts[:top1])/total_wallet_entries:.1f}% of all postings")
    print(f"  wallets with 0     : {len(ngn_wallets)+len(usd_wallets)-len(wallet_counts):,}")


if __name__ == "__main__":
    main()
