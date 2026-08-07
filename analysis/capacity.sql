-- analysis/capacity.sql
--
-- Capacity snapshot of the naive baseline schema after seeding (see SeedRunner).
-- Run against the seeded database:
--
--     PGPASSWORD=postgres psql -h localhost -p 5433 -U postgres -d paylane \
--         -f analysis/capacity.sql
--
-- Three sections: (1) row counts, (2) on-disk size, (3) the plan for the query the
-- whole indexing/partitioning story hangs on.

\echo '== 1. Row counts per table =='
SELECT 'merchants'            AS table, count(*) FROM merchants
UNION ALL SELECT 'api_keys',             count(*) FROM api_keys
UNION ALL SELECT 'accounts',             count(*) FROM accounts
UNION ALL SELECT 'transactions',         count(*) FROM transactions
UNION ALL SELECT 'transaction_attempts', count(*) FROM transaction_attempts
UNION ALL SELECT 'ledger_entries',       count(*) FROM ledger_entries
UNION ALL SELECT 'providers',            count(*) FROM providers
UNION ALL SELECT 'provider_routes',      count(*) FROM provider_routes
ORDER BY 2 DESC;

\echo '== 2. On-disk size per table (total / table / indexes) =='
SELECT c.relname                                                         AS table,
       pg_size_pretty(pg_total_relation_size(c.oid))                     AS total_size,
       pg_size_pretty(pg_total_relation_size(c.oid) - pg_indexes_size(c.oid)) AS table_size,
       pg_size_pretty(pg_indexes_size(c.oid))                            AS indexes_size,
       pg_total_relation_size(c.oid)                                     AS total_bytes,
       pg_indexes_size(c.oid)                                            AS indexes_bytes
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public'
  AND c.relkind = 'r'
ORDER BY pg_total_relation_size(c.oid) DESC;

\echo '== 3. The target query: a tenant''s 50 most recent transactions =='
-- SELECT * FROM transactions WHERE merchant_id = ? AND created_at > ?
--   ORDER BY created_at DESC LIMIT 50
--
-- Params below are filled with the WORST case: the "whale" merchant (the one the seed
-- gives ~40% of all rows — it is the earliest-created merchant, ord = 1) and a 30-day
-- window. With only idx_transactions_merchant_id, Postgres must read every one of that
-- merchant's rows, then sort them by created_at with no index to help — watch the Sort
-- node and its buffer counts. Substitute a literal uuid for '?' to test other tenants.
EXPLAIN (ANALYZE, BUFFERS)
SELECT *
FROM transactions
WHERE merchant_id = (SELECT id FROM merchants ORDER BY created_at, id LIMIT 1)
  AND created_at > now() - interval '30 days'
ORDER BY created_at DESC
LIMIT 50;
