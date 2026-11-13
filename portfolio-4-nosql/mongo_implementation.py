#!/usr/bin/env python3
"""
KineticsPay - MongoDB document layer
Portfolio 4: NoSQL and Advanced Data Models

MIT 8103 Advanced Database Systems
Biliaminu Abdulfarid (301918844)

WHICH ENGINE THIS RUNS AGAINST - READ THIS FIRST
------------------------------------------------
A real mongod could not be installed in the environment this was built
in: fastdl.mongodb.org, repo.mongodb.org and GitHub release downloads are
all blocked by the network policy. Rather than present a design with no
execution evidence, the pipelines below are executed against **mongomock
4.3.0**, an in-memory MongoDB-compatible implementation of the pymongo
API.

What that means honestly:

  * The documents, indexes, queries and aggregation pipelines are real
    and really execute. The outputs in evidence/ are genuine results,
    not transcribed expectations.
  * The same code runs unchanged against a real server - swap
    mongomock.MongoClient() for pymongo.MongoClient(ATLAS_URI). The
    equivalent mongosh scripts are in mongosh/.
  * mongomock does NOT implement the storage engine, the query planner,
    $jsonSchema validation, replica sets or multi-document transactions.
    So NOTHING here should be read as evidence about MongoDB
    PERFORMANCE, and the transaction discussion in section 6 is argued
    from MongoDB's documented semantics, with the parts mongomock cannot
    execute clearly marked.

Usage:
    python3 mongo_implementation.py
"""

import json
import os
import sys
from datetime import datetime

import mongomock
from jsonschema import Draft7Validator

DATA = "./data"
SEP = "=" * 62


def banner(title):
    print(f"\n{SEP}\n{title}\n{SEP}")


def _round(obj, nd=2):
    """Round floats for display. mongomock has no $round, so pipelines
    emit raw quotients and the rounding happens here."""
    if isinstance(obj, float):
        return round(obj, nd)
    if isinstance(obj, dict):
        return {k: _round(v, nd) for k, v in obj.items()}
    if isinstance(obj, list):
        return [_round(v, nd) for v in obj]
    return obj


def show(rows, limit=10):
    rows = list(rows)
    if not rows:
        print("  (no rows)")
        return
    for r in rows[:limit]:
        print("  " + json.dumps(_round(r), default=str))
    if len(rows) > limit:
        print(f"  ... {len(rows)-limit:,} more")


# =====================================================================
# 1. Schema design and validation
# =====================================================================
TRANSACTION_EVENT_SCHEMA = {
    "bsonType": "object",
    "required": ["_id", "transaction_id", "type", "status", "currency",
                 "amount", "initiated_at", "metadata"],
    "properties": {
        "_id":            {"bsonType": "string",
                           "pattern": "^KP-[0-9]{4}-[0-9]{6}$"},
        "transaction_id": {"bsonType": "int"},
        "type":           {"enum": ["DEPOSIT", "WITHDRAWAL", "TRANSFER",
                                    "FEE", "REVERSAL"]},
        "status":         {"enum": ["PENDING", "COMPLETED", "FAILED", "REVERSED"]},
        "currency":       {"bsonType": "string", "pattern": "^[A-Z]{3}$"},
        "amount":         {"bsonType": "double", "minimum": 0},
        "metadata": {
            "bsonType": "object",
            "required": ["channel"],
            "properties": {
                "channel": {"enum": ["MOBILE_APP", "WEB", "USSD", "API", "INTERNAL"]},
                "risk": {
                    "bsonType": "object",
                    "properties": {
                        "score":  {"bsonType": "double", "minimum": 0, "maximum": 100},
                        "action": {"enum": ["ALLOW", "CHALLENGE", "REVIEW"]},
                    },
                },
            },
        },
        "state_history": {
            "bsonType": "array",
            "items": {"bsonType": "object", "required": ["state", "at"]},
        },
    },
}

