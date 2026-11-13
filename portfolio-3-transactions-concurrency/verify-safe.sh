#!/usr/bin/env bash
# Verification of safe-transfer.sql under the same conditions that broke
# every weaker control. Portfolio 3, KineticsPay.
set -u
PSQL="psql -h localhost -U postgres -d kineticspay -X"
WA=WAL-TEST-A-NGN; WB=WAL-TEST-B-NGN
banner () { printf '\n==============================================================\n%s\n==============================================================\n' "$1"; }
reset () { $PSQL -q -c "SELECT fn_reset_test_wallet('$WA',50000);" >/dev/null 2>&1; $PSQL -q -c "SELECT fn_reset_test_wallet('$WB',50000);" >/dev/null 2>&1; }
bal () { $PSQL -c "SELECT wallet_reference, balance FROM wallets WHERE wallet_reference LIKE 'WAL-TEST-%' ORDER BY 1;"; }
race () {
  : > /tmp/a.out; : > /tmp/b.out
  ( $PSQL -c "$1" > /tmp/a.out 2>&1 ) & local p1=$!
  sleep "${3:-0.4}"
  ( $PSQL -c "$2" > /tmp/b.out 2>&1 ) & local p2=$!
  wait $p1 $p2
  echo "----- SESSION A -----"; sed 's/^/  A| /' /tmp/a.out
  echo "----- SESSION B -----"; sed 's/^/  B| /' /tmp/b.out
}

banner "VERIFICATION 1 - the original race, against fn_safe_withdraw"
echo "Same two sessions, same 50,000 wallet, same two 35,000 withdrawals."
reset; echo "--- before ---"; bal
SAFE="DO \$\$ BEGIN PERFORM pg_sleep(0.1);
  PERFORM fn_safe_withdraw('$WA', 35000, 'safe withdrawal');
  RAISE NOTICE 'WITHDRAWAL SUCCEEDED';
END \$\$;"
race "$SAFE" "$SAFE" 0.2
echo ""; echo "--- after (expect 15,000: exactly one withdrawal) ---"; bal

banner "VERIFICATION 2 - simultaneous commits, the case that defeated Phase 2B"
reset; race "$SAFE" "$SAFE" 0.0
echo ""; echo "--- after (expect 15,000) ---"; bal

banner "VERIFICATION 3 - five concurrent withdrawals against one 50,000 wallet"
echo "35,000 each. Only one can be affordable."
reset
for i in 1 2 3 4 5; do ( $PSQL -c "$SAFE" > /tmp/m$i.out 2>&1 ) & done
wait
for i in 1 2 3 4 5; do printf "  session %s| %s\n" "$i" "$(grep -oE 'WITHDRAWAL SUCCEEDED|Insufficient funds[^"]*|could not serialize[^"]*|deadlock detected' /tmp/m$i.out | head -1)"; done
echo ""; echo "--- after (expect 15,000) ---"; bal

banner "VERIFICATION 4 - opposing transfers that deadlocked in Phase 6"
echo "A transfers 10,000 to B while B transfers 10,000 to A, concurrently."
reset
T_AB="DO \$\$ BEGIN PERFORM fn_safe_transfer('$WA','$WB',10000,50,'A to B'); RAISE NOTICE 'A->B OK'; END \$\$;"
T_BA="DO \$\$ BEGIN PERFORM fn_safe_transfer('$WB','$WA',10000,50,'B to A'); RAISE NOTICE 'B->A OK'; END \$\$;"
race "$T_AB" "$T_BA" 0.0
echo ""; echo "--- after (both should succeed, no deadlock; each pays a 50 fee) ---"; bal

banner "VERIFICATION 5 - insufficient funds is a clean rejection, not a crash"
reset
$PSQL -c "SELECT fn_safe_withdraw('$WA', 999999, 'too much');" 2>&1 | sed 's/^/  /'
echo "--- balance unchanged ---"; bal

banner "VERIFICATION 6 - ledger integrity survives all of the above"
$PSQL -c "SELECT currency_code, SUM(amount) FILTER (WHERE direction='DEBIT') AS debits, SUM(amount) FILTER (WHERE direction='CREDIT') AS credits, CASE WHEN SUM(CASE WHEN direction='DEBIT' THEN amount ELSE -amount END)=0 THEN 'BALANCED' ELSE 'IMBALANCE' END AS result FROM ledger_entries GROUP BY 1 ORDER BY 1;"
$PSQL -c "SELECT COUNT(*) AS legacy_negative_wallets, MIN(balance) AS most_negative FROM wallets WHERE balance < 0;"
$PSQL -c "SELECT COUNT(*) AS test_wallets_negative FROM wallets WHERE balance < 0 AND wallet_reference LIKE 'WAL-TEST-%';"
