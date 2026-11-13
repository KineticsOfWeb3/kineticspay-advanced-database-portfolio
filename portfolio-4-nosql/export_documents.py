#!/usr/bin/env python3
"""
KineticsPay - build the document collections from the relational ledger
Portfolio 4: NoSQL and Advanced Data Models

MIT 8103 Advanced Database Systems
Biliaminu Abdulfarid (301918844)

The documents here are NOT invented. They are derived from the same
528,647-entry PostgreSQL ledger built in Portfolios 1-3, so the NoSQL
model describes the same case study and can be compared against it
directly.

Two collections are produced:

  transaction_events   one document per payment attempt, carrying the
                       sparse, schema-variable metadata that is awkward
                       in a relational table: device, channel, network,
                       risk signals, 3-D Secure outcome, retry history.
                       Shape varies by channel, which is the point.

  wallet_snapshots     a denormalised READ MODEL for the app home
                       screen: customer identity, balance, and the last
                       few transactions, embedded in one document so the
                       screen is a single lookup by _id.

Usage:
    python3 export_documents.py --out ./data --limit 50000
"""

import argparse
import json
import os
import random
import subprocess
from datetime import datetime, timedelta

SEED = 8103
random.seed(SEED)

PSQL = ["psql", "-h", "localhost", "-U", "postgres", "-d", "kineticspay",
        "-X", "-t", "-A", "-F", "\x1f", "-c"]

# Metadata vocabularies. Different channels carry different fields - that
# asymmetry is exactly what a document store handles well and what a
# relational table handles with a forest of nullable columns.
DEVICES   = ["android", "ios", "web-chrome", "web-safari", "web-firefox"]
CARRIERS  = ["MTN", "Airtel", "Glo", "9mobile"]
BANKS     = ["GTBank", "Access", "Zenith", "UBA", "First Bank", "Kuda", "Opay"]
CITIES    = ["Lagos", "Abuja", "Port Harcourt", "Ibadan", "Kano", "Benin City"]
DECLINES  = ["INSUFFICIENT_FUNDS", "CARD_EXPIRED", "DO_NOT_HONOUR",
             "LIMIT_EXCEEDED", "ISSUER_UNAVAILABLE", "SUSPECTED_FRAUD"]


def query(sql):
    out = subprocess.run(PSQL + [sql], capture_output=True, text=True, check=True)
    rows = []
    for line in out.stdout.strip().split("\n"):
        if line:
            rows.append(line.split("\x1f"))
    return rows


