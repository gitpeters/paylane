-- analysis/capacity.sql
--
-- Capacity snapshot of the naive baseline schema after seeding.
--
-- Section 3 needs the whale merchant id passed in as a psql variable:
--
--     psql ... -v whale_id=<uuid> -f analysis/capacity.sql
--
-- scripts/capacity-run.sh resolves the whale and passes it for you. The id is used as a
-- literal (not a subquery) on purpose: a literal lets the planner use column statistics to
-- estimate selectivity for that specific merchant; a subquery forces a generic estimate and
-- pollutes the plan we are trying to read.
--
-- Sections: (1) row counts, (2) on-disk size, (3) the target-query plan, (4) rows per merchant,
-- (5) average bytes per row, (6) post-seed invariant self-checks.

\echo '== 1. Row counts per table =='
        SELECT 'merchants'            AS table_name, count(*) FROM merchants
UNION ALL SELECT 'api_keys',            count(*) FROM api_keys
UNION ALL SELECT 'accounts',            count(*) FROM accounts
UNION ALL SELECT 'transactions',        count(*) FROM transactions
UNION ALL SELECT 'transaction_attempts', count(*) FROM transaction_attempts
UNION ALL SELECT 'ledger_entries',      count(*) FROM ledger_entries
UNION ALL SELECT 'providers',           count(*) FROM providers
UNION ALL SELECT 'provider_routes',     count(*) FROM provider_routes
ORDER BY 2 DESC;

\echo '== 2. On-disk size per table (total / table / indexes) =='
SELECT c.relname                                                             AS table_name,
       pg_size_pretty(pg_total_relation_size(c.oid))                         AS total_size,
       pg_size_pretty(pg_total_relation_size(c.oid) - pg_indexes_size(c.oid)) AS table_size,
       pg_size_pretty(pg_indexes_size(c.oid))                                AS indexes_size,
       pg_total_relation_size(c.oid)                                         AS total_bytes,
       pg_indexes_size(c.oid)                                                AS indexes_bytes
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public'
  AND c.relkind = 'r'
ORDER BY pg_total_relation_size(c.oid) DESC;

\echo '== 3. The target query: a tenant''s 50 most recent transactions =='
-- SELECT * FROM transactions WHERE merchant_id = ? AND created_at > ?
--   ORDER BY created_at DESC LIMIT 50
--
-- :whale_id is the merchant with the most rows. With only idx_transactions_merchant_id,
-- Postgres reads every one of that merchant's rows, then sorts by created_at with no index
-- to help — watch the Bitmap Heap Scan row count, the "Rows Removed by Filter", and the Sort.
EXPLAIN (ANALYZE, BUFFERS)
SELECT *
FROM transactions
WHERE merchant_id = :'whale_id'::uuid
  AND created_at > now() - interval '30 days'
ORDER BY created_at DESC
LIMIT 50;

\echo '== 4. Rows per merchant (top 5) =='
SELECT merchant_id,
       count(*)                                            AS rows,
       round(100.0 * count(*) / sum(count(*)) OVER (), 2)  AS pct_of_table
FROM transactions
GROUP BY merchant_id
ORDER BY rows DESC
LIMIT 5;

\echo '== 5. Average bytes per row (seeded tables) =='
-- The projection number for the post: measured, not estimated. n_live_tup comes from
-- pg_stat_user_tables and is only trustworthy right after VACUUM ANALYZE (capacity-run.sh
-- runs one before this). Integer division, bytes.
SELECT s.relname                                        AS table_name,
       s.n_live_tup                                     AS live_rows,
       pg_total_relation_size(c.oid)                    AS total_bytes,
       pg_total_relation_size(c.oid) / NULLIF(s.n_live_tup, 0) AS bytes_per_row
FROM pg_stat_user_tables s
JOIN pg_class c ON c.oid = s.relid
WHERE s.relname IN ('merchants', 'api_keys', 'accounts',
                    'transactions', 'transaction_attempts', 'ledger_entries')
ORDER BY bytes_per_row DESC NULLS LAST;

