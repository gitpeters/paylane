#!/usr/bin/env bash
#
# scripts/ledger-truth.sh — capture the before-state for the "ledger is not the truth" post.
#
# The naive charge path posts BOTH legs of every double-entry pair against the SAME account
# (the merchant's own), and mutates accounts.balance separately. Two consequences fall out of
# that, and this script makes both visible against a live Postgres:
#
#   1. Summing the ledger for that account (CREDIT − DEBIT) always nets to ZERO — the pairs
#      cancel — so the balance can never be reconstructed from the ledger.
#   2. A correction written straight to accounts.balance leaves no ledger row at all, so there
#      is literally no entry that explains why the balance moved.
#
# It boots the app on its own port (dev profile, provider delay-ms=0 so every charge succeeds
# instantly), runs three real charges through POST /v1/charges, applies a manual balance
# correction, and prints the ledger vs balance divergence. The existing capacity.sql section-6
# invariants are run too — they all PASS, which is the point: the self-checks are green and the
# ledger is still useless as a source of truth.
#
# Evidence is written to analysis/out/ledger-before.txt and echoed to the terminal. Nothing here
# changes the schema or the ledger code — this is a pure capture of the current behaviour.
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
OUT_FILE="$OUT_DIR/ledger-before.txt"
APP_LOG="$OUT_DIR/ledger-truth.app.log"
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
# balance -> 0, and drop any prior 'ledger-demo%' transactions (children first for the FKs) so
# the run is repeatable and the balances below are directly comparable across runs.
echo ">> resetting dev merchant: balance -> 0, deleting prior '${REFERENCE_PREFIX}%' transactions"
psql -q \
    -c "DELETE FROM ledger_entries       WHERE transaction_id IN (SELECT id FROM transactions WHERE reference LIKE '${REFERENCE_PREFIX}%')" \
    -c "DELETE FROM transaction_attempts WHERE transaction_id IN (SELECT id FROM transactions WHERE reference LIKE '${REFERENCE_PREFIX}%')" \
    -c "DELETE FROM transactions         WHERE reference LIKE '${REFERENCE_PREFIX}%'" \
    -c "UPDATE accounts SET balance = 0 WHERE merchant_id = '$DEV_MERCHANT_ID'::uuid AND currency = 'NGN'"
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
    echo "# ledger truth (before) | $TS | postgres=$PGVER | delay-ms=$DELAY_MS"
    echo "# dev merchant=$DEV_MERCHANT_ID currency=NGN | charge amount=$AMOUNT | correction=-$CORRECTION"
    echo "#"
    echo "# The naive charge path posts BOTH legs of every pair against the SAME account and"
    echo "# mutates accounts.balance separately. The ledger for that account therefore nets to 0"
    echo "# and cannot reconstruct the balance; a direct balance correction leaves no ledger row."
    echo

    echo "== 1. reset: balance -> 0, prior '${REFERENCE_PREFIX}%' transactions deleted =="
    echo "accounts.balance after reset: $BALANCE_RESET"
    echo

    echo "== 2. three successful charges of $AMOUNT (delay-ms=$DELAY_MS), balance after each =="
    printf '%s' "$CHARGE_LINES"
    echo

    echo "== 3. ledger_entries for those three transactions =="
    echo "-- the point: both legs of every pair carry the SAME account_id"
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

    echo "== 5. section-6 invariants (from analysis/capacity.sql §6) — every row PASSes =="
    # Run the existing capacity.sql and keep only its section 6. tail -n +2 drops capacity.sql's
    # own "== 6. ..." echo line so the numbering here stays 1..6 with no duplicate header.
    psql -v whale_id="$WHALE_ID" -f "$CAPACITY_SQL" 2>/dev/null | sed -n '/== 6\./,$p' | tail -n +2
    echo

    echo "== 6. \"which entry explains the difference?\" =="
    echo "-- The ledger nets to 0 for this account; the balance is not 0. If the ledger were the"
    echo "-- source of truth, some posting would move this account's net away from 0 and account"
    echo "-- for the gap. Look for any entry whose opposite leg is NOT on the same account+txn."
    echo "-- There is none: both legs of every pair share this one account, and the correction"
    echo "-- wrote no entry at all. The query returns zero rows."
    psql -c "SELECT le.id, le.transaction_id, le.direction, le.amount \
             FROM ledger_entries le \
             JOIN accounts a ON a.id = le.account_id \
             WHERE a.merchant_id = '$DEV_MERCHANT_ID'::uuid AND a.currency = 'NGN' \
               AND NOT EXISTS ( \
                     SELECT 1 FROM ledger_entries opp \
                     WHERE opp.transaction_id = le.transaction_id \
                       AND opp.account_id     = le.account_id \
                       AND opp.direction      = CASE le.direction WHEN 'DEBIT' THEN 'CREDIT' ELSE 'DEBIT' END \
                       AND opp.amount         = le.amount)"
} > "$OUT_FILE"

echo
cat "$OUT_FILE"
echo
echo ">> written to ${OUT_FILE#"$ROOT"/}"
