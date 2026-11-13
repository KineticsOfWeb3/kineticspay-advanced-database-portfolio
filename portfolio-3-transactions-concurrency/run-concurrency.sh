#!/usr/bin/env bash
# =====================================================================
# KineticsPay - Portfolio 3 concurrency experiments
# MIT 8103 Advanced Database Systems
# Biliaminu Abdulfarid (301918844)
#
# Two INDEPENDENT PostgreSQL sessions attempt to spend the same money.
# Each phase runs them as separate background psql processes against the
# live database - not simulated, not sequential.
#
# Interleaving is made deterministic with pg_sleep() inside each session
# and a staggered start, so the same failure is reproduced on every run
# rather than depending on luck.
#
# Usage:  ./run-concurrency.sh
# =====================================================================
set -u

PSQL="psql -h localhost -U postgres -d kineticspay -X"
OUT="evidence"
mkdir -p "$OUT"

WA=WAL-TEST-A-NGN
AMOUNT=35000
START=50000

banner () { printf '\n==============================================================\n%s\n==============================================================\n' "$1"; }

reset_wallets () {
    $PSQL -q -c "SELECT fn_reset_test_wallet('$WA', $START);" >/dev/null 2>&1
    $PSQL -q -c "SELECT fn_reset_test_wallet('WAL-TEST-B-NGN', $START);" >/dev/null 2>&1
}

show_balance () {
    $PSQL -c "SELECT wallet_reference, balance, entry_count FROM wallets WHERE wallet_reference = '$WA';"
}

# Run two sessions concurrently. $1 = session A sql, $2 = session B sql,
# $3 = delay before starting B.
race () {
    local sqlA="$1" sqlB="$2" delay="${3:-0.4}"
    : > /tmp/sessA.out; : > /tmp/sessB.out
    ( $PSQL -v ON_ERROR_STOP=0 -c "$sqlA" > /tmp/sessA.out 2>&1 ) &
    local pidA=$!
    sleep "$delay"
    ( $PSQL -v ON_ERROR_STOP=0 -c "$sqlB" > /tmp/sessB.out 2>&1 ) &
    local pidB=$!
    wait $pidA $pidB
    echo ""
    echo "----- SESSION A output -----"
    sed 's/^/  A| /' /tmp/sessA.out
    echo "----- SESSION B output -----"
    sed 's/^/  B| /' /tmp/sessB.out
}

