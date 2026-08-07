-- V1 — Paylane core schema.
--
-- Money is stored in minor units (kobo/cents) as BIGINT — never float or BigDecimal.
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
    balance     BIGINT      NOT NULL DEFAULT 0,   -- minor units
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE transactions (
    id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    merchant_id UUID        NOT NULL REFERENCES merchants (id),
    reference   VARCHAR(255) NOT NULL,             -- merchant-supplied
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

-- Index on merchant_id for tenant-scoped lookups.
CREATE INDEX idx_transactions_merchant_id ON transactions (merchant_id);
