# Testing

Tests here do double duty: they verify the system **and** they produce the evidence that
goes in the posts. A flaky test is worse than useless — it can't prove anything publicly.

---

## Stack

JUnit 5 · AssertJ · Testcontainers (PostgreSQL 18, RabbitMQ, Redis) · WireMock (providers)
· Awaitility (async) · k6 (load) · Spring Boot Test slices.

No H2. Ever. Half the topics depend on real Postgres behaviour — locking, isolation, plan
choice — and H2 lies about all of it.

## Layers

| Type | Scope | Speed | Use for |
|---|---|---|---|
| Unit | One class, mocked collaborators | ms | Money math, routing rules, mappers, state machines |
| Slice | `@DataJpaTest`, `@WebMvcTest` | fast | Repository queries, controller contracts |
| Integration | Full context + Testcontainers | slow | Anything crossing a boundary. **Most topic evidence lives here.** |
| Load | k6 against a running instance | slowest | Anything claiming a latency or throughput number |

## Naming and structure

`methodName_condition_expectedOutcome`, Given/When/Then blocks, one behaviour per test.

```java
@Test
void initiateCharge_concurrentDuplicateRequests_createsOnlyOneLedgerPair() { ... }
```

## Reproducing failures deterministically — the important part

Concurrency evidence must be **repeatable**, not "run it 20 times and screenshot the bad one."

```java
int threads = 2;
var start = new CountDownLatch(1);
var done  = new CountDownLatch(threads);
var pool  = Executors.newFixedThreadPool(threads);

for (int i = 0; i < threads; i++) {
    pool.submit(() -> {
        start.await();              // release both at the same instant
        chargeService.initiate(sameRequest);
        done.countDown();
        return null;
    });
}
start.countDown();
done.await(10, SECONDS);

// The assertion IS the evidence:
assertThat(ledgerEntryRepository.countByTransactionReference(ref)).isEqualTo(2); // fails: 4
```

Techniques allowed for forcing an interleaving:
- Latches to align thread start
- A test-profile bean that injects a delay at a specific point (`@TestConfiguration`, never
  a `sleep` in production code)
- Postgres advisory locks held by the test to pin ordering
- WireMock delays and faults to simulate slow/failing providers
- Killing a Testcontainer mid-flow for at-least-once and crash-recovery topics

Not allowed: `Thread.sleep` as the synchronisation mechanism, retrying until it fails,
or asserting on timing.

## The invariant test

`LedgerInvariantTest` asserts I1, I2 and I5 from `docs/domain-model.md` after every
integration scenario. It runs on every build and is never disabled. If a topic's naive
version breaks it, that failure output **is** the evidence — capture it before fixing.

## Test data

- One `TestDataFactory` with builders. No fixture SQL scattered across files.
- Every test creates its own merchant. Tests never share tenant state.
- Amounts in tests are realistic (₦45,000 = `4500000`), not `1` — realistic numbers make
  screenshots believable.

## Load tests

- k6 scripts in `load/`, one per topic that claims a number.
- Always record: p50/p95/p99, throughput, error rate, and the machine it ran on.
- Run before and after the fix, same conditions, same data volume. Both numbers go in
  `NOTES.md`.
- Never quote a load number in a post that came from a different run than the one recorded.

## Coverage

Not a target. But: every invariant has a test, every failure mode in a topic has a test that
reproduces it, and every fix has a test that would have caught the original bug. That last
one is the actual standard.
