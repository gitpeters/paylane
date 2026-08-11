#!/usr/bin/env bash
#
# scripts/ledger-truth.sh — capture the ledger-vs-balance truth for the "ledger is the truth" post.
#
# Runs the SAME steps against whichever code/schema is checked out, so the before (naive) and
# after (real double-entry) captures compare directly:
#
#   1. reset the dev merchant  2. three charges  3. list the ledger legs  4. an off-ledger
#   balance correction + balance-vs-ledger side-by-side  5. the capacity.sql invariants
#   6. reconcile the cached balance against the ledger ("which entry explains the difference?").
#
# What the two captures show:
#   before: both legs of every pair land on ONE account, so the ledger nets to 0 and cannot
#           reconstruct the balance; step 6 returns nothing — no entry explains the difference.
#   after:  the legs land on DIFFERENT accounts, so the ledger net is the real credited amount;
#           step 6 returns the discrepancy — exactly the off-ledger correction (check c).
#
# Usage: ./scripts/ledger-truth.sh [out-basename]   # default: ledger-before ; after: ledger-after
#
# It boots the app on its own port (dev profile, provider delay-ms=0 so every charge succeeds
# instantly). Evidence is written to analysis/out/<out-basename>.txt and echoed to the terminal.
set -euo pipefail

# --- config -----------------------------------------------------------------
PORT="${PORT:-8080}"           # override if 8080 is taken (e.g. the app is running in the IDE)
DELAY_MS=0                     # provider returns SUCCESS immediately; charges are synchronous
RAW_KEY="pk_test_paylane_dev"
DEV_MERCHANT_ID="11111111-1111-1111-1111-111111111111"
WHALE_ID="96444bf1-5cb9-4cf4-8efd-00cc01aafa9c"   # pinned seed whale; capacity.sql §3 needs it
AMOUNT=4500000                 # minor units, per charge
CORRECTION=5000000             # minor units removed by the manual, off-ledger correction
REFERENCE_PREFIX="ledger-demo" # charge references; reset targets 'ledger-demo%'

# Three charges, each with a UNIQUE idempotency key. Hardcoded so the run is byte-reproducible.
REFERENCES=("${REFERENCE_PREFIX}-1" "${REFERENCE_PREFIX}-2" "${REFERENCE_PREFIX}-3")
IDEMPOTENCY_KEYS=(
    "a1111111-0000-4000-8000-000000000001"
    "a2222222-0000-4000-8000-000000000002"
    "a3333333-0000-4000-8000-000000000003"
)

export PGHOST="${PGHOST:-localhost}"
export PGPORT="${PGPORT:-5433}"
export PGUSER="${PGUSER:-postgres}"
export PGPASSWORD="${PGPASSWORD:-postgres}"
export PGDATABASE="${PGDATABASE:-paylane}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"   # so the app finds .env (spring.config.import is relative to CWD)
OUT_DIR="$ROOT/analysis/out"
OUT_NAME="${1:-ledger-before}"          # evidence basename: ledger-before | ledger-after
PHASE="${OUT_NAME#ledger-}"             # "before" | "after" — labels the header only
OUT_FILE="$OUT_DIR/${OUT_NAME}.txt"
APP_LOG="$OUT_DIR/${OUT_NAME}.app.log"
CAPACITY_SQL="$ROOT/analysis/capacity.sql"
JAR="$ROOT/target/paylane-0.0.1-SNAPSHOT.jar"
BASE_URL="http://localhost:${PORT}/v1/charges"

if command -v nc >/dev/null && nc -z localhost "$PORT" 2>/dev/null; then
    echo "error: port $PORT is already in use (set PORT=... to override)" >&2
    exit 1
fi

# --- build + start the app (dev profile, instant provider) ------------------
mkdir -p "$OUT_DIR"
echo ">> building jar"
(cd "$ROOT" && ./mvnw -q -DskipTests package)

echo ">> starting app on :$PORT (dev profile, provider delay-ms=$DELAY_MS)"
java -jar "$JAR" \
    --spring.profiles.active=dev \
    --paylane.provider.stub.delay-ms="$DELAY_MS" \
    --server.port="$PORT" > "$APP_LOG" 2>&1 &
APP_PID=$!
trap 'kill "$APP_PID" 2>/dev/null || true' EXIT

