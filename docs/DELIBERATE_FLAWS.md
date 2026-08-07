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

## Source notes that were moved here

These comments were removed from `V1__create_core_tables.sql` so the migration reads as
innocent. They are recorded here instead:

- `accounts.balance … -- mutable by design` → row 1 above.
- `transactions.reference … -- NOT unique yet` → row 7 above.
- The two-line comment above `idx_transactions_merchant_id`
  ("deliberately-insufficient … does NOT help the `ORDER BY created_at DESC`") → row 5 above.
- The 19-line `INTENTIONAL, TRACKED DESIGN CHOICES` header block (its 7 enumerated items map
  onto the rows above).
