# Conventions

Java 21, Spring Boot 3.x, Maven. Read this before writing code; don't re-read it every turn.

---

## Package structure — feature-first, not layer-first

```
com.paylane
├── charge/          ChargeController, ChargeService, ChargeRepository, dto/, domain/
├── ledger/
├── merchant/
├── provider/        provider/paystack/, provider/stripe/, provider/monnify/
├── webhook/         webhook/inbound/, webhook/outbound/
├── payout/
├── reconciliation/
├── outbox/
└── common/          error/, config/, security/, money/, tenancy/, observability/
```

Rules:
- A feature package owns its controller, service, repository, entities and DTOs.
- Cross-feature calls go **service → service**, never repository → other feature's repository.
- `common` holds only genuinely shared code. If something is used by one feature, it lives
  in that feature.
- No `util` package. Name things after what they do.

## Layers

| Layer | Owns | Never |
|---|---|---|
| Controller | HTTP, validation, status codes, DTO mapping | Business logic, transactions, entities in signatures |
| Service | Business rules, transaction boundaries, orchestration | HTTP concerns, `HttpServletRequest`, `ResponseEntity` |
| Repository | Data access, tenant-scoped queries | Business rules |
| Provider client | One external API, its quirks, its error mapping | Knowledge of our domain beyond its own DTOs |

DTOs never leak entities. Entities never leave the service layer.

## Naming

- Services: `ChargeService`. Interface only when there's a real second implementation —
  no `IChargeService`, no `ChargeServiceImpl` for a single class.
- Booleans: `isSettled`, `hasBalance`, `canRetry`.
- Methods say what, not how: `reserveFunds()` not `updateBalanceColumn()`.
- Tests: `methodName_condition_expectedOutcome` —
  `initiateCharge_duplicateIdempotencyKey_returnsOriginalResponse`.
- Migrations: `V<seq>__verb_object.sql` — `V014__add_idempotency_keys_table.sql`.
- No abbreviations except the universally known ones (id, url, api, http, dto).

## Money — the rules that matter most here

- Store and compute in **minor units** as `long` (kobo, cents). Never `float`, never `double`.
- A `Money` value type wraps `long amountMinor` + `Currency`. Arithmetic across currencies
  throws, never silently converts.
- Rounding is explicit and always stated at the call site. Never rely on a default.
- Amounts crossing the API boundary are integers in minor units, with the currency alongside.
  Never a decimal string.
- Anything that changes a balance writes ledger entries. There is no other way to move money.

## Transactions

- `@Transactional` on the **service** method, never the controller, never the repository.
- **Never hold a transaction open across an HTTP call, a queue publish, or a file write.**
  This is the single most damaging pattern in this codebase's problem space.
- Default isolation is READ COMMITTED. Anything stricter is explicit and commented with why.
- Read-only operations: `@Transactional(readOnly = true)`.
- Cross-service side effects go through the outbox, not inline.

## Error handling

- Domain errors are typed exceptions extending `PaylaneException` with a stable `errorCode`
  string. Clients switch on the code, never on the message.
- One `@RestControllerAdvice` maps exceptions to RFC 9457 problem details.
- Never catch `Exception` to log and continue. Never swallow. Never `e.printStackTrace()`.
- Errors from providers map into our own taxonomy at the client boundary — provider error
  shapes never reach the service layer.
- Retryable vs terminal must be explicit on every failure. "Unknown" is retryable only if the
  operation is idempotent, and that decision gets a comment.

## Logging

- SLF4J, parameterised: `log.info("Charge settled: chargeId={} merchantId={}", id, mid)`.
- Every log line in a request path carries `chargeId` or `transactionId` and `merchantId`.
- Correlation ID from header → MDC → queue headers → provider call. Never dropped.
- **Never log:** request/response bodies on payment endpoints, card data, full API keys,
  customer PII, provider credentials. Mask to last 4 where a reference is genuinely needed.
- Levels: ERROR = someone must act. WARN = degraded but handled. INFO = state transitions.
  DEBUG = everything else. No INFO logging inside loops.

## API design

- REST, plural nouns: `/v1/charges`, `/v1/merchants/{id}/payouts`.
- Versioned in the path from day one.
- Mutating endpoints accept `Idempotency-Key`. (Topic 03 — the naive version won't.)
- Pagination is cursor-based on `(created_at, id)`, never `OFFSET`.
- Timestamps are UTC ISO-8601 with offset. Store as `timestamptz`.
- Request validation via Bean Validation on DTOs; business validation in the service.

## Persistence

- Entities are JPA, but complex reads use explicit JPQL or native SQL — no accidental
  Cartesian products from entity graphs.
- `FetchType.LAZY` on every association. No exceptions.
- Every repository method filters by `merchant_id`, either explicitly or via the tenant
  context. A method that can't is a design error — raise it.
- Indexes are created in migrations, named `idx_<table>_<cols>`, with a comment saying which
  query they serve.
- No `spring.jpa.hibernate.ddl-auto` beyond `validate`. Flyway owns the schema.

## Configuration

- No magic numbers in code. Timeouts, limits, retries, batch sizes → `application.yml`
  bound to `@ConfigurationProperties` records.
- Profiles: `local`, `test`, `prod`. Secrets from env vars only.
- Every timeout is set explicitly. A default timeout is a missing timeout.

## Style

- Records for DTOs and value objects. Constructor injection only, no field `@Autowired`.
- `final` on fields and parameters that don't change.
- Methods under ~30 lines. Classes under ~300. If you're past it, the design is wrong.
- No Lombok `@Data` on entities. `@Getter` and explicit constructors are fine.
- Comments explain *why*, never *what*. If a line needs a "what" comment, rename something.
- Format on save; keep lines under 120 chars — **long lines screenshot badly and that matters
  in this repo.**
