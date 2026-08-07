-- V1 — Paylane core schema (the naive baseline).
--
-- INTENTIONAL, TRACKED DESIGN CHOICES. Do not "fix" these here — each one is the
-- before-state for a future post in the Deep Dive into System Design series:
--
--   1. accounts.balance is a mutable BIGINT column, treated as the source of truth.
--      (Topic on ledger-as-truth reverses this. Keep it mutable for now.)
--   2. The money column is named `amount`, NOT `amount_minor`. Still minor units.
--   3. transactions is a plain, NON-partitioned table with no partition key.
--      (Partitioning-by-month topic changes this.)
--   4. The ONLY index on transactions is a single-column index on merchant_id.
--      There is deliberately no index on created_at — the capacity/EXPLAIN topic
--      depends on the resulting sort being slow.
--   5. No @Version / optimistic-lock column anywhere.
--   6. No row-level security.
--   7. No idempotency table, and no unique constraint on transactions.reference.
--
-- All money is BIGINT in minor units (kobo/cents). Never float, never BigDecimal.
-- All timestamps are TIMESTAMPTZ, stored in UTC.

CREATE TABLE merchants (
    id         UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    name       VARCHAR(255) NOT NULL,
    status     VARCHAR(32)  NOT NULL DEFAULT 'ACTIVE',
    created_at TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE TABLE api_keys (
    id          BIGINT      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    merchant_id UUID        NOT NULL REFERENCES merchants (id),
    key_hash    VARCHAR(255) NOT NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE accounts (
    id          BIGINT      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    merchant_id UUID        NOT NULL REFERENCES merchants (id),
    currency    VARCHAR(3)  NOT NULL,
    balance     BIGINT      NOT NULL DEFAULT 0,   -- minor units; mutable by design
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE transactions (
    id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    merchant_id UUID        NOT NULL REFERENCES merchants (id),
    reference   VARCHAR(255) NOT NULL,             -- merchant-supplied; NOT unique yet
    amount      BIGINT      NOT NULL,              -- minor units
    currency    VARCHAR(3)  NOT NULL,
    status      VARCHAR(32) NOT NULL,
    provider    VARCHAR(64),
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE transaction_attempts (
    id             BIGINT      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    transaction_id UUID        NOT NULL REFERENCES transactions (id),
    provider       VARCHAR(64) NOT NULL,
    status         VARCHAR(32) NOT NULL,
    latency_ms     INTEGER,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE ledger_entries (
    id             BIGINT      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    transaction_id UUID        NOT NULL REFERENCES transactions (id),
    account_id     BIGINT      NOT NULL REFERENCES accounts (id),
    direction      VARCHAR(8)  NOT NULL,           -- DEBIT / CREDIT
    amount         BIGINT      NOT NULL,           -- minor units
    currency       VARCHAR(3)  NOT NULL,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE providers (
    id      BIGINT      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name    VARCHAR(64) NOT NULL,
    enabled BOOLEAN     NOT NULL DEFAULT true
);

CREATE TABLE provider_routes (
    id          BIGINT     GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    provider_id BIGINT     NOT NULL REFERENCES providers (id),
    currency    VARCHAR(3) NOT NULL,
    priority    INTEGER    NOT NULL,
    enabled     BOOLEAN    NOT NULL DEFAULT true
);

-- The single, deliberately-insufficient index on transactions. Serves lookups by
-- tenant; does NOT help the `ORDER BY created_at DESC` in the capacity query.
CREATE INDEX idx_transactions_merchant_id ON transactions (merchant_id);
