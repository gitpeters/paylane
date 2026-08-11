#!/usr/bin/env bash
#
# scripts/capacity-run.sh — deterministic capacity harness for the naive baseline.
#
# Usage: ./scripts/capacity-run.sh <transaction_row_count>
#
# Truncates and reseeds the tenant/transaction tables with a FIXED random seed (so the skew
# distribution is identical across runs for a given row count), VACUUM ANALYZEs, resolves the
# whale merchant, then runs analysis/capacity.sql warm-then-captured. The captured output is
# written to analysis/out/capacity-<rowcount>.txt and echoed to the terminal.
#
# The database is never dropped — Flyway history and provider reference data survive.
set -euo pipefail

# --- args -------------------------------------------------------------------
if [[ $# -ne 1 ]]; then
  echo "usage: $0 <transaction_row_count>" >&2
  exit 2
fi
ROWCOUNT="$1"
if ! [[ "$ROWCOUNT" =~ ^[0-9]+$ ]]; then
  echo "error: row count must be a non-negative integer, got: $ROWCOUNT" >&2
  exit 2
fi

# --- connection (matches .env; override via PG* environment) ----------------
export PGHOST="${PGHOST:-localhost}"
export PGPORT="${PGPORT:-5433}"
export PGUSER="${PGUSER:-postgres}"
export PGPASSWORD="${PGPASSWORD:-postgres}"
export PGDATABASE="${PGDATABASE:-paylane}"

readonly MERCHANTS=500
readonly SEED=0.42

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly CAPACITY_SQL="$ROOT/analysis/capacity.sql"
readonly OUT_DIR="$ROOT/analysis/out"
readonly OUT_FILE="$OUT_DIR/capacity-$ROWCOUNT.txt"

echo ">> reseeding $PGDATABASE: $ROWCOUNT transactions across $MERCHANTS merchants (setseed=$SEED)"

# --- (a) truncate  (b) deterministic reseed  (c) vacuum analyze -------------
# One psql session so setseed() persists across statements. Autocommit
# (no --single-transaction) so VACUUM is allowed.
psql -v ON_ERROR_STOP=1 -v rowcount="$ROWCOUNT" -q <<'SQL'
-- The whale merchant's id is pinned to a literal so it is stable across runs.
-- gen_random_uuid() is NOT affected by setseed(), so without pinning, the whale's uuid would
-- change every run — only its ~40% share would be reproducible, not its identity.
\set whale '96444bf1-5cb9-4cf4-8efd-00cc01aafa9c'

-- (a) truncate tenant + transaction data. Flyway history and providers are untouched.
TRUNCATE merchants, api_keys, accounts, transactions, transaction_attempts, ledger_entries
    RESTART IDENTITY CASCADE;

-- (b) deterministic + shm-safe: disable ALL parallel workers. This keeps random() ordering
--     stable AND avoids parallel VACUUM/scan DSM segments, which overflow a container's small
--     default /dev/shm (64 MB) at multi-million-row scale. Fix the seed before the first random().
SET max_parallel_workers_per_gather = 0;
SET max_parallel_maintenance_workers = 0;
SET max_parallel_workers = 0;
SELECT setseed(0.42);

-- Reference data (providers/routes) is not truncated; insert only if empty.
INSERT INTO providers (name, enabled)
SELECT v.name, true
FROM (VALUES ('paystack'), ('stripe'), ('monnify')) AS v(name)
WHERE NOT EXISTS (SELECT 1 FROM providers);

INSERT INTO provider_routes (provider_id, currency, priority, enabled)
SELECT id, 'NGN', row_number() OVER (ORDER BY id), true
FROM providers
WHERE NOT EXISTS (SELECT 1 FROM provider_routes);

-- 500 merchants, created_at spread over ~14 months. The whale gets the pinned id.
INSERT INTO merchants (id, name, status, created_at)
VALUES (:'whale'::uuid, 'Merchant 1 (whale)', 'ACTIVE', now() - (random() * interval '425 days'));
INSERT INTO merchants (id, name, status, created_at)
SELECT gen_random_uuid(), 'Merchant ' || (g + 1), 'ACTIVE',
       now() - (random() * interval '425 days')
FROM generate_series(1, 499) AS g;

INSERT INTO api_keys (merchant_id, key_hash, created_at)
SELECT id, md5(random()::text || id::text), now() FROM merchants;

INSERT INTO accounts (merchant_id, account_type, currency, balance, created_at, updated_at)
SELECT id, 'MERCHANT_AVAILABLE', 'NGN', 0, now(), now() FROM merchants;

-- System-owned accounts (no merchant): one PROVIDER_SETTLEMENT + one FEES_REVENUE per currency.
INSERT INTO accounts (merchant_id, account_type, currency, balance, created_at, updated_at)
SELECT NULL, t.account_type, 'NGN', 0, now(), now()
FROM (VALUES ('PROVIDER_SETTLEMENT'), ('FEES_REVENUE')) AS t(account_type);

-- Transactions: the whale (~40%) is ids[1], the earliest-created merchant; the rest decay
-- via power(random(),2). Merchant assignment is an array subscript, not a join, so random()
-- is evaluated once per row (a LATERAL subquery gets collapsed to a single evaluation).
WITH m AS (
    SELECT array_agg(id ORDER BY (id = :'whale'::uuid) DESC, created_at, id) AS ids FROM merchants
)
INSERT INTO transactions
    (id, merchant_id, reference, amount, currency, status, provider, created_at)
SELECT gen_random_uuid(),
       m.ids[CASE WHEN random() < 0.40 THEN 1
                  ELSE 2 + floor(power(random(), 2) * 499)::int END],
       'txn_' || g,
       (10000 + floor(random() * 49990000))::bigint,
       'NGN',
       -- ~90% SUCCESS, ~7% FAILED, ~3% PENDING, in a SINGLE random() draw so the merchant
       -- assignment draws above are unperturbed and the whale skew is preserved exactly.
       (ARRAY['SUCCESS','FAILED','PENDING'])[width_bucket(random(), ARRAY[0.90, 0.97]) + 1],
       (ARRAY['paystack','stripe','monnify'])[1 + floor(random() * 3)::int],
       now() - (random() * interval '425 days')
FROM generate_series(1, :rowcount) AS g CROSS JOIN m;

-- Each transaction gets 1..2 attempts: ~15% have a failed first try, then a retry. The
-- LATERAL references t.h, so it is genuinely correlated and evaluated once per row.
INSERT INTO transaction_attempts (transaction_id, provider, status, latency_ms, created_at)
SELECT t.id,
       t.provider,
       CASE WHEN a.attempt_no = 1 AND (t.h % 100) < 15 THEN 'FAILED' ELSE t.status END,
       CASE WHEN a.attempt_no = 1 AND (t.h % 100) < 15 THEN (2000 + floor(random() * 4000))::int
            ELSE (50 + floor(random() * 450))::int END,
       t.created_at + (a.attempt_no - 1) * interval '3 seconds'
FROM (SELECT id, provider, status, created_at,
             (hashtext(id::text) & 2147483647) AS h FROM transactions) t
CROSS JOIN LATERAL (
    SELECT gs AS attempt_no
    FROM generate_series(1, CASE WHEN (t.h % 100) < 15 THEN 2 ELSE 1 END) AS gs
) a;

-- Only SUCCESS transactions get ledger entries. Real double-entry: DEBIT the system
-- PROVIDER_SETTLEMENT account, CREDIT the merchant's MERCHANT_AVAILABLE account — two accounts.
INSERT INTO ledger_entries (transaction_id, account_id, direction, amount, currency, created_at)
SELECT t.id, ps.id, 'DEBIT', t.amount, t.currency, t.created_at
FROM transactions t
JOIN accounts ps ON ps.merchant_id IS NULL AND ps.account_type = 'PROVIDER_SETTLEMENT'
                AND ps.currency = t.currency
WHERE t.status = 'SUCCESS'
UNION ALL
SELECT t.id, ma.id, 'CREDIT', t.amount, t.currency, t.created_at
FROM transactions t
JOIN accounts ma ON ma.merchant_id = t.merchant_id AND ma.account_type = 'MERCHANT_AVAILABLE'
                AND ma.currency = t.currency
WHERE t.status = 'SUCCESS';

-- Balance caches = each account's ledger net (CREDIT − DEBIT), so invariant (c) holds on the
-- fresh seed: accounts.balance equals the signed sum of that account's entries. One GROUP BY
-- scan + join (NOT a per-account correlated subquery, which would be ~500 full scans at 4M rows).
-- Accounts with no entries keep their seeded balance 0, which already equals their (empty) sum.
UPDATE accounts a
SET balance = s.net, updated_at = now()
FROM (
    SELECT account_id,
           SUM(CASE WHEN direction = 'CREDIT' THEN amount ELSE -amount END) AS net
    FROM ledger_entries
    GROUP BY account_id
) s
WHERE s.account_id = a.id;

-- (c) refresh planner stats. An EXPLAIN on stale stats measures the wrong thing.
VACUUM ANALYZE merchants;
VACUUM ANALYZE api_keys;
VACUUM ANALYZE accounts;
VACUUM ANALYZE transactions;
VACUUM ANALYZE transaction_attempts;
VACUUM ANALYZE ledger_entries;
VACUUM ANALYZE providers;
VACUUM ANALYZE provider_routes;
SQL

# --- (d) resolve the whale --------------------------------------------------
WHALE="$(psql -tAq -c \
  'SELECT merchant_id FROM transactions GROUP BY merchant_id ORDER BY count(*) DESC LIMIT 1;')"
WHALE="${WHALE//[[:space:]]/}"
if [[ -z "$WHALE" ]]; then
  echo "error: no transactions seeded — cannot resolve whale merchant" >&2
  exit 1
fi
echo ">> whale merchant (most rows): $WHALE"

# --- (e) run capacity.sql: warm (discarded) then captured -------------------
echo ">> warm run (discarded)"
psql -v ON_ERROR_STOP=1 -v whale_id="$WHALE" -f "$CAPACITY_SQL" >/dev/null

echo ">> captured run"
CAPTURED="$(mktemp)"
trap 'rm -f "$CAPTURED"' EXIT
psql -v ON_ERROR_STOP=1 -v whale_id="$WHALE" -f "$CAPACITY_SQL" >"$CAPTURED" 2>&1

# --- (f) header line, then write + echo -------------------------------------
PGVER="$(psql -tAq -c 'SHOW server_version;')"
SHARED_BUFFERS="$(psql -tAq -c 'SHOW shared_buffers;')"
WORK_MEM="$(psql -tAq -c 'SHOW work_mem;')"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
HEADER="# rows=$ROWCOUNT | postgres=$PGVER | shared_buffers=$SHARED_BUFFERS | work_mem=$WORK_MEM | whale=$WHALE | $TS"

mkdir -p "$OUT_DIR"
{
  echo "$HEADER"
  echo
  cat "$CAPTURED"
} >"$OUT_FILE"

echo
cat "$OUT_FILE"
echo
echo ">> written to ${OUT_FILE#"$ROOT"/}"
