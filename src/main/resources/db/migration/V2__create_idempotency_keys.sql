-- V2: idempotency keys for POST /v1/charges (the double-charge fix).
--
-- A request claims (merchant_id, idempotency_key) before the provider call;
-- the UNIQUE constraint makes the claim atomic. Money is untouched here: all
-- amounts stay BIGINT minor units in the transactions/ledger tables.

CREATE TABLE idempotency_keys (
    id                  BIGINT       GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    merchant_id         UUID         NOT NULL REFERENCES merchants (id),
    idempotency_key     VARCHAR(255) NOT NULL,
    request_fingerprint CHAR(64)     NOT NULL,   -- SHA-256 hex
    status              VARCHAR(16)  NOT NULL,   -- IN_FLIGHT | COMPLETED
    response_status     INTEGER,
    response_body       JSONB,
    created_at          TIMESTAMPTZ  NOT NULL DEFAULT now(),
    expires_at          TIMESTAMPTZ  NOT NULL,
    UNIQUE (merchant_id, idempotency_key)
);
