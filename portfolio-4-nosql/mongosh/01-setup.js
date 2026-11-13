/* =====================================================================
 * KineticsPay - collections, validators and indexes
 * Portfolio 4: NoSQL and Advanced Data Models
 * Biliaminu Abdulfarid (301918844)
 *
 * Runs against a REAL MongoDB server (local mongod or Atlas free tier):
 *     mongosh "<connection-string>" --file mongosh/01-setup.js
 *
 * This is the server-side counterpart to mongo_implementation.py. The
 * Python version runs against mongomock, which does not implement
 * $jsonSchema; here the validator is enforced by the server itself.
 * ===================================================================== */

db = db.getSiblingDB("kineticspay");

db.transaction_events.drop();
db.wallet_snapshots.drop();

/* ---------------------------------------------------------------------
 * transaction_events
 *
 * validationLevel "strict", validationAction "error": the server refuses
 * writes that break the schema, rather than merely warning. A payment
 * event collection is not a dumping ground - MongoDB is schema-flexible,
 * not schema-less.
 * ------------------------------------------------------------------- */
db.createCollection("transaction_events", {
  validator: {
    $jsonSchema: {
      bsonType: "object",
      required: ["_id","transaction_id","type","status","currency","amount",
                 "initiated_at","metadata"],
      properties: {
        _id:            { bsonType: "string", pattern: "^KP-[0-9]{4}-[0-9]{6}$" },
        transaction_id: { bsonType: ["int","long"] },
        type:           { enum: ["DEPOSIT","WITHDRAWAL","TRANSFER","FEE","REVERSAL"] },
        status:         { enum: ["PENDING","COMPLETED","FAILED","REVERSED"] },
        currency:       { bsonType: "string", pattern: "^[A-Z]{3}$" },
        amount:         { bsonType: ["double","decimal","int"], minimum: 0 },
        customer_id:    { bsonType: ["int","long","null"] },
        metadata: {
          bsonType: "object",
          required: ["channel"],
          properties: {
            channel: { enum: ["MOBILE_APP","WEB","USSD","API","INTERNAL"] },
            risk: {
              bsonType: "object",
              properties: {
                score:  { bsonType: "double", minimum: 0, maximum: 100 },
                action: { enum: ["ALLOW","CHALLENGE","REVIEW"] }
              }
            }
          }
        },
        state_history: {
          bsonType: "array",
          items: { bsonType: "object", required: ["state","at"] }
        }
      }
    }
  },
  validationLevel: "strict",
  validationAction: "error"
});

db.createCollection("wallet_snapshots", {
  validator: {
    $jsonSchema: {
      bsonType: "object",
      required: ["_id","wallet_id","customer","currency","balance","status"],
      properties: {
        _id:       { bsonType: "string" },
        wallet_id: { bsonType: ["int","long"] },
        customer:  { bsonType: "object", required: ["reference","name"] },
        currency:  { bsonType: "string", pattern: "^[A-Z]{3}$" },
        balance:   { bsonType: ["double","decimal","int"] },
        status:    { enum: ["ACTIVE","FROZEN","CLOSED"] },
        /* Bounded on purpose. The busiest wallet has 56,297 postings;
         * embedding all of them would approach the 16 MB document limit
         * and make every balance read transfer megabytes. */
        recent_activity: { bsonType: "array", maxItems: 10 }
      }
    }
  },
  validationLevel: "strict",
  validationAction: "error"
});

/* --------------------------------------------------------------------- */
db.transaction_events.createIndex({ customer_id: 1, initiated_at: -1 },
                                  { name: "customer_recent" });
db.transaction_events.createIndex({ status: 1, initiated_at: -1 },
                                  { name: "status_recent" });
db.transaction_events.createIndex({ "metadata.channel": 1 }, { name: "channel" });

/* SPARSE: only ~18% of events carry a risk block, so the index holds
 * only those documents. Same reasoning as the PARTIAL index on
 * transactions(status) in Portfolio 2's indexes.sql. */
db.transaction_events.createIndex({ "metadata.risk.action": 1 },
                                  { name: "risk_action", sparse: true });

/* Multikey index over an array field. */
db.transaction_events.createIndex({ "metadata.risk.signals": 1 },
                                  { name: "risk_signals", sparse: true });

/* TTL: payment event metadata is operational telemetry, not the
 * accounting record, so it can expire. The LEDGER never expires - it
 * lives in PostgreSQL and is append-only. This is only safe because of
 * that separation. */
db.transaction_events.createIndex({ initiated_at: 1 },
                                  { name: "ttl_24_months",
                                    expireAfterSeconds: 63072000 });

db.wallet_snapshots.createIndex({ "customer.reference": 1 }, { name: "customer_ref" });

print("collections and indexes created");
printjson(db.transaction_events.getIndexes().map(i => i.name));