echo ">> waiting for the dev fixture to be ready"
ready=0
for _ in $(seq 1 120); do
    if grep -q "Dev fixture ready" "$APP_LOG" 2>/dev/null; then ready=1; break; fi
    if ! kill -0 "$APP_PID" 2>/dev/null; then break; fi
    sleep 1
done
if [ "$ready" != "1" ]; then
    echo "error: app did not become ready; last log lines:" >&2
    tail -20 "$APP_LOG" >&2
    exit 1
fi

# --- helpers ----------------------------------------------------------------
balance_of() {
    psql -tAq -c "SELECT balance FROM accounts \
        WHERE merchant_id = '$DEV_MERCHANT_ID'::uuid AND currency = 'NGN'"
}

# fire_charge <reference> <idempotency-key> -> prints the HTTP status code
fire_charge() {
    local ref="$1" idem="$2"
    curl -sS -o /dev/null -w '%{http_code}' -X POST "$BASE_URL" \
        -H "X-API-Key: $RAW_KEY" \
        -H "Idempotency-Key: $idem" \
        -H "Content-Type: application/json" \
        -d "{\"merchantReference\":\"$ref\",\"amount\":$AMOUNT,\"currency\":\"NGN\",\"customerEmail\":\"buyer@example.com\"}"
}

# --- (1) reset the dev merchant --------------------------------------------
# balance -> 0, and drop any prior 'ledger-demo%' transactions so the run is repeatable and the
# balances below are directly comparable. session_replication_role='replica' bypasses the V3
# immutability trigger for this dev-only reset (and FK triggers, so child-first order is not
# required); it is a harmless no-op on the pre-V3 schema. The dev fixture has usually wiped these
# rows already at boot, so the deletes typically match nothing.
echo ">> resetting dev merchant: balance -> 0, deleting prior '${REFERENCE_PREFIX}%' transactions"
psql -q -c "
SET session_replication_role = 'replica';
DELETE FROM ledger_entries       WHERE transaction_id IN (SELECT id FROM transactions WHERE reference LIKE '${REFERENCE_PREFIX}%');
DELETE FROM transaction_attempts WHERE transaction_id IN (SELECT id FROM transactions WHERE reference LIKE '${REFERENCE_PREFIX}%');
DELETE FROM transactions         WHERE reference LIKE '${REFERENCE_PREFIX}%';
UPDATE accounts SET balance = 0 WHERE merchant_id = '$DEV_MERCHANT_ID'::uuid AND currency = 'NGN';
SET session_replication_role = 'origin';
"
BALANCE_RESET="$(balance_of)"

# --- (2) three successful charges, balance printed after each ---------------
echo ">> firing three charges of $AMOUNT (delay-ms=$DELAY_MS)"
CHARGE_LINES=""
for i in 0 1 2; do
    code="$(fire_charge "${REFERENCES[$i]}" "${IDEMPOTENCY_KEYS[$i]}")"
    bal="$(balance_of)"
    n=$((i + 1))
    printf -v line "charge %d  ref=%-14s idempotency-key=%s  http_status=%s  accounts.balance=%s" \
        "$n" "${REFERENCES[$i]}" "${IDEMPOTENCY_KEYS[$i]}" "$code" "$bal"
    echo "   $line"
    CHARGE_LINES+="${line}"$'\n'
done

# --- (4) the manual correction: a plain UPDATE, outside the ledger ----------
# Run without -q so psql's command tag ("UPDATE 1") is captured verbatim for the evidence.
echo ">> applying the manual correction: balance = balance - $CORRECTION (no ledger entry written)"
CORRECTION_TAG="$(psql -c \
    "UPDATE accounts SET balance = balance - $CORRECTION \
     WHERE merchant_id = '$DEV_MERCHANT_ID'::uuid AND currency = 'NGN'")"

# --- gather the run's timestamp + version for the header --------------------
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
PGVER="$(psql -tAq -c 'SHOW server_version')"