def build_metadata(channel, status, amount):
    """Channel-dependent metadata. Deliberately heterogeneous."""
    meta = {
        "channel": channel,
        "ip_address": f"197.{random.randint(0,255)}.{random.randint(0,255)}.{random.randint(1,254)}",
        "location": {"city": random.choice(CITIES), "country": "NG"},
    }

    if channel == "MOBILE_APP":
        meta["device"] = {
            "platform": random.choice(["android", "ios"]),
            "os_version": f"{random.randint(11,18)}.{random.randint(0,6)}",
            "app_version": f"4.{random.randint(0,9)}.{random.randint(0,20)}",
            "device_id": f"dev_{random.getrandbits(40):010x}",
            "biometric_used": random.random() < 0.72,
        }
        meta["network"] = {"type": random.choice(["wifi", "4g", "5g"]),
                           "carrier": random.choice(CARRIERS)}

    elif channel == "WEB":
        meta["device"] = {"platform": random.choice(["web-chrome", "web-safari", "web-firefox"]),
                          "user_agent_hash": f"ua_{random.getrandbits(32):08x}"}
        meta["three_d_secure"] = {
            "attempted": True,
            "outcome": random.choices(["AUTHENTICATED", "ATTEMPTED", "FAILED"],
                                      weights=[0.86, 0.09, 0.05])[0],
            "version": random.choice(["2.1.0", "2.2.0"]),
        }

    elif channel == "USSD":
        meta["ussd"] = {"short_code": f"*{random.randint(100,999)}#",
                        "carrier": random.choice(CARRIERS),
                        "session_steps": random.randint(3, 7)}
        # no device block at all - USSD has no app

    elif channel == "API":
        meta["api"] = {"client_id": f"cli_{random.getrandbits(24):06x}",
                       "version": random.choice(["v1", "v2"]),
                       "idempotency_key": f"idem_{random.getrandbits(48):012x}"}

    # Risk signals are attached to a minority of events only.
    if random.random() < 0.18:
        meta["risk"] = {
            "score": round(random.uniform(0, 100), 1),
            "signals": random.sample(
                ["NEW_DEVICE", "VELOCITY", "GEO_MISMATCH", "LARGE_AMOUNT",
                 "NIGHT_HOURS", "NEW_BENEFICIARY"],
                k=random.randint(1, 3)),
            "action": random.choices(["ALLOW", "CHALLENGE", "REVIEW"],
                                     weights=[0.72, 0.21, 0.07])[0],
        }

    if status == "FAILED":
        meta["failure"] = {
            "code": random.choice(DECLINES),
            "retryable": random.random() < 0.6,
            "attempts": random.randint(1, 3),
            "issuer": random.choice(BANKS),
        }

    if amount and float(amount) > 150000:
        meta["compliance"] = {"threshold_review": True,
                              "reviewed_by": f"ops_{random.randint(1,12):03d}"}
    return meta


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="./data")
    ap.add_argument("--limit", type=int, default=50000)
    args = ap.parse_args()
    os.makedirs(args.out, exist_ok=True)

    # ---------------------------------------------------------------
    # transaction_events
    # ---------------------------------------------------------------
    print(f"reading up to {args.limit:,} transactions from PostgreSQL ...")
    rows = query(f"""
        SELECT t.transaction_id, t.transaction_reference, t.transaction_type,
               t.status, t.channel, t.currency_code,
               COALESCE(t.initiated_by_customer::TEXT, ''),
               t.initiated_at, COALESCE(t.settled_at::TEXT, ''),
               COALESCE((SELECT SUM(le.amount) FROM ledger_entries le
                         WHERE le.transaction_id = t.transaction_id
                           AND le.direction = 'DEBIT')::TEXT, '0')
        FROM transactions t
        WHERE t.transaction_reference LIKE 'KP-2026-%'
        ORDER BY t.transaction_id
        LIMIT {args.limit};
    """)

    events = []
    for (tid, ref, ttype, status, channel, ccy, cust, initiated, settled, debit) in rows:
        amount = float(debit) if debit else 0.0
        doc = {
            "_id": ref,
            "transaction_id": int(tid),
            "type": ttype,
            "status": status,
            "currency": ccy,
            "amount": round(amount, 2),
            "customer_id": int(cust) if cust else None,
            "initiated_at": initiated,
            "metadata": build_metadata(channel, status, amount),
        }
        if settled:
            doc["settled_at"] = settled
            try:
                d0 = datetime.fromisoformat(initiated)
                d1 = datetime.fromisoformat(settled)
                doc["latency_ms"] = int((d1 - d0).total_seconds() * 1000)
            except ValueError:
                pass
        # Event history: a small embedded array, variable length.
        hist = [{"state": "INITIATED", "at": initiated}]
        if status == "COMPLETED":
            hist += [{"state": "AUTHORISED", "at": initiated},
                     {"state": "SETTLED", "at": settled or initiated}]
        elif status == "FAILED":
            hist += [{"state": "DECLINED", "at": settled or initiated,
                      "reason": doc["metadata"].get("failure", {}).get("code")}]
        doc["state_history"] = hist
        events.append(doc)

    # ---------------------------------------------------------------
    # wallet_snapshots - the denormalised read model
    # ---------------------------------------------------------------
    print("building wallet snapshots ...")
    wrows = query("""
        SELECT w.wallet_id, w.wallet_reference, w.customer_reference,
               w.customer_name, w.currency_code, w.balance::TEXT,
               w.status, COALESCE(w.last_posted_at::TEXT,''), w.entry_count
        FROM wallets w
        ORDER BY w.wallet_id;
    """)

    recent = {}
    for (wid, le_tid, direction, amount, posted) in query("""
        SELECT le.account_id, le.transaction_id, le.direction,
               le.amount::TEXT, le.posted_at::TEXT
        FROM (SELECT le.*, ROW_NUMBER() OVER (PARTITION BY le.account_id
                                              ORDER BY le.posted_at DESC) rn
              FROM ledger_entries le) le
        JOIN accounts a ON a.account_id = le.account_id
        WHERE le.rn <= 5 AND a.account_type = 'CUSTOMER_WALLET';
    """):
        recent.setdefault(int(wid), []).append({
            "transaction_id": int(le_tid),
            "direction": direction,
            "amount": round(float(amount), 2),
            "posted_at": posted,
        })

    snapshots = []
    for (wid, wref, cref, cname, ccy, bal, status, last, n) in wrows:
        snapshots.append({
            "_id": wref,
            "wallet_id": int(wid),
            "customer": {"reference": cref, "name": cname},
            "currency": ccy,
            "balance": round(float(bal), 2),
            "status": status,
            "posting_count": int(n),
            "last_posted_at": last or None,
            "recent_activity": recent.get(int(wid), []),
            "snapshot_at": datetime.utcnow().isoformat(),
        })

    # ---------------------------------------------------------------
    with open(os.path.join(args.out, "transaction_events.json"), "w") as fh:
        json.dump(events, fh)
    with open(os.path.join(args.out, "wallet_snapshots.json"), "w") as fh:
        json.dump(snapshots, fh)

    # Field-presence report: evidence that the documents really are
    # heterogeneous rather than a uniform table in JSON clothing.
    fields = {}
    for e in events:
        for path in ("metadata.device", "metadata.network", "metadata.ussd",
                     "metadata.api", "metadata.three_d_secure", "metadata.risk",
                     "metadata.failure", "metadata.compliance", "latency_ms"):
            parts = path.split(".")
            cur = e
            ok = True
            for p in parts:
                if isinstance(cur, dict) and p in cur and cur[p] is not None:
                    cur = cur[p]
                else:
                    ok = False
                    break
            if ok:
                fields[path] = fields.get(path, 0) + 1

    print(f"\nseed                : {SEED}")
    print(f"transaction_events  : {len(events):,} documents")
    print(f"wallet_snapshots    : {len(snapshots):,} documents")
    print("\nField presence across transaction_events (the heterogeneity):")
    for k in sorted(fields, key=lambda x: -fields[x]):
        print(f"  {k:28s} {fields[k]:7,}  ({100*fields[k]/len(events):5.1f}%)")
    absent = len(events) - fields.get("metadata.device", 0)
    print(f"\n  documents with NO device block : {absent:,} "
          f"({100*absent/len(events):.1f}%)  <- USSD and API have no device")


if __name__ == "__main__":
    main()