# JSON Schema equivalent, for local validation. $jsonSchema is a MongoDB
# server feature that mongomock does not implement, so validation is run
# here with the jsonschema library against the same rules - which is
# arguably better evidence, since every document is checked rather than
# only those the server happened to reject.
JSON_SCHEMA = {
    "type": "object",
    "required": ["_id", "transaction_id", "type", "status", "currency",
                 "amount", "initiated_at", "metadata"],
    "properties": {
        "_id":            {"type": "string", "pattern": "^KP-[0-9]{4}-[0-9]{6}$"},
        "transaction_id": {"type": "integer"},
        "type":           {"enum": ["DEPOSIT", "WITHDRAWAL", "TRANSFER", "FEE", "REVERSAL"]},
        "status":         {"enum": ["PENDING", "COMPLETED", "FAILED", "REVERSED"]},
        "currency":       {"type": "string", "pattern": "^[A-Z]{3}$"},
        "amount":         {"type": "number", "minimum": 0},
        "metadata": {
            "type": "object",
            "required": ["channel"],
            "properties": {
                "channel": {"enum": ["MOBILE_APP", "WEB", "USSD", "API", "INTERNAL"]},
                "risk": {
                    "type": "object",
                    "properties": {
                        "score":  {"type": "number", "minimum": 0, "maximum": 100},
                        "action": {"enum": ["ALLOW", "CHALLENGE", "REVIEW"]},
                    },
                },
            },
        },
    },
}


