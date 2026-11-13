/* =====================================================================
 * KineticsPay - multi-document transactions
 * Portfolio 4, section 6.3
 *
 * THIS IS THE SCRIPT mongomock COULD NOT RUN. Multi-document
 * transactions need a replica set. A standalone mongod will reject
 * startTransaction() with:
 *     "Transaction numbers are only allowed on a replica set member
 *      or mongos"
 *
 * To run locally, start a single-node replica set:
 *     mongod --replSet rs0 --dbpath /data/db
 *     mongosh --eval "rs.initiate()"
 * Atlas free-tier clusters are replica sets already, so it works there
 * unchanged.
 * ===================================================================== */
db = db.getSiblingDB("kineticspay");

db.wallet_snapshots.updateOne({ _id: "WAL-TEST-A-NGN" },
  { $set: { balance: 50000, wallet_id: 90001, currency: "NGN", status: "ACTIVE",
            customer: { reference: "CUS-900001", name: "Concurrency TestA" } } },
  { upsert: true });
db.wallet_snapshots.updateOne({ _id: "WAL-TEST-B-NGN" },
  { $set: { balance: 10000, wallet_id: 90002, currency: "NGN", status: "ACTIVE",
            customer: { reference: "CUS-900002", name: "Concurrency TestB" } } },
  { upsert: true });

function totals(label) {
  const a = db.wallet_snapshots.findOne({ _id: "WAL-TEST-A-NGN" }).balance;
  const b = db.wallet_snapshots.findOne({ _id: "WAL-TEST-B-NGN" }).balance;
  print(`${label}: A=${a}  B=${b}  total=${a + b}`);
}

/* ---- 1. WITHOUT a transaction: the failure mode from section 6.2 ---- */
print("\n=== without a transaction ===");
totals("before");
db.wallet_snapshots.updateOne({ _id: "WAL-TEST-A-NGN", balance: { $gte: 20000 } },
                              { $inc: { balance: -20000 } });
try {
  /* recipient does not exist -> no write happens */
  const r = db.wallet_snapshots.updateOne({ _id: "WAL-TEST-C-MISSING" },
                                          { $inc: { balance: 20000 } });
  print(`credit modified: ${r.modifiedCount}`);
} catch (e) { print("credit failed: " + e); }
totals("after ");
print("the debit stands alone: value destroyed, nothing to roll it back");

/* ---- 2. WITH a transaction ---- */
print("\n=== with a multi-document transaction ===");
db.wallet_snapshots.updateOne({ _id: "WAL-TEST-A-NGN" }, { $set: { balance: 50000 } });
db.wallet_snapshots.updateOne({ _id: "WAL-TEST-B-NGN" }, { $set: { balance: 10000 } });
totals("before");

const session = db.getMongo().startSession();
const wallets = session.getDatabase("kineticspay").wallet_snapshots;
try {
  session.startTransaction({ readConcern: { level: "snapshot" },
                             writeConcern: { w: "majority" } });

  const debit = wallets.updateOne({ _id: "WAL-TEST-A-NGN", balance: { $gte: 20000 } },
                                  { $inc: { balance: -20000 } });
  if (debit.modifiedCount !== 1) throw new Error("insufficient funds");

  const credit = wallets.updateOne({ _id: "WAL-TEST-C-MISSING" },
                                   { $inc: { balance: 20000 } });
  if (credit.modifiedCount !== 1) throw new Error("recipient not found");

  session.commitTransaction();
  print("committed");
} catch (e) {
  session.abortTransaction();
  print("aborted and rolled back: " + e.message);
} finally {
  session.endSession();
}
totals("after ");
print("balances unchanged: the debit was rolled back with the failed credit");

/* ---- 3. The retry obligation -------------------------------------
 * Under contention a transaction can fail with TransientTransactionError
 * and MUST be retried - the same obligation SERIALIZABLE imposed in
 * Portfolio 3. Shape of it:
 *
 *   function runWithRetry(txnFunc, session, maxAttempts = 5) {
 *     for (let i = 0; i < maxAttempts; i++) {
 *       try { return txnFunc(session); }
 *       catch (e) {
 *         if (e.hasErrorLabel("TransientTransactionError")) continue;
 *         throw e;
 *       }
 *     }
 *     throw new Error("retries exhausted");
 *   }
 * ------------------------------------------------------------------- */
