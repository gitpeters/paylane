# Architecture

Paylane is a **modular monolith**. One deployable, hard internal boundaries.

That's a deliberate choice and it's a teaching point: most systems that "need microservices"
need a module boundary and an index. If a topic genuinely requires a second process (queue
consumers, scheduled workers), we split *that* out and explain why — never by default.

---

## Runtime shape

```
Merchant app
     │  HTTPS + API key
     ▼
┌─────────────────────────────────────────┐
│  Paylane (Spring Boot)                  │
│                                         │
│  charge → routing → provider client ────┼──▶ Paystack / Stripe / Monnify
│     │                                   │        (WireMock locally)
│     ▼                                   │
│  ledger (double-entry)                  │
│     │                                   │
│     ▼                                   │
│  outbox ──▶ RabbitMQ ──▶ consumers      │
│                │                        │
│                ├─▶ outbound webhooks ───┼──▶ Merchant endpoint
│                ├─▶ settlement           │
│                └─▶ notifications ───────┼──▶ MailHog
│                                         │
│  inbound webhooks ◀──────────────────────┼─── Provider callbacks
│  reconciliation (scheduled)             │
└─────────────────────────────────────────┘
     │                    │           │
  PostgreSQL           Redis      Prometheus / OTel
```

## Modules and their contracts

| Module | Owns | Depends on |
|---|---|---|
| `merchant` | Merchants, API keys, accounts, config | — |
| `charge` | Charge lifecycle, attempts, idempotency | merchant, provider, ledger, outbox |
| `ledger` | Double-entry entries, balances, invariants | — (deliberately dependency-free) |
| `provider` | Provider clients, routing, health, circuit breakers | — |
| `webhook.inbound` | Signature verification, raw storage, dispatch | charge, ledger |
| `webhook.outbound` | Merchant notification, retry, DLQ | — (consumes events) |
| `payout` | Withdrawals, batching, balance reservation | ledger, provider, merchant |
| `reconciliation` | Provider vs ledger comparison, discrepancies | ledger, provider |
| `outbox` | Transactional event publishing | — |

**`ledger` depends on nothing.** It's the correctness core. If something wants the ledger to
know about charges, that's inverted — the charge module tells the ledger to record entries.

## Cross-cutting

- **Tenancy** — `merchant_id` resolved from the API key at the filter, held in a request-scoped
  `TenantContext`, applied at the repository layer. Topic 22 replaces this with Postgres RLS.
- **Idempotency** — request fingerprint + stored response, keyed on `Idempotency-Key`
  (topic 03).
- **Observability** — correlation ID from header → MDC → RabbitMQ headers → provider client.
  Micrometer counters on every state transition; OTel spans on every external call.
- **Resilience** — every provider call: explicit timeout, retry with jittered backoff,
  circuit breaker, bulkhead. Configured per provider, never globally.

## Provider abstraction

```java
interface PaymentProvider {
    ProviderCharge initiate(ChargeRequest request);
    ProviderCharge fetch(String providerReference);
    WebhookVerification verify(RawWebhook raw);
    ProviderCapabilities capabilities();
}
```

- One implementation per provider, each owning its own quirks, error mapping, and DTOs.
- Provider DTOs never escape the package. Everything is mapped to our types at the boundary.
- Routing (`ProviderRoute`) picks a provider by currency, method, merchant preference,
  health and priority — not hardcoded anywhere.
- Locally, all three are WireMock stubs with recorded fixtures, including the interesting
  cases: timeouts, 500s, duplicate webhooks, out-of-order webhooks, wrong amounts.

## Data flow: a charge

1. `POST /v1/charges` with `Idempotency-Key`
2. Resolve tenant from API key → `TenantContext`
3. Idempotency check → replay stored response if seen
4. Persist `Transaction` (PENDING) + `LedgerEntry` pair (pending account) + `OutboxEvent`
   — **one transaction, no external calls inside it**
5. Commit
6. Route → provider client (outside the transaction) → `TransactionAttempt`
7. Provider webhook arrives → verify → store raw → dispatch
8. Settle: ledger entries move pending → available, transaction → SUCCESS, outbox event
9. Outbox poller publishes → RabbitMQ → merchant webhook + notification

Steps 4 and 6 being separate is the whole point of topic 05. Step 4 including the outbox is
topic 07. The system is designed so these lessons are structural, not bolted on.

## What we deliberately do NOT have

No Kubernetes, no service mesh, no Kafka, no CQRS, no event sourcing, no GraphQL. Each of
those is a defensible choice at some scale and an anchor at ours. If a topic needs one, we
add it, measure it, and say honestly what it cost.
