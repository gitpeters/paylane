# Deliberate flaws — design log

This is the design log for Paylane's **build-the-broken-version-first** approach (see the
boxed rule in `CLAUDE.md`). The migrations and code are written to read as if a competent
engineer thought they were correct — **the notes about what is deliberately wrong live here,
not in the source.** If you are tempted to "fix" one of these in place, check this table first:
it is almost certainly the before-state a specific post depends on.

Each row is a flaw, why it is present, and the post that removes it. Post numbers come from the
hints in `docs/domain-model.md` and `docs/conventions.md`; where a post isn't yet numbered, the
column names the concept instead.

| Flaw | Why it's there | Post that removes it |
|---|---|---|
| `accounts.balance` is a mutable `BIGINT` treated as the source of truth | The naive model writes a balance column directly instead of deriving it from the ledger — the setup for showing why that is unrecoverable | **Topic 04** — the ledger becomes the source of truth; these columns become a derived cache |
| No `@Version` / optimistic-lock column anywhere | Two concurrent balance updates must be able to lose an update on purpose, so the race is demonstrable | **Topic 04 / concurrency** — optimistic locking on the account |
| Money column is named `amount`, not `amount_minor` | Ambiguous naming that a real team drifts into; the value is still minor units, but nothing at the boundary says so | Naming alignment (no dedicated post) |
| `transactions` is a plain, non-partitioned table with no partition key | Single-table growth is the baseline the partitioning post starts from | **Topic 17** — partition `transactions` by month |
| The only index on `transactions` is single-column `merchant_id` (no `created_at`) | The "recent transactions for a tenant" query has to read all of a merchant's rows and sort them with no supporting index — this is the capacity/EXPLAIN evidence | Indexing / capacity topic — composite `(merchant_id, created_at)` (and later, partitioning) |
| No row-level security | Tenant isolation is enforced only in application code, so a missing `WHERE merchant_id = ?` can leak across tenants | Multi-tenant isolation / RLS topic |
| No idempotency table, and no unique constraint on `transactions.reference` | A retried charge can be recorded twice — the duplicate-charge demo needs the missing uniqueness/idempotency | **Topic 03** — `Idempotency-Key` and a per-merchant unique reference |
| `POST /v1/charges` accepts no `Idempotency-Key`, does no request fingerprinting, and does not dedupe on `merchantReference` | The charge path runs the whole insert → provider → ledger → balance flow every call; a retried request creates a second transaction, a second ledger pair, and a second balance credit | **Topic 03** — `Idempotency-Key` + request fingerprint + per-merchant unique reference |
| No timeout (connect or read) on the provider client | The stub holds the call open for 30s; the caller times out at 10s and retries, but the original charge still completes server-side — the client timeout is exactly what triggers the duplicate | **Topic 03** — a bounded provider timeout, and the safe-retry story around it |
| No retry and no circuit breaker on the provider call | Kept naive so the only retry in the story is the caller's blind re-send; nothing here makes a second attempt safe | **Topic 03** (and later resilience topics) — idempotent retries behind a breaker |
| `ledger_entries` pairs DEBIT and CREDIT against the **same** `account_id` | A real double-entry pair needs a counterparty account (provider settlement / suspense). `sum(DEBIT)=sum(CREDIT)` passes trivially because both legs hit the same account, so the balance check proves nothing yet | **Topic 04** — post the credit against a settlement/suspense counterparty account |
| No `@Transactional` anywhere in the charge path | Deliberate — each step (insert → provider → attempt → ledger → balance → status) autocommits on its own, so a mid-flow failure leaves partial state. This is the reverse case Topic 05 builds on. **Do not add `@Transactional` before then.** | **Topic 05** — a transaction boundary around the provider call |
| No `Idempotency-Key` handling, no request fingerprinting, no unique constraint on `(merchant_id, reference)` | Nothing at the API or the schema stops a retried charge from creating a second transaction, ledger pair, and balance credit | **Topic 03** — `Idempotency-Key`, request fingerprint, and a unique `(merchant_id, reference)` |

## Source notes that were moved here

These comments were removed from `V1__create_core_tables.sql` so the migration reads as
innocent. They are recorded here instead:

- `accounts.balance … -- mutable by design` → row 1 above.
- `transactions.reference … -- NOT unique yet` → row 7 above.
- The two-line comment above `idx_transactions_merchant_id`
  ("deliberately-insufficient … does NOT help the `ORDER BY created_at DESC`") → row 5 above.
- The 19-line `INTENTIONAL, TRACKED DESIGN CHOICES` header block (its 7 enumerated items map
  onto the rows above).
