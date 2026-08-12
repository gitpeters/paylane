# Domain Model

Nine tables. This is the entire system. **Adding a table requires my approval** — scope creep
is the main way a 24-topic series dies.

---

## Tables

### `merchant`
`id` · `name` · `country` · `default_currency` · `status` · `created_at`

### `api_key`
`id` · `merchant_id` · `key_hash` (never the raw key) · `key_prefix` (for display: `pk_live_a1b2…`)
· `last_used_at` · `revoked_at`

### `account`
`id` · `merchant_id` (nullable = system-owned) · `account_type` · `currency` · `available_minor`
· `pending_minor` · `reserved_minor` · `version`

`account_type` is one of:

- `MERCHANT_AVAILABLE` — a merchant's own balance. One per merchant per currency; `merchant_id` set.
- `PROVIDER_SETTLEMENT` — system-owned (`merchant_id` NULL). The counterparty a charge debits.
- `FEES_REVENUE` — system-owned (`merchant_id` NULL). Where processing fees are booked.

> A charge is real double-entry across **two** accounts: DEBIT `PROVIDER_SETTLEMENT`, CREDIT
> `MERCHANT_AVAILABLE` — never both legs on one account. Introduced in topic 04.

> The balance columns are a **derived cache**, not the source of truth. The ledger is the
> truth. Topic 04 builds the naive version where these columns *are* the truth, then shows
> why that's unrecoverable — and then makes the ledger the truth, with the cache kept in the
> same transaction as the entries.

### `transaction`
`id` · `merchant_id` · `reference` (merchant-supplied, unique per merchant) · `amount_minor`
· `currency` · `status` (PENDING/SUCCESS/FAILED/REVERSED) · `customer_ref` · `metadata` (jsonb)
· `created_at` · `updated_at`
Partitioned by month from topic 17.

### `transaction_attempt`
`id` · `transaction_id` · `provider` · `provider_reference` · `status` · `request_snapshot`
(jsonb, redacted) · `response_snapshot` (jsonb, redacted) · `latency_ms` · `error_code`
· `attempted_at`

One row per provider try. Retries and failovers are visible here — this table is where most
of the series' evidence screenshots come from.

### `ledger_entry`
`id` · `transaction_id` · `account_id` · `direction` (DEBIT/CREDIT) · `amount_minor`
· `currency` · `entry_type` · `balance_bucket` (AVAILABLE/PENDING/RESERVED) · `created_at`

**Append-only.** No updates, no deletes, ever. A correction is a new reversing pair.

### `provider_route`
`id` · `merchant_id` (nullable = global default) · `provider` · `currency` · `method`
· `priority` · `enabled` · `health_status`

### `webhook_event`
`id` · `provider` · `event_type` · `raw_payload` (text, stored **before** parsing)
· `signature` · `signature_valid` · `received_at` · `processed_at` · `processing_status`
· `dedupe_key`

### `outbox_event`
`id` · `aggregate_type` · `aggregate_id` · `event_type` · `payload` (jsonb) · `created_at`
· `published_at` · `attempts` · `last_error`

### `idempotency_key`
`id` · `merchant_id` · `key` · `request_fingerprint` (hash of method+path+body)
· `response_status` · `response_body` · `created_at` · `expires_at`
Unique on `(merchant_id, key)`.

### `reconciliation_run` / `reconciliation_discrepancy`
Run: `id` · `provider` · `window_start` · `window_end` · `status` · `records_compared` · `discrepancies_found`
Discrepancy: `id` · `run_id` · `transaction_id` · `type` (MISSING_LOCAL/MISSING_REMOTE/AMOUNT_MISMATCH/STATUS_MISMATCH)
· `local_value` · `remote_value` · `resolved_at` · `resolution_note`

*(Counting generously that's 11 — reconciliation is one concept in two tables. Still fixed.)*

---

## Invariants — verify these after any money-touching change

**I1 — The ledger balances.**
```sql
SELECT transaction_id,
       SUM(CASE WHEN direction='DEBIT' THEN amount_minor ELSE -amount_minor END) AS delta
FROM ledger_entry GROUP BY transaction_id HAVING SUM(...) <> 0;
```
Must return zero rows. Globally too.

**I2 — Cached balances match the ledger.** For every account, `available_minor` equals the
signed sum of its AVAILABLE-bucket entries. Drift means a bug, always.

**I3 — No negative available balance.** Unless a topic is explicitly demonstrating that
failure, in which case it's the evidence.

**I4 — Ledger entries are immutable.** Any `UPDATE` or `DELETE` on `ledger_entry` is a defect.

**I5 — Tenant isolation.** No query returns rows for more than one `merchant_id` unless it's
an explicitly-marked admin/reconciliation query.

**I6 — Every transaction has at least one attempt** once it has left PENDING.

**I7 — Idempotency keys are scoped per merchant.** Merchant A's key never matches B's.

Invariants I1, I2 and I5 are asserted in an integration test that runs on every build:
`LedgerInvariantTest`. Never disable it. If it fails, that's the topic.

---

## Money handling

- Minor units, `long`, always. `₦450.50` is `45050` with currency `NGN`.
- Never mix currencies in one transaction or one ledger pair.
- Rounding is explicit at the call site; there is no ambient default.
- Provider amounts are converted at the client boundary and asserted to round-trip exactly.
  A mismatch throws — silent truncation of money is unrecoverable.

## Status transitions

```
Transaction:  PENDING ──▶ SUCCESS ──▶ REVERSED
                  └────▶ FAILED
```
Terminal states never transition back. A late webhook contradicting a terminal state is
recorded as a discrepancy, not applied. (Topic 23.)
