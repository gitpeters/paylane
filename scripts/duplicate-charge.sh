#!/usr/bin/env bash
#
# scripts/duplicate-charge.sh — reproduce the double charge on the naive charge path.
#
# The provider stub holds each call open for 30s. A charge is fired with a 10s client timeout;
# curl gives up, but the server keeps going and completes the charge. 4s later the byte-identical
# request is fired again. Both carry the same Idempotency-Key, which the naive server ignores;
# with no reference dedupe either, the merchant is charged twice. Evidence is written to
# analysis/out/duplicate-charge.txt and echoed to the terminal.
#
# The app is started on its own port with the dev profile (DevFixtureRunner creates the known
# merchant) and stopped at the end. Assumes the bulk data is already at 100k (dev-reset.sh).
set -euo pipefail

# --- config -----------------------------------------------------------------
PORT="${PORT:-8080}"   # override if 8080 is taken (e.g. the app is running in the IDE)
DELAY_MS=30000
CLIENT_TIMEOUT=10
RAW_KEY="pk_test_paylane_dev"
DEV_MERCHANT_ID="11111111-1111-1111-1111-111111111111"
REFERENCE="dup-charge-demo"
AMOUNT=4500000
# Sent on both requests; the current (naive) server ignores it. Hardcoded so the before
# and after runs stay byte-identical at the request level.
IDEMPOTENCY_KEY="7f3d9c2a-4b1e-4c8d-9a2f-6d5e3c7b1a09"
WHALE_ID="96444bf1-5cb9-4cf4-8efd-00cc01aafa9c"
BODY="{\"merchantReference\":\"${REFERENCE}\",\"amount\":${AMOUNT},\"currency\":\"NGN\",\"customerEmail\":\"buyer@example.com\"}"

export PGHOST="${PGHOST:-localhost}"
export PGPORT="${PGPORT:-5433}"
export PGUSER="${PGUSER:-postgres}"
export PGPASSWORD="${PGPASSWORD:-postgres}"
export PGDATABASE="${PGDATABASE:-paylane}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"   # so the app finds .env (spring.config.import is relative to CWD)
OUT_DIR="$ROOT/analysis/out"
OUT_FILE="$OUT_DIR/duplicate-charge.txt"
APP_LOG="$OUT_DIR/duplicate-charge.app.log"
JAR="$ROOT/target/paylane-0.0.1-SNAPSHOT.jar"
BASE_URL="http://localhost:${PORT}/v1/charges"

if command -v nc >/dev/null && nc -z localhost "$PORT" 2>/dev/null; then
    echo "error: port $PORT is already in use" >&2
    exit 1
fi

# --- build + start the app (dev profile, slow provider) ---------------------
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

balance_of() {
    psql -tAq -c "SELECT balance FROM accounts WHERE merchant_id = '$DEV_MERCHANT_ID'::uuid AND currency = 'NGN'"
}

fire_charge() {
    set +e
    curl -sS --max-time "$CLIENT_TIMEOUT" -X POST "$BASE_URL" \
        -H "X-API-Key: $RAW_KEY" \
        -H "Idempotency-Key: $IDEMPOTENCY_KEY" \
        -H "Content-Type: application/json" \
        -d "$BODY" \
        -w '\n[curl] http_status=%{http_code} time_total=%{time_total}s\n' 2>&1
    local code=$?
    set -e
    echo "[curl] exit code: $code"
}

# Reset so before/after balances are directly comparable on every run: zero the dev
# balance and drop any prior '$REFERENCE' transactions (children first for the FKs).
echo ">> resetting dev merchant: balance -> 0, deleting prior '$REFERENCE' transactions"
psql -q \
    -c "DELETE FROM ledger_entries WHERE transaction_id IN (SELECT id FROM transactions WHERE reference = '$REFERENCE')" \
    -c "DELETE FROM transaction_attempts WHERE transaction_id IN (SELECT id FROM transactions WHERE reference = '$REFERENCE')" \
    -c "DELETE FROM transactions WHERE reference = '$REFERENCE'" \
    -c "UPDATE accounts SET balance = 0 WHERE merchant_id = '$DEV_MERCHANT_ID'::uuid AND currency = 'NGN'"

BALANCE_BEFORE="$(balance_of)"

echo ">> firing charge 1 (curl --max-time $CLIENT_TIMEOUT — expected to time out client-side)"
EXCHANGE_1="$(fire_charge)"
echo ">> waiting 4s"
sleep 4
echo ">> firing charge 2 (byte-identical request)"
EXCHANGE_2="$(fire_charge)"

echo ">> waiting for both charges to finish server-side (30s provider delay each)"
for _ in $(seq 1 90); do
    done_count="$(psql -tAq -c "SELECT count(*) FROM transactions WHERE reference = '$REFERENCE' AND status = 'SUCCESS'")"
    [ "$done_count" = "2" ] && break
    sleep 1
done

BALANCE_AFTER="$(balance_of)"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
PGVER="$(psql -tAq -c 'SHOW server_version')"

# --- write the evidence file ------------------------------------------------
{
    echo "# duplicate-charge repro | $TS | postgres=$PGVER | delay-ms=$DELAY_MS | client-timeout=${CLIENT_TIMEOUT}s"
    echo "# idempotency-key on both requests (sent, ignored by the naive server): $IDEMPOTENCY_KEY"
    echo
    echo "== curl exchange 1 (client times out; server keeps processing) =="
    echo "$EXCHANGE_1"
    echo
    echo "== curl exchange 2 (byte-identical request) =="
    echo "$EXCHANGE_2"
    echo
    echo "== transactions WHERE reference = '$REFERENCE' ORDER BY created_at =="
    psql -c "SELECT id, reference, amount, status, created_at FROM transactions WHERE reference = '$REFERENCE' ORDER BY created_at"
    echo "== ledger_entries for those transactions (direction, amount) =="
    psql -c "SELECT le.transaction_id, le.direction, le.amount FROM ledger_entries le JOIN transactions t ON t.id = le.transaction_id WHERE t.reference = '$REFERENCE' ORDER BY le.transaction_id, le.direction"
    echo "== dev merchant accounts.balance (minor units) =="
    echo "before charges: $BALANCE_BEFORE"
    echo "after charges:  $BALANCE_AFTER"
    echo
    psql -v whale_id="$WHALE_ID" -f "$ROOT/analysis/capacity.sql" 2>/dev/null | sed -n '/== 6\./,$p'
} > "$OUT_FILE"

echo
cat "$OUT_FILE"
echo
echo ">> written to ${OUT_FILE#"$ROOT"/}"
