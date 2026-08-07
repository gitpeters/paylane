# Domain — Payments (Paylane)

Business rules and real-world behaviour. Read when a task touches money, providers, or
settlement semantics.

*(When the series moves to a new domain, this file is replaced wholesale. Everything in
`topic-workflow.md`, `content-capture.md`, `.claude/agents/` and `.claude/commands/` stays.)*

---

## The mental model

A payment is **not** a database write. It's a distributed agreement between you, a provider,
a bank, and a customer — where you control exactly one of the four participants and can be
lied to, timed out, or contradicted by any of the others.

Everything else in this domain follows from that.

## Rules that shape the code

**1. The network is not the source of truth about the outcome.**
A timeout means "unknown", never "failed". Charging again on a timeout is how double-charges
happen. Unknown outcomes are resolved by querying the provider, never by assuming.

**2. Webhooks arrive out of order, twice, late, or never.**
Design for all four. `charge.success` can arrive before your own HTTP response has returned.
A webhook can arrive for a transaction you have no record of. A webhook can arrive at 3am for
something that happened yesterday.

**3. Money that moves must be recorded twice.**
Every movement is a balanced debit/credit pair. This isn't accounting ceremony — it's the
only structure that lets you answer "why is this number what it is?" six months later.

**4. Balances are buckets, not a number.**
`available` (spendable), `pending` (charged, not settled), `reserved` (payout in flight).
A payout moves available → reserved → out. Skipping `reserved` is how you pay out twice.

**5. Provider settlement lags.** In NGN, T+1 is normal, weekends and public holidays push it
further. "Successful" and "settled" are different states and conflating them is a real bug
class, not a modelling nicety.

**6. You will disagree with the provider.** Not "might". Reconciliation isn't a feature for
later — it's the acknowledgement that your ledger and theirs will drift, and drift must be
detectable.

## Provider behaviours to model in WireMock

| Behaviour | Why it matters |
|---|---|
| 30s timeout then eventual success | The classic double-charge setup |
| 500 on a request that actually succeeded | Retry creates the duplicate |
| Duplicate webhook, same event ID | Dedupe or double-credit |
| Out-of-order webhooks (`success` before `pending`) | Naive state machines corrupt |
| Webhook for an unknown reference | Must not crash the consumer |
| Amount mismatch between charge and webhook | Trust the provider or your record? (Neither — flag it) |
| Rate limit 429 with `Retry-After` | Backoff must respect it |
| Slow-but-successful (8s) | Connection pool exhaustion under load |

These stubs are built in phase 1 of the project and reused by nearly every topic. Invest in
them early.

## Nigerian / African context (use as technical detail, never as disclaimer)

- Provider timeouts on local routes are common; 30s is a realistic p99, not an edge case.
- Bank downtime windows are scheduled and public — routing should degrade, not fail.
- NGN settlement is T+1 with holiday gaps; multi-currency merchants hold separate accounts.
- Customers retry aggressively on slow networks. Idempotency isn't theoretical here — a
  double-tap on a slow 3G connection is the single most common cause of duplicate charges.
- Amounts are large in nominal terms (₦450,000 = `45000000` minor). Integer overflow isn't a
  concern with `long`, but display formatting and provider limits are.

## Compliance boundaries (we simulate, we don't implement)

We never touch real card data. All card-like flows go through provider-hosted references and
tokens. If a topic seems to need raw PAN handling, it doesn't — reframe it.

Security topics (21) cover: key hashing, field-level encryption of customer identifiers,
secret management, log redaction. Not PCI certification.

## Vocabulary — use these words consistently in code and posts

| Term | Means |
|---|---|
| Charge | The attempt to collect money from a customer |
| Transaction | Our record of a charge, in any state |
| Attempt | One try against one provider |
| Settlement | Provider actually moving money to the merchant's balance |
| Payout | Merchant withdrawing from their available balance |
| Reversal | A completed movement undone by a compensating ledger pair |
| Reconciliation | Comparing our ledger against the provider's record |
| Discrepancy | A difference found during reconciliation, before it's explained |