# ---------------------------------------------------------------------
{
banner "PORTFOLIO 3 - TRANSACTIONS AND CONCURRENCY"
cat <<EOF
Scenario, identical in every phase:

    Wallet $WA starts with NGN $START.
    Session A withdraws NGN $AMOUNT.
    Session B withdraws NGN $AMOUNT, concurrently.

    Total attempted: NGN 70,000.  Available: NGN $START.

Exactly one withdrawal should succeed. Each phase applies a different
control and reports what actually happened.

Run at: $(date -u '+%Y-%m-%d %H:%M:%S UTC')
PostgreSQL: $($PSQL -tAc 'SHOW server_version')
EOF

# =====================================================================
banner "PHASE 0 - A single transaction in isolation: COMMIT and ROLLBACK"
# =====================================================================
cat <<'EOF'
Before any concurrency, the baseline transactional behaviour. A withdrawal
is posted and then rolled back; the ledger must show no trace of it.
EOF
reset_wallets
echo "--- balance before ---"; show_balance
echo "--- BEGIN, post 35,000, then ROLLBACK ---"
$PSQL 2>&1 <<SQL
BEGIN;
SELECT fn_post_withdrawal('$WA', $AMOUNT, 'will be rolled back') AS posted_reference;
SELECT balance AS balance_inside_transaction FROM wallets WHERE wallet_reference = '$WA';
ROLLBACK;
SQL
echo "--- balance after ROLLBACK (must be unchanged) ---"; show_balance

echo ""
echo "--- BEGIN, post 35,000, SAVEPOINT, post again, roll back to savepoint, COMMIT ---"
$PSQL 2>&1 <<SQL
BEGIN;
SELECT fn_post_withdrawal('$WA', 10000, 'kept') AS first_posting;
SAVEPOINT after_first;
SELECT fn_post_withdrawal('$WA', 10000, 'discarded') AS second_posting;
ROLLBACK TO SAVEPOINT after_first;
COMMIT;
SQL
echo "--- balance after partial rollback (expect 40,000: only the first posting kept) ---"
show_balance

# =====================================================================
banner "PHASE 1 - THE RACE, with no protection at all"
# =====================================================================
cat <<'EOF'
Each session does what an unprotected application does:

    1. read the authoritative balance from the ledger
    2. decide whether the withdrawal is affordable
    3. post it

Both sessions read BEFORE either commits. Both see 50,000. Both conclude
35,000 is affordable. The balance is never stale - the CHECK is
unserialised.
EOF
reset_wallets
echo "--- balance before ---"; show_balance

RACE_SQL="DO \$\$
DECLARE v_bal NUMERIC;
BEGIN
  SELECT balance INTO v_bal FROM account_balances
   WHERE account_id = (SELECT account_id FROM accounts WHERE account_reference='$WA');
  RAISE NOTICE 'read balance = %', v_bal;
  PERFORM pg_sleep(2);
  IF v_bal >= $AMOUNT THEN
    PERFORM fn_post_withdrawal('$WA', $AMOUNT, 'unprotected');
    RAISE NOTICE 'DECISION: sufficient funds -> POSTED % ', $AMOUNT;
  ELSE
    RAISE NOTICE 'DECISION: insufficient funds -> REJECTED';
  END IF;
END \$\$;"

race "$RACE_SQL" "$RACE_SQL" 0.4
echo ""
echo "--- balance after (expect -20,000 if the race occurred) ---"; show_balance
echo "--- the ledger still balances, which is the point: double-entry does NOT prevent an overdraft ---"
$PSQL -c "SELECT SUM(CASE WHEN direction='DEBIT' THEN amount ELSE -amount END) AS global_imbalance FROM ledger_entries;"

# =====================================================================
banner "PHASE 2 - Does a deferred overdraft CONSTRAINT alone fix it?"
# =====================================================================
cat <<'EOF'
A natural first instinct: add a constraint forbidding a negative wallet
balance, and let the database enforce it. Since the balance is derived,
this must be a DEFERRABLE constraint trigger evaluated at COMMIT.

The question this phase answers empirically: is a correctness constraint
sufficient on its own, without any locking?
EOF
$PSQL -q 2>&1 <<'SQL'
CREATE OR REPLACE FUNCTION fn_assert_no_overdraft()
RETURNS TRIGGER LANGUAGE plpgsql AS $fn$
DECLARE
    v_balance NUMERIC(20,4);
    v_type    account_type_t;
    v_ref     VARCHAR;
BEGIN
    SELECT a.account_type, a.account_reference INTO v_type, v_ref
    FROM accounts a WHERE a.account_id = NEW.account_id;

    IF v_type <> 'CUSTOMER_WALLET' THEN
        RETURN NULL;           -- internal control accounts may go negative
    END IF;

    SELECT balance INTO v_balance
    FROM account_balances WHERE account_id = NEW.account_id;

    IF v_balance < 0 THEN
        RAISE EXCEPTION 'Overdraft refused on %: balance would be %',
            v_ref, v_balance USING ERRCODE = 'check_violation';
    END IF;
    RETURN NULL;
END;
$fn$;

DROP TRIGGER IF EXISTS trg_ledger_entries_no_overdraft ON ledger_entries;
CREATE CONSTRAINT TRIGGER trg_ledger_entries_no_overdraft
    AFTER INSERT ON ledger_entries
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION fn_assert_no_overdraft();
SQL
echo "constraint trigger installed."
reset_wallets
echo "--- balance before ---"; show_balance
race "$RACE_SQL" "$RACE_SQL" 0.4
echo ""
echo "--- balance after ---"; show_balance

echo ""
echo "--- 2B: the same two sessions committing at the SAME instant (no stagger) ---"
cat <<'EOF'
Phase 2A staggered the sessions by 0.4s, so one committed before the
other's deferred check ran. Removing the stagger makes both commit
together. If the constraint is doing the work alone, the outcome should
not depend on timing.
EOF
reset_wallets
race "$RACE_SQL" "$RACE_SQL" 0.0
echo ""
echo "--- balance after simultaneous commit ---"; show_balance

# =====================================================================
banner "PHASE 3 - SELECT ... FOR UPDATE (pessimistic row lock)"
# =====================================================================
cat <<'EOF'
The accounts row is used as a LOCK ANCHOR. It is not where the balance
lives - the balance is derived from ledger_entries - but every writer
agrees to take the same row lock before reading and posting. That
serialises them.

Session B will BLOCK at the lock until A commits, then read a balance
that already includes A's withdrawal.
EOF
reset_wallets
echo "--- balance before ---"; show_balance

LOCK_SQL="DO \$\$
DECLARE v_bal NUMERIC; v_acct BIGINT;
BEGIN
  SELECT account_id INTO v_acct FROM accounts WHERE account_reference='$WA' FOR UPDATE;
  RAISE NOTICE 'acquired row lock on account %', v_acct;
  SELECT balance INTO v_bal FROM account_balances WHERE account_id = v_acct;
  RAISE NOTICE 'read balance = %', v_bal;
  PERFORM pg_sleep(2);
  IF v_bal >= $AMOUNT THEN
    PERFORM fn_post_withdrawal('$WA', $AMOUNT, 'row-locked');
    RAISE NOTICE 'DECISION: sufficient funds -> POSTED %', $AMOUNT;
  ELSE
    RAISE NOTICE 'DECISION: insufficient funds -> REJECTED';
  END IF;
END \$\$;"

race "$LOCK_SQL" "$LOCK_SQL" 0.4
echo ""
echo "--- balance after (expect 15,000: exactly one withdrawal) ---"; show_balance

# =====================================================================
banner "PHASE 4 - SERIALIZABLE isolation (optimistic)"
# =====================================================================
cat <<'EOF'
No explicit locks. Both sessions run at SERIALIZABLE and read the ledger.
PostgreSQL's Serializable Snapshot Isolation tracks the read-write
dependency between them and aborts one with SQLSTATE 40001 when the
interleaving could not have arisen from any serial order.

The application's obligation under SERIALIZABLE is to RETRY on 40001 -
a serialization failure is an expected outcome, not a bug.
EOF
reset_wallets
echo "--- balance before ---"; show_balance

SER_SQL="BEGIN ISOLATION LEVEL SERIALIZABLE;
DO \$\$
DECLARE v_bal NUMERIC;
BEGIN
  SELECT balance INTO v_bal FROM account_balances
   WHERE account_id = (SELECT account_id FROM accounts WHERE account_reference='$WA');
  RAISE NOTICE 'read balance = %', v_bal;
  PERFORM pg_sleep(2);
  IF v_bal >= $AMOUNT THEN
    PERFORM fn_post_withdrawal('$WA', $AMOUNT, 'serializable');
    RAISE NOTICE 'DECISION: sufficient funds -> POSTED %', $AMOUNT;
  ELSE
    RAISE NOTICE 'DECISION: insufficient funds -> REJECTED';
  END IF;
END \$\$;
COMMIT;"

race "$SER_SQL" "$SER_SQL" 0.4
echo ""
echo "--- balance after (expect 15,000, with one session receiving SQLSTATE 40001) ---"
show_balance

# =====================================================================
banner "PHASE 5 - Read phenomena across isolation levels"
# =====================================================================
cat <<'EOF'
PostgreSQL never permits dirty reads at any isolation level, so the
classic four-phenomena table does not map onto it directly. What CAN be
demonstrated is the difference between READ COMMITTED and REPEATABLE
READ for a non-repeatable read.
EOF
reset_wallets

echo ""
echo "--- 5A: READ COMMITTED - the same query returns different answers ---"
( $PSQL 2>&1 <<SQL | sed 's/^/  READER| /'
BEGIN ISOLATION LEVEL READ COMMITTED;
SELECT balance AS first_read FROM wallets WHERE wallet_reference='$WA';
SELECT pg_sleep(2);
SELECT balance AS second_read FROM wallets WHERE wallet_reference='$WA';
COMMIT;
SQL
) &
READER=$!
sleep 0.8
$PSQL -q -c "SELECT fn_post_withdrawal('$WA', 5000, 'writer during read');" >/dev/null 2>&1
echo "  WRITER| committed a 5,000 withdrawal while the reader was open"
wait $READER

echo ""
echo "--- 5B: REPEATABLE READ - the snapshot is stable ---"
reset_wallets
( $PSQL 2>&1 <<SQL | sed 's/^/  READER| /'
BEGIN ISOLATION LEVEL REPEATABLE READ;
SELECT balance AS first_read FROM wallets WHERE wallet_reference='$WA';
SELECT pg_sleep(2);
SELECT balance AS second_read FROM wallets WHERE wallet_reference='$WA';
COMMIT;
SQL
) &
READER=$!
sleep 0.8
$PSQL -q -c "SELECT fn_post_withdrawal('$WA', 5000, 'writer during repeatable read');" >/dev/null 2>&1
echo "  WRITER| committed a 5,000 withdrawal while the reader was open"
wait $READER
echo "  (the reader's two reads agree; the write is simply not in its snapshot)"

echo ""
echo "--- 5C: phantom rows under READ COMMITTED ---"
( $PSQL 2>&1 <<SQL | sed 's/^/  READER| /'
BEGIN ISOLATION LEVEL READ COMMITTED;
SELECT COUNT(*) AS first_count FROM ledger_entries le
 JOIN accounts a USING (account_id) WHERE a.account_reference='$WA';
SELECT pg_sleep(2);
SELECT COUNT(*) AS second_count FROM ledger_entries le
 JOIN accounts a USING (account_id) WHERE a.account_reference='$WA';
COMMIT;
SQL
) &
READER=$!
sleep 0.8
$PSQL -q -c "SELECT fn_post_withdrawal('$WA', 1000, 'phantom');" >/dev/null 2>&1
echo "  WRITER| inserted new ledger rows matching the reader's predicate"
wait $READER

# =====================================================================
banner "PHASE 6 - Deadlock between two opposing transfers"
# =====================================================================
cat <<'EOF'
A transfers to B while B transfers to A. Each locks its own wallet first,
then reaches for the other's. Neither can proceed.

PostgreSQL detects the cycle and aborts one transaction with SQLSTATE
40P01. The fix is not a longer timeout: it is a consistent LOCK ORDERING,
shown afterwards.
EOF
reset_wallets

DL_A="DO \$\$
BEGIN
  PERFORM 1 FROM accounts WHERE account_reference='WAL-TEST-A-NGN' FOR UPDATE;
  RAISE NOTICE 'locked A';
  PERFORM pg_sleep(1);
  RAISE NOTICE 'reaching for B...';
  PERFORM 1 FROM accounts WHERE account_reference='WAL-TEST-B-NGN' FOR UPDATE;
  RAISE NOTICE 'locked B';
END \$\$;"
DL_B="DO \$\$
BEGIN
  PERFORM 1 FROM accounts WHERE account_reference='WAL-TEST-B-NGN' FOR UPDATE;
  RAISE NOTICE 'locked B';
  PERFORM pg_sleep(1);
  RAISE NOTICE 'reaching for A...';
  PERFORM 1 FROM accounts WHERE account_reference='WAL-TEST-A-NGN' FOR UPDATE;
  RAISE NOTICE 'locked A';
END \$\$;"

race "$DL_A" "$DL_B" 0.1

echo ""
echo "--- 6B: the same two transfers, with locks taken in a CONSISTENT ORDER ---"
cat <<'EOF'
Both sessions now lock accounts in ascending account_id order, regardless
of which direction the money is moving. A cycle becomes impossible: one
session simply waits for the other.
EOF
ORD="DO \$\$
DECLARE r RECORD;
BEGIN
  FOR r IN SELECT account_id FROM accounts
            WHERE account_reference IN ('WAL-TEST-A-NGN','WAL-TEST-B-NGN')
            ORDER BY account_id FOR UPDATE
  LOOP
    RAISE NOTICE 'locked account % (ascending order)', r.account_id;
  END LOOP;
  PERFORM pg_sleep(1);
  RAISE NOTICE 'both locks held, work done, committing';
END \$\$;"
race "$ORD" "$ORD" 0.1

# ---------------------------------------------------------------------
banner "CLEANUP - remove the experimental overdraft trigger"
# ---------------------------------------------------------------------
echo "The overdraft constraint is re-applied permanently by safe-transfer.sql,"
echo "together with the locking it requires. Dropping the standalone version:"
$PSQL -c "DROP TRIGGER IF EXISTS trg_ledger_entries_no_overdraft ON ledger_entries;"
reset_wallets
show_balance

} > "$OUT/concurrency-output.txt" 2>&1

echo "complete -> $OUT/concurrency-output.txt"
wc -l "$OUT/concurrency-output.txt"
