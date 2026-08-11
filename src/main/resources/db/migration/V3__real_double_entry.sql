-- V3 — real double-entry.
--
-- Topic 04 (the fix). The naive ledger posted both legs of every pair against the merchant's
-- own account and treated accounts.balance as the truth. This migration makes the ledger the
-- truth: accounts get a TYPE, a successful charge posts to TWO different accounts, ledger
-- entries become immutable at the database, and accounts.balance is documented as a cache.
--
-- Money stays BIGINT minor units throughout. This migration adds no money columns.

-- 1. Accounts get a type, and system accounts have no merchant. -----------------------------
ALTER TABLE accounts ADD COLUMN account_type VARCHAR(32);
ALTER TABLE accounts ALTER COLUMN merchant_id DROP NOT NULL;

COMMENT ON COLUMN accounts.account_type IS
    'MERCHANT_AVAILABLE (one per merchant per currency) | PROVIDER_SETTLEMENT, FEES_REVENUE '
    '(system-owned, merchant_id IS NULL). A charge debits PROVIDER_SETTLEMENT and credits '
    'MERCHANT_AVAILABLE — two different accounts.';

-- Existing accounts are all merchant balances -> MERCHANT_AVAILABLE. Backfill before NOT NULL.
UPDATE accounts SET account_type = 'MERCHANT_AVAILABLE' WHERE account_type IS NULL;

-- Seed the system accounts: one PROVIDER_SETTLEMENT and one FEES_REVENUE per operating currency.
-- Every currency that already has merchant accounts, plus NGN (the operating currency) so a
-- fresh database still has them for the charge path. Idempotent via NOT EXISTS.
INSERT INTO accounts (merchant_id, account_type, currency, balance)
SELECT NULL, t.account_type, c.currency, 0
FROM (SELECT DISTINCT currency FROM accounts WHERE currency IS NOT NULL
      UNION SELECT 'NGN') c
CROSS JOIN (VALUES ('PROVIDER_SETTLEMENT'), ('FEES_REVENUE')) AS t(account_type)
WHERE NOT EXISTS (
    SELECT 1 FROM accounts a
    WHERE a.merchant_id IS NULL
      AND a.account_type = t.account_type
      AND a.currency = c.currency
);

ALTER TABLE accounts ALTER COLUMN account_type SET NOT NULL;

-- 4. accounts.balance is now explicitly a CACHE of the ledger, not the source of truth. --------
COMMENT ON COLUMN accounts.balance IS
    'CACHE of the ledger, not the source of truth. Equals the signed sum (CREDIT − DEBIT) of '
    'this account''s ledger_entries, written in the SAME transaction as the entries. Any drift '
    'from that sum is a bug — see invariant check (c) in analysis/capacity.sql.';

-- 3. Immutability, enforced at the database — not just documented. -----------------------------
-- A ledger is append-only: corrections are new reversing entries, never edits. Any UPDATE or
-- DELETE on a row is a defect, so the database refuses it.
CREATE OR REPLACE FUNCTION ledger_entries_immutable() RETURNS trigger
    LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION
        'ledger_entries is append-only: % blocked (id=%). A correction is a new reversing entry.',
        TG_OP, COALESCE(OLD.id, NEW.id)
        USING ERRCODE = 'restrict_violation';
END;
$$;

CREATE TRIGGER ledger_entries_no_update_delete
    BEFORE UPDATE OR DELETE ON ledger_entries
    FOR EACH ROW EXECUTE FUNCTION ledger_entries_immutable();

-- 6. Backfill report — do NOT rewrite history. -------------------------------------------------
-- The rows written before this topic are same-account pairs and will fail the new per-transaction
-- invariant (a): they touch only one account_id. A real ledger is not retconned, so they are left
-- exactly as they are. Report the count — it is the migration boundary, and useful in the post.
DO $$
DECLARE
    non_conforming bigint;
BEGIN
    SELECT count(*) INTO non_conforming
    FROM (
        SELECT transaction_id
        FROM ledger_entries
        GROUP BY transaction_id
        HAVING count(DISTINCT account_id) < 2
    ) single_account_pairs;

    RAISE NOTICE
        'V3 backfill: % existing transaction(s) have single-account (non-conforming) ledger pairs; '
        'left unchanged — a ledger is not retconned.', non_conforming;
END;
$$;