def main():
    if not os.path.exists(f"{DATA}/transaction_events.json"):
        sys.exit("run export_documents.py first")

    with open(f"{DATA}/transaction_events.json") as fh:
        events = json.load(fh)
    with open(f"{DATA}/wallet_snapshots.json") as fh:
        snapshots = json.load(fh)

    client = mongomock.MongoClient()
    db = client.kineticspay

    banner("ENGINE AND PROVENANCE")
    print(f"  engine              : mongomock {mongomock.__version__} "
          f"(in-memory, pymongo-compatible)")
    print(f"  why not mongod      : binaries unreachable from this sandbox; "
          f"see the module docstring")
    print(f"  documents           : derived from the PostgreSQL ledger of "
          f"Portfolios 1-3")
    print(f"  transaction_events  : {len(events):,}")
    print(f"  wallet_snapshots    : {len(snapshots):,}")
    print(f"  run at              : {datetime.utcnow().isoformat()}Z")

    # =================================================================
    banner("1. SCHEMA VALIDATION")
    # =================================================================
    print("""  MongoDB is schema-FLEXIBLE, not schema-LESS. A payment event
  collection still needs rules; what it does not need is a fixed column
  for every optional field.

  The $jsonSchema validator is in mongosh/01-create-collections.js and
  is reproduced here as an equivalent JSON Schema, checked against every
  document rather than only those a server rejects.""")

    validator = Draft7Validator(JSON_SCHEMA)
    failures = []
    for doc in events:
        for err in validator.iter_errors(doc):
            failures.append((doc["_id"], err.message))
            break
    print(f"\n  documents validated : {len(events):,}")
    print(f"  violations          : {len(failures):,}")
    if failures:
        for ref, msg in failures[:5]:
            print(f"    {ref}: {msg}")

    print("\n  Negative control - three deliberately invalid documents:")
    for bad, label in [
        ({"_id": "NOT-A-REF", "transaction_id": 1, "type": "DEPOSIT",
          "status": "COMPLETED", "currency": "NGN", "amount": 1.0,
          "initiated_at": "x", "metadata": {"channel": "WEB"}}, "malformed _id"),
        ({"_id": "KP-2026-000001", "transaction_id": 1, "type": "TELEPORT",
          "status": "COMPLETED", "currency": "NGN", "amount": 1.0,
          "initiated_at": "x", "metadata": {"channel": "WEB"}}, "unknown type"),
        ({"_id": "KP-2026-000001", "transaction_id": 1, "type": "DEPOSIT",
          "status": "COMPLETED", "currency": "NGN", "amount": -5.0,
          "initiated_at": "x", "metadata": {"channel": "SMOKE_SIGNAL"}},
         "negative amount + bad channel"),
    ]:
        errs = [e.message for e in validator.iter_errors(bad)]
        print(f"    {label:32s} -> REJECTED ({len(errs)} violation(s)): {errs[0][:60]}")

    # =================================================================
    banner("2. LOAD AND INDEX")
    # =================================================================
    db.transaction_events.insert_many(events)
    db.wallet_snapshots.insert_many(snapshots)

    db.transaction_events.create_index([("customer_id", 1), ("initiated_at", -1)],
                                       name="customer_recent")
    db.transaction_events.create_index([("status", 1), ("initiated_at", -1)],
                                       name="status_recent")
    db.transaction_events.create_index([("metadata.channel", 1)], name="channel")
    db.transaction_events.create_index([("metadata.risk.action", 1)],
                                       name="risk_action", sparse=True)
    db.wallet_snapshots.create_index([("customer.reference", 1)], name="customer_ref")

    print("  transaction_events indexes:")
    for name in db.transaction_events.index_information():
        print(f"    {name}")
    print("  wallet_snapshots indexes:")
    for name in db.wallet_snapshots.index_information():
        print(f"    {name}")
    print("""
  Note 'risk_action' is SPARSE: only 18% of events carry a risk block,
  so the index holds only those documents. The relational equivalent in
  Portfolio 2 was a PARTIAL index on transactions(status) - the same
  idea reached from a different direction.""")

    # =================================================================
    banner("3. QUERIES THE DOCUMENT MODEL MAKES EASY")
    # =================================================================
    print("  3.1  Events from Android devices on 5G  (no join, no schema change)")
    show(db.transaction_events.find(
        {"metadata.device.platform": "android", "metadata.network.type": "5g"},
        {"_id": 1, "amount": 1, "metadata.device.app_version": 1}).limit(3))

    print("\n  3.2  High-risk events that were challenged")
    show(db.transaction_events.find(
        {"metadata.risk.score": {"$gt": 90}, "metadata.risk.action": "CHALLENGE"},
        {"_id": 1, "amount": 1, "metadata.risk": 1}).limit(3))

    print("\n  3.3  Events carrying a specific risk signal (array membership)")
    show(db.transaction_events.find(
        {"metadata.risk.signals": "GEO_MISMATCH"},
        {"_id": 1, "metadata.risk.signals": 1}).limit(3))

    print("\n  3.4  3-D Secure failures on web (a field that exists only for WEB)")
    show(db.transaction_events.find(
        {"metadata.three_d_secure.outcome": "FAILED"},
        {"_id": 1, "metadata.three_d_secure": 1}).limit(3))

    print("""
  Each of these reaches into a field that exists on only a subset of
  documents. In the relational schema every one would need either a
  nullable column, a side table, or a JSONB column queried with ->> -
  and the first two change the schema for every row.""")

    # =================================================================
    banner("4. AGGREGATION PIPELINES")
    # =================================================================
    print("  4.1  Failure rate by channel  (compare: Portfolio 2 queries.sql Q5)")
    show(db.transaction_events.aggregate([
        {"$group": {
            "_id": "$metadata.channel",
            "attempted": {"$sum": 1},
            "failed": {"$sum": {"$cond": [{"$eq": ["$status", "FAILED"]}, 1, 0]}},
            "value": {"$sum": "$amount"},
        }},
        {"$project": {
            "attempted": 1, "failed": 1,
            # NOTE: $round is not implemented by mongomock, so the raw
            # quotient is produced here and rounded when displayed. On a
            # real server this stage would read {"$round": [expr, 2]}.
            "failure_rate_pct": {"$multiply": [{"$divide": ["$failed", "$attempted"]}, 100]},
            "avg_value": {"$divide": ["$value", "$attempted"]},
        }},
        {"$sort": {"attempted": -1}},
    ]))

    print("\n  4.2  Monthly volume by type  (compare: Q2)")
    show(db.transaction_events.aggregate([
        {"$group": {
            "_id": {"month": {"$substr": ["$initiated_at", 0, 7]}, "type": "$type"},
            "n": {"$sum": 1},
            "value": {"$sum": "$amount"},
        }},
        {"$sort": {"_id.month": -1, "n": -1}},
        {"$limit": 8},
    ]))

    print("\n  4.3  Decline reasons ranked  (NO relational equivalent without a side table)")
    show(db.transaction_events.aggregate([
        {"$match": {"metadata.failure.code": {"$exists": True}}},
        {"$group": {"_id": "$metadata.failure.code",
                    "n": {"$sum": 1},
                    "retryable": {"$sum": {"$cond": ["$metadata.failure.retryable", 1, 0]}},
                    "value_lost": {"$sum": "$amount"}}},
        {"$sort": {"n": -1}},
    ]))

    print("\n  4.4  Risk signals unwound from their array")
    show(db.transaction_events.aggregate([
        {"$match": {"metadata.risk.signals": {"$exists": True}}},
        {"$unwind": "$metadata.risk.signals"},
        {"$group": {"_id": "$metadata.risk.signals",
                    "n": {"$sum": 1},
                    "avg_score": {"$avg": "$metadata.risk.score"}}},
        {"$project": {"n": 1, "avg_score": 1}},
        {"$sort": {"n": -1}},
    ]))

    print("\n  4.5  Settlement latency percentiles by channel")
    show(db.transaction_events.aggregate([
        {"$match": {"latency_ms": {"$exists": True}, "status": "COMPLETED"}},
        {"$group": {"_id": "$metadata.channel",
                    "n": {"$sum": 1},
                    "avg_ms": {"$avg": "$latency_ms"},
                    "max_ms": {"$max": "$latency_ms"},
                    "min_ms": {"$min": "$latency_ms"}}},
        {"$project": {"n": 1, "avg_ms": 1, "max_ms": 1, "min_ms": 1}},
        {"$sort": {"avg_ms": -1}},
    ]))

    print("\n  4.6  $facet - several independent summaries in ONE pass over the data")
    res = list(db.transaction_events.aggregate([{"$facet": {
        "by_status": [{"$group": {"_id": "$status", "n": {"$sum": 1}}},
                      {"$sort": {"n": -1}}],
        "by_currency": [{"$group": {"_id": "$currency", "n": {"$sum": 1}}}],
        "biometric_adoption": [
            {"$match": {"metadata.device.biometric_used": {"$exists": True}}},
            {"$group": {"_id": "$metadata.device.biometric_used", "n": {"$sum": 1}}}],
        "compliance_flagged": [
            {"$match": {"metadata.compliance.threshold_review": True}},
            {"$count": "n"}],
    }}]))
    for key, rows in res[0].items():
        print(f"    {key}:")
        for r in rows:
            print("      " + json.dumps(_round(r), default=str))

    print("\n  4.7  $lookup - joining events to wallet snapshots")
    show(db.wallet_snapshots.aggregate([
        {"$match": {"posting_count": {"$gt": 500}}},
        {"$lookup": {"from": "transaction_events", "localField": "customer.reference",
                     "foreignField": "metadata.api.client_id", "as": "api_events"}},
        {"$project": {"customer.name": 1, "balance": 1, "posting_count": 1,
                      "api_event_count": {"$size": "$api_events"}}},
        {"$sort": {"posting_count": -1}},
        {"$limit": 3},
    ]))
    print("""    ($lookup works, but note it found nothing to join on here - the
     fields are not related. That is the point of 4.8.)""")

    print("\n  4.8  The embedded read model: one lookup serves the whole home screen")
    doc = db.wallet_snapshots.find_one({"recent_activity.4": {"$exists": True}})
    if doc:
        print(f"    _id              : {doc['_id']}")
        print(f"    customer         : {doc['customer']['name']}")
        print(f"    balance          : {doc['balance']:,.2f} {doc['currency']}")
        print(f"    recent_activity  : {len(doc['recent_activity'])} embedded postings")
        print(f"    documents read   : 1")
        print(f"    relational equiv : wallets view (aggregate over ledger_entries)")
        print(f"                       + join customers + top-5 postings = 3 relations")

    # =================================================================
    banner("5. EMBEDDING VERSUS REFERENCING")
    # =================================================================
    print("""  The same information, modelled two ways, measured on document size
  and read count.""")
    import statistics
    emb = [len(json.dumps(d, default=str)) for d in snapshots]
    ev = [len(json.dumps(d, default=str)) for d in events]
    print(f"\n    wallet_snapshots (embedded recent activity)")
    print(f"      mean document size  : {statistics.mean(emb):,.0f} bytes")
    print(f"      max  document size  : {max(emb):,} bytes")
    print(f"      reads for home screen: 1")
    print(f"\n    transaction_events (referenced by customer_id)")
    print(f"      mean document size  : {statistics.mean(ev):,.0f} bytes")
    print(f"      max  document size  : {max(ev):,} bytes")
    print(f"      reads for full history: 1 query, N documents")
    busiest = max(snapshots, key=lambda d: d["posting_count"])
    print(f"""
    Why recent_activity is capped at 5 and not unbounded:
      busiest wallet has {busiest['posting_count']:,} postings.
      Embedding all of them would put that wallet's document at roughly
      {busiest['posting_count'] * 120 / 1024 / 1024:.1f} MB, against MongoDB's hard 16 MB
      document limit - and every balance read would transfer all of it.

    This is the unbounded-array anti-pattern. The rule applied here: embed
    what is read TOGETHER and bounded; reference what GROWS.""")

    # =================================================================
    banner("6. CONCURRENCY: WHAT SINGLE-DOCUMENT ATOMICITY BUYS")
    # =================================================================
    print("""  Portfolio 3 demonstrated a real double-spend race against
  PostgreSQL using two concurrent processes. What follows is NOT a
  wall-clock race - mongomock is in-process and single-threaded, so a
  genuine race cannot be staged here. It demonstrates the SEMANTICS of
  MongoDB's guarantee, executed, with the limits stated.""")

    db.wallet_snapshots.update_one({"_id": "WAL-TEST-A-NGN"},
                                   {"$set": {"balance": 50000.0}}, upsert=True)

    print("\n  6.1  Guarded update - the compare-and-set that DOES work")
    print("       update_one({_id, balance: {$gte: 35000}}, {$inc: {balance: -35000}})")
    for attempt in (1, 2):
        r = db.wallet_snapshots.update_one(
            {"_id": "WAL-TEST-A-NGN", "balance": {"$gte": 35000}},
            {"$inc": {"balance": -35000}})
        bal = db.wallet_snapshots.find_one({"_id": "WAL-TEST-A-NGN"})["balance"]
        verdict = "APPLIED" if r.modified_count else "REFUSED (guard failed)"
        print(f"       withdrawal {attempt}: matched={r.matched_count} "
              f"modified={r.modified_count} -> {verdict}, balance now {bal:,.2f}")
    print("""
       The filter and the update are ONE atomic operation on ONE
       document. A second writer cannot slip between the read and the
       write, because there is no gap: there is no separate read. This
       is genuinely strong, and it is the idiomatic MongoDB answer to
       the Portfolio 3 race.""")

    print("\n  6.2  Where it stops working: a transfer touches TWO documents")
    db.wallet_snapshots.update_one({"_id": "WAL-TEST-A-NGN"},
                                   {"$set": {"balance": 50000.0}})
    db.wallet_snapshots.update_one({"_id": "WAL-TEST-B-NGN"},
                                   {"$set": {"balance": 10000.0}}, upsert=True)
    a0 = db.wallet_snapshots.find_one({"_id": "WAL-TEST-A-NGN"})["balance"]
    b0 = db.wallet_snapshots.find_one({"_id": "WAL-TEST-B-NGN"})["balance"]
    print(f"       before: A={a0:,.2f}  B={b0:,.2f}  total={a0+b0:,.2f}")

    debit = db.wallet_snapshots.update_one(
        {"_id": "WAL-TEST-A-NGN", "balance": {"$gte": 20000}},
        {"$inc": {"balance": -20000}})
    print(f"       step 1 debit A 20,000 : modified={debit.modified_count}")
    credit = db.wallet_snapshots.update_one(
        {"_id": "WAL-TEST-C-DOES-NOT-EXIST"}, {"$inc": {"balance": 20000}})
    print(f"       step 2 credit B 20,000: modified={credit.modified_count}  "
          f"<-- FAILED (recipient missing)")
    a1 = db.wallet_snapshots.find_one({"_id": "WAL-TEST-A-NGN"})["balance"]
    b1 = db.wallet_snapshots.find_one({"_id": "WAL-TEST-B-NGN"})["balance"]
    print(f"       after : A={a1:,.2f}  B={b1:,.2f}  total={a1+b1:,.2f}")
    print(f"       NGN {a0+b0-a1-b1:,.2f} HAS BEEN DESTROYED.")
    print("""
       Step 1 committed. Step 2 failed. There is no enclosing
       transaction to roll step 1 back, so the money is simply gone.
       The relational ledger cannot reach this state: trg_ledger_entries
       _balanced rejects any transaction whose debits and credits do not
       sum to zero, at COMMIT.""")

    print("""
  6.3  What MongoDB actually offers here - stated accurately

       It is NOT true that MongoDB has no multi-document transactions.
       Since 4.0 it supports multi-document ACID transactions on replica
       sets, and since 4.2 across sharded clusters. The accurate claims
       are narrower:

         * Single-document atomicity is the DEFAULT and the idiomatic
           design target. Multi-document transactions are an escape
           hatch that the data model is supposed to make unnecessary.
         * They require a replica set; a standalone mongod cannot run
           them.
         * They carry real cost: a 60-second default runtime limit,
           WiredTiger cache pressure, and under contention a
           TransientTransactionError the application must retry - the
           same retry obligation SERIALIZABLE imposed in Portfolio 3.
         * mongomock implements none of this, so this script CANNOT
           demonstrate it. That is a limitation of the evidence here,
           not a claim about MongoDB.

       The design conclusion stands either way: if a workload needs
       multi-document transactions constantly, the document model is
       being used against its grain, and the ledger belongs in
       PostgreSQL. See analysis.md section 5.""")

    # =================================================================
    banner("7. COLLECTION STATISTICS")
    # =================================================================
    for name in ("transaction_events", "wallet_snapshots"):
        coll = db[name]
        print(f"  {name:22s} {coll.count_documents({}):>8,} documents")
    print(f"\n  status distribution:")
    show(db.transaction_events.aggregate([
        {"$group": {"_id": "$status", "n": {"$sum": 1}}}, {"$sort": {"n": -1}}]))

    print(f"\n{SEP}\nrun complete\n{SEP}")


if __name__ == "__main__":
    main()