# --- assemble the evidence file --------------------------------------------
{
    echo "# ledger-truth ($PHASE) | $TS | postgres=$PGVER | delay-ms=$DELAY_MS"
    echo "# dev merchant=$DEV_MERCHANT_ID currency=NGN | charge amount=$AMOUNT | correction=-$CORRECTION"
    echo "#"
    echo "# Three charges then one off-ledger balance correction, then reconcile accounts.balance"
    echo "# against the ledger. before (naive): both legs on ONE account -> ledger nets to 0."
    echo "# after (real): legs on DIFFERENT accounts -> ledger net is the true credited amount."
    echo

    echo "== 1. reset: balance -> 0, prior '${REFERENCE_PREFIX}%' transactions deleted =="
    echo "accounts.balance after reset: $BALANCE_RESET"
    echo

    echo "== 2. three successful charges of $AMOUNT (delay-ms=$DELAY_MS), balance after each =="
    printf '%s' "$CHARGE_LINES"
    echo

    echo "== 3. ledger_entries for those three transactions =="
    echo "-- before: both legs share ONE account_id; after: DEBIT and CREDIT land on DIFFERENT accounts"
    psql -c "SELECT le.transaction_id, le.account_id, le.direction, le.amount \
             FROM ledger_entries le \
             JOIN transactions t ON t.id = le.transaction_id \
             WHERE t.reference LIKE '${REFERENCE_PREFIX}%' \
             ORDER BY t.created_at, le.direction"
    echo

    echo "== 4. the manual correction (a plain UPDATE, outside the ledger) =="
    echo "UPDATE accounts SET balance = balance - $CORRECTION"
    echo "  WHERE merchant_id = '$DEV_MERCHANT_ID' AND currency = 'NGN';   -> $CORRECTION_TAG"
    echo
    echo "-- accounts.balance vs the ledger's net for that account, side by side:"
    psql -c "SELECT a.balance AS accounts_balance, \
                    COALESCE(SUM(CASE WHEN le.direction = 'CREDIT' THEN le.amount ELSE -le.amount END), 0) AS ledger_sum, \
                    a.balance - COALESCE(SUM(CASE WHEN le.direction = 'CREDIT' THEN le.amount ELSE -le.amount END), 0) AS difference \
             FROM accounts a \
             LEFT JOIN ledger_entries le ON le.account_id = a.id \
             WHERE a.merchant_id = '$DEV_MERCHANT_ID'::uuid AND a.currency = 'NGN' \
             GROUP BY a.id, a.balance"
    echo

    echo "== 5. invariants (from analysis/capacity.sql §6) — OLD checks PASS, NEW (a,b,c) can fail =="
    # Run the existing capacity.sql and keep only its section 6. tail -n +2 drops capacity.sql's
    # own "== 6. ..." echo line so the numbering here stays 1..6 with no duplicate header.
    psql -v whale_id="$WHALE_ID" -f "$CAPACITY_SQL" 2>/dev/null | sed -n '/== 6\./,$p' | tail -n +2
    echo

    echo "== 6. \"which entry explains the difference?\" (reconcile cache vs ledger — check c) =="
    echo "-- Sum this account's ledger entries and compare to the cached accounts.balance. Only"
    echo "-- accounts whose ledger net is non-zero are considered — an account a real ledger moved."
    echo "--   before (naive): both legs share one account, net = 0 -> no account qualifies ->"
    echo "--                    zero rows. The ledger cannot explain the balance; nothing to find."
    echo "--   after  (real):  net = the true credited amount; the row shows the gap between the"
    echo "--                    cache and the truth = exactly the off-ledger manual correction."
    psql -c "SELECT a.id AS account_id, a.balance AS cached_balance, s.ledger_truth, \
                    a.balance - s.ledger_truth AS discrepancy \
             FROM accounts a \
             JOIN ( \
                   SELECT le.account_id, \
                          SUM(CASE WHEN le.direction = 'CREDIT' THEN le.amount ELSE -le.amount END) AS ledger_truth \
                   FROM ledger_entries le \
                   GROUP BY le.account_id \
                   HAVING SUM(CASE WHEN le.direction = 'CREDIT' THEN le.amount ELSE -le.amount END) <> 0 \
             ) s ON s.account_id = a.id \
             WHERE a.merchant_id = '$DEV_MERCHANT_ID'::uuid AND a.currency = 'NGN' \
               AND a.balance <> s.ledger_truth"
} > "$OUT_FILE"

echo
cat "$OUT_FILE"
echo
echo ">> written to ${OUT_FILE#"$ROOT"/}"
