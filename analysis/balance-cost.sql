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


-- ==============================================================================================
\echo '== C. an index on ledger_entries(account_id): MEASURED, NOT ADOPTED (indexing is post 15) =='
-- ==============================================================================================
-- What would an index buy? This section creates one, measures the read win (query B re-run
-- unchanged), the index's size, and its per-write cost (the three-charge loop, with vs without),
-- then DROPS it. It is deliberately NOT in any migration — the shipped schema stays index-free on
-- account_id until the indexing topic. Nothing here persists: the index is dropped and every
-- write-cost insert is rolled back (INSERT does not trip the immutability trigger).

-- FK targets for the write-cost inserts. Any existing SUCCESS txn works — the inserts roll back.
SELECT id AS demo_txn
FROM transactions
WHERE merchant_id = :'whale'::uuid AND status = 'SUCCESS'
LIMIT 1 \gset
SELECT id AS settle_acct
FROM accounts
WHERE merchant_id IS NULL AND account_type = 'PROVIDER_SETTLEMENT' AND currency = 'NGN' \gset

\echo '-- C1. write cost of the three-charge loop WITHOUT the index (6 ledger rows, rolled back) =='
-- Three charges, each DEBIT PROVIDER_SETTLEMENT + CREDIT MERCHANT_AVAILABLE. A warm-up run first
-- (untimed — it pays the session's cold first-write costs), then the measured run: the INSERT
-- "Time:" line is the number. BEGIN/ROLLBACK bracket each so nothing persists (and the
-- immutability trigger, which only fires on UPDATE/DELETE, is never involved).
BEGIN;  -- warm-up, untimed
INSERT INTO ledger_entries (transaction_id, account_id, direction, amount, currency) VALUES
  (:'demo_txn', :settle_acct, 'DEBIT',  4500000, 'NGN'),
  (:'demo_txn', :acct,        'CREDIT', 4500000, 'NGN'),
  (:'demo_txn', :settle_acct, 'DEBIT',  4500000, 'NGN'),
  (:'demo_txn', :acct,        'CREDIT', 4500000, 'NGN'),
  (:'demo_txn', :settle_acct, 'DEBIT',  4500000, 'NGN'),
  (:'demo_txn', :acct,        'CREDIT', 4500000, 'NGN');
ROLLBACK;
\timing on
BEGIN;  -- measured
INSERT INTO ledger_entries (transaction_id, account_id, direction, amount, currency) VALUES
  (:'demo_txn', :settle_acct, 'DEBIT',  4500000, 'NGN'),
  (:'demo_txn', :acct,        'CREDIT', 4500000, 'NGN'),
  (:'demo_txn', :settle_acct, 'DEBIT',  4500000, 'NGN'),
  (:'demo_txn', :acct,        'CREDIT', 4500000, 'NGN'),
  (:'demo_txn', :settle_acct, 'DEBIT',  4500000, 'NGN'),
  (:'demo_txn', :acct,        'CREDIT', 4500000, 'NGN');
ROLLBACK;
\timing off

\echo '-- C2. create the index on ledger_entries(account_id), then ANALYZE =='
\timing on
CREATE INDEX idx_ledger_entries_account_id ON ledger_entries (account_id);
\timing off
ANALYZE ledger_entries;

\echo '-- C3. index size (the new index on its own, and pg_indexes_size = all indexes on the table) =='
SELECT pg_size_pretty(pg_relation_size('idx_ledger_entries_account_id')) AS new_index_size,
       pg_relation_size('idx_ledger_entries_account_id')                 AS new_index_bytes,
       pg_size_pretty(pg_indexes_size('ledger_entries'))                 AS all_indexes_on_ledger,
       pg_indexes_size('ledger_entries')                                 AS all_indexes_bytes;

\echo '-- C4. query B re-run UNCHANGED, now WITH the index =='
EXPLAIN (ANALYZE, BUFFERS)
SELECT SUM(CASE WHEN direction = 'CREDIT' THEN amount ELSE -amount END) AS ledger_balance
FROM ledger_entries
WHERE account_id = :acct;

\echo '-- C5. write cost of the same three-charge loop WITH the index (6 ledger rows, rolled back) =='
-- Same warm-up-then-measure as C1, so C1 and C5 are compared warm-to-warm. The delta between the
-- two measured INSERT times is the index's per-loop write penalty.
BEGIN;  -- warm-up, untimed
INSERT INTO ledger_entries (transaction_id, account_id, direction, amount, currency) VALUES
  (:'demo_txn', :settle_acct, 'DEBIT',  4500000, 'NGN'),
  (:'demo_txn', :acct,        'CREDIT', 4500000, 'NGN'),
  (:'demo_txn', :settle_acct, 'DEBIT',  4500000, 'NGN'),
  (:'demo_txn', :acct,        'CREDIT', 4500000, 'NGN'),
  (:'demo_txn', :settle_acct, 'DEBIT',  4500000, 'NGN'),
  (:'demo_txn', :acct,        'CREDIT', 4500000, 'NGN');
ROLLBACK;
\timing on
BEGIN;  -- measured
INSERT INTO ledger_entries (transaction_id, account_id, direction, amount, currency) VALUES
  (:'demo_txn', :settle_acct, 'DEBIT',  4500000, 'NGN'),
  (:'demo_txn', :acct,        'CREDIT', 4500000, 'NGN'),
  (:'demo_txn', :settle_acct, 'DEBIT',  4500000, 'NGN'),
  (:'demo_txn', :acct,        'CREDIT', 4500000, 'NGN'),
  (:'demo_txn', :settle_acct, 'DEBIT',  4500000, 'NGN'),
  (:'demo_txn', :acct,        'CREDIT', 4500000, 'NGN');
ROLLBACK;
\timing off

\echo '-- C6. drop the index — measured, not adopted =='
DROP INDEX idx_ledger_entries_account_id;
