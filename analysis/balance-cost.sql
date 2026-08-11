-- analysis/balance-cost.sql
--
-- The cache trade-off, measured. accounts.balance is a cache of the ledger; this file shows what
-- it buys. Reading the cached balance is a single-row primary-key lookup. Deriving the same number
-- from the ledger sums every one of that account's entries — and there is no index on
-- ledger_entries.account_id, so it is a full scan. That gap is why the balance stays a cache.
--
-- Run against the whale merchant's MERCHANT_AVAILABLE account after a fresh 4M-row seed:
--
--     ./scripts/capacity-run.sh 4000000
--     psql ... -f analysis/balance-cost.sql
--
-- The whale is pinned in the seed. Resolve its account id to a literal with \gset so both plans
-- use a constant (stable estimates), not a parameter or a subquery.

\set whale '96444bf1-5cb9-4cf4-8efd-00cc01aafa9c'
SELECT id AS acct
FROM accounts
WHERE merchant_id = :'whale'::uuid
  AND account_type = 'MERCHANT_AVAILABLE'
  AND currency = 'NGN'
\gset

\echo '== whale MERCHANT_AVAILABLE account id =='
\echo :acct

\echo '== A. read the cached balance: SELECT balance FROM accounts WHERE id = ? (PK lookup) =='
EXPLAIN (ANALYZE, BUFFERS)
SELECT balance
FROM accounts
WHERE id = :acct;

\echo '== B. derive it from the ledger: SUM over the account''s entries (no index on account_id) =='
EXPLAIN (ANALYZE, BUFFERS)
SELECT SUM(CASE WHEN direction = 'CREDIT' THEN amount ELSE -amount END) AS ledger_balance
FROM ledger_entries
WHERE account_id = :acct;

\echo '== sanity: cache == truth for the whale account =='
SELECT a.balance AS cached_balance,
       (SELECT SUM(CASE WHEN direction = 'CREDIT' THEN amount ELSE -amount END)
        FROM ledger_entries WHERE account_id = a.id) AS ledger_truth,
       (SELECT count(*) FROM ledger_entries WHERE account_id = a.id) AS entries_summed
FROM accounts a
WHERE a.id = :acct;