\echo '== 6. Invariants (self-check): OLD checks always PASS; NEW checks (a,b,c) CAN fail =='
-- The OLD checks (1-4) are the naive ledger's own self-checks. They pass even on a fake ledger
-- whose two legs share one account, because they only test count/balance in aggregate. The NEW
-- checks (a,b,c) are the ones that a real double-entry ledger must satisfy and a naive one cannot:
--   a) every posting nets to zero AND touches >= 2 distinct accounts (real double-entry);
--   b) the whole ledger nets to zero;
--   c) each account's cached balance equals its ledger net (cache = truth; drift is a bug).
-- Note: none of these reference accounts.account_type, so this section also runs on the pre-V3
-- schema (the naive baseline) unchanged.
WITH success AS (SELECT count(*) AS n FROM transactions WHERE status = 'SUCCESS'),
     led AS (SELECT count(*) AS n FROM ledger_entries),
     bad_pair AS (
         SELECT count(*) AS n FROM (
             SELECT transaction_id
             FROM ledger_entries
             GROUP BY transaction_id
             HAVING count(*) FILTER (WHERE direction = 'DEBIT')  <> 1
                 OR count(*) FILTER (WHERE direction = 'CREDIT') <> 1
         ) x
     ),
     sums AS (
         SELECT coalesce(sum(amount) FILTER (WHERE direction = 'DEBIT'), 0)  AS d,
                coalesce(sum(amount) FILTER (WHERE direction = 'CREDIT'), 0) AS c
         FROM ledger_entries
     ),
     orphan AS (
         SELECT count(*) AS n
         FROM ledger_entries le
         JOIN transactions t ON t.id = le.transaction_id
         WHERE t.status <> 'SUCCESS'
     ),
     -- NEW (a): a real posting nets to 0 AND spans >= 2 distinct accounts. Same-account pairs
     -- net to 0 but touch ONE account, so the naive ledger fails this on every transaction.
     new_a AS (
         SELECT count(*) AS n FROM (
             SELECT transaction_id
             FROM ledger_entries
             GROUP BY transaction_id
             HAVING sum(CASE WHEN direction = 'CREDIT' THEN amount ELSE -amount END) <> 0
                 OR count(DISTINCT account_id) < 2
         ) x
     ),
     -- NEW (b): the whole ledger nets to 0.
     new_b AS (
         SELECT coalesce(sum(CASE WHEN direction = 'CREDIT' THEN amount ELSE -amount END), 0) AS s
         FROM ledger_entries
     ),
     -- NEW (c): each account's cached balance equals the signed sum of its entries. This is the
     -- cache-vs-truth check; an off-ledger balance write (or a fake ledger) makes it fail.
     new_c AS (
         SELECT count(*) AS n FROM (
             SELECT a.id
             FROM accounts a
             LEFT JOIN ledger_entries le ON le.account_id = a.id
             GROUP BY a.id, a.balance
             HAVING a.balance <> coalesce(
                 sum(CASE WHEN le.direction = 'CREDIT' THEN le.amount ELSE -le.amount END), 0)
         ) x
     )
SELECT ord, check_name, detail, CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS result
FROM (
    SELECT 1 AS ord, 'OLD 1: ledger_entries = 2 x SUCCESS'    AS check_name,
           format('ledger=%s, 2*success=%s', led.n, 2 * success.n) AS detail,
           led.n = 2 * success.n                                   AS ok
    FROM led, success
    UNION ALL
    SELECT 2, 'OLD 2: each txn 1 DEBIT + 1 CREDIT',
           format('violating txns=%s', bad_pair.n), bad_pair.n = 0
    FROM bad_pair
    UNION ALL
    SELECT 3, 'OLD 3: sum(DEBIT) = sum(CREDIT)',
           format('debit=%s, credit=%s', sums.d, sums.c), sums.d = sums.c
    FROM sums
    UNION ALL
    SELECT 4, 'OLD 4: no ledger rows for FAILED/PENDING',
           format('orphan rows=%s', orphan.n), orphan.n = 0
    FROM orphan
    UNION ALL
    SELECT 5, 'NEW a: per txn nets 0 AND >= 2 distinct accounts',
           format('non-conforming txns=%s', new_a.n), new_a.n = 0
    FROM new_a
    UNION ALL
    SELECT 6, 'NEW b: whole ledger nets to 0',
           format('system net=%s', new_b.s), new_b.s = 0
    FROM new_b
    UNION ALL
    SELECT 7, 'NEW c: accounts.balance = ledger net (cache=truth)',
           format('drifted accounts=%s', new_c.n), new_c.n = 0
    FROM new_c
) checks
ORDER BY ord;
