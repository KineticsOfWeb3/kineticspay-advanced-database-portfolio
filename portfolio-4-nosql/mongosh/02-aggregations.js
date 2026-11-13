/* =====================================================================
 * KineticsPay - aggregation pipelines
 * Portfolio 4. Run after loading data from data/*.json:
 *   mongoimport --db kineticspay --collection transaction_events \
 *               --file data/transaction_events.json --jsonArray
 * ===================================================================== */
db = db.getSiblingDB("kineticspay");

print("\n--- Failure rate by channel (cf. Portfolio 2 Q5) ---");
printjson(db.transaction_events.aggregate([
  { $group: { _id: "$metadata.channel",
              attempted: { $sum: 1 },
              failed: { $sum: { $cond: [{ $eq: ["$status","FAILED"] }, 1, 0] } },
              value: { $sum: "$amount" } } },
  { $project: { attempted: 1, failed: 1,
                failure_rate_pct: { $round: [{ $multiply: [{ $divide: ["$failed","$attempted"] }, 100] }, 2] },
                avg_value: { $round: [{ $divide: ["$value","$attempted"] }, 2] } } },
  { $sort: { attempted: -1 } }
]).toArray());

print("\n--- Decline reasons ranked ---");
printjson(db.transaction_events.aggregate([
  { $match: { "metadata.failure.code": { $exists: true } } },
  { $group: { _id: "$metadata.failure.code", n: { $sum: 1 },
              retryable: { $sum: { $cond: ["$metadata.failure.retryable", 1, 0] } } } },
  { $sort: { n: -1 } }
]).toArray());

print("\n--- Risk signals unwound ---");
printjson(db.transaction_events.aggregate([
  { $match: { "metadata.risk.signals": { $exists: true } } },
  { $unwind: "$metadata.risk.signals" },
  { $group: { _id: "$metadata.risk.signals", n: { $sum: 1 },
              avg_score: { $avg: "$metadata.risk.score" } } },
  { $sort: { n: -1 } }
]).toArray());

print("\n--- Settlement latency by channel ---");
printjson(db.transaction_events.aggregate([
  { $match: { latency_ms: { $exists: true }, status: "COMPLETED" } },
  { $group: { _id: "$metadata.channel", n: { $sum: 1 },
              avg_ms: { $avg: "$latency_ms" }, max_ms: { $max: "$latency_ms" } } },
  { $sort: { avg_ms: -1 } }
]).toArray());

print("\n--- $facet: several summaries in one pass ---");
printjson(db.transaction_events.aggregate([
  { $facet: {
      by_status:   [ { $group: { _id: "$status", n: { $sum: 1 } } }, { $sort: { n: -1 } } ],
      by_currency: [ { $group: { _id: "$currency", n: { $sum: 1 } } } ],
      compliance:  [ { $match: { "metadata.compliance.threshold_review": true } },
                     { $count: "n" } ]
  } }
]).toArray());

/* EXPLAIN - the one thing mongomock cannot show. Run this on a real
 * server to see whether the index was used, and compare against the
 * PostgreSQL execution plans in Portfolio 2. */
print("\n--- explain: does the sparse index get used? ---");
printjson(db.transaction_events.find({ "metadata.risk.action": "CHALLENGE" })
            .explain("executionStats").executionStats);
