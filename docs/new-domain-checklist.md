# New Domain Checklist

For when Paylane's 24 topics are done and the series moves to a new domain.

The workflow is the asset, not the payments code. Almost nothing needs rewriting.

---

## Carries over unchanged

- `docs/topic-workflow.md` — the 6-phase loop and gates
- `docs/content-capture.md` — evidence and screenshot standards
- `docs/testing.md` — minus any Postgres-specific bits if the stack changes
- `.claude/agents/*` — architect, backend, qa, adversary
- `.claude/commands/*` — topic-start, capture-evidence, topic-close
- `content/topics/_TEMPLATE/NOTES.md`
- Most of `docs/conventions.md` if the language stays the same

## Gets rewritten

| File | What changes |
|---|---|
| `CLAUDE.md` | The "What this repo is" section, stack, current state. The boxed build-the-broken-version-first rule stays word for word. |
| `docs/architecture.md` | Entirely |
| `docs/domain-model.md` | Entirely |
| `docs/domain/<name>.md` | New file, old one deleted |
| `docs/conventions.md` | Only if the stack changes |

---

## Choosing the next domain

The same four tests that picked Paylane:

1. **Do I have real scars in it?** Authority beats research. If I'd be citing rather than
   remembering, it's the wrong domain.
2. **Does it generate the topics naturally?** The topic list should feel discovered, not
   forced. If I have to invent a reason to talk about sharding, the domain is wrong.
3. **Are the failures dramatic and visible?** The reverse-case format needs pain with
   evidence. Abstract "inefficiency" doesn't screenshot.
4. **Is it saturated?** Skip whatever the last six viral system design threads used.

## Domains that pass those tests

| Domain | Why it works | Topics it naturally owns |
|---|---|---|
| **Ride-hailing dispatch** | Geospatial, real-time, matching under contention | Geo indexing, matching algorithms, WebSocket scale, state machines, surge, hot partitions |
| **Multi-tenant booking/inventory** | Overselling is a vivid, universal failure | Reservations, optimistic locking, TTL holds, calendars, timezone hell, availability caching |
| **Logistics tracking** | Streams of events, ordering, offline devices | Event ordering, late/duplicate events, geofencing, at-least-once, time-series storage |
| **Notification/messaging platform** | Fan-out, delivery guarantees, preferences | Fan-out patterns, priority queues, rate limiting per channel, template rendering, deliverability |
| **Real-time analytics / metering** | Aggregation under volume, correctness vs freshness | Stream vs batch, windowing, late data, pre-aggregation, cardinality explosions |

A **usage-based billing/metering platform** deserves a special mention: it's the natural
sequel to Paylane, reuses the ledger intuition, and covers streams, aggregation and
correctness-under-volume without repeating a single topic.

## Reuse rule between domains

**Never repeat a topic with a new coat of paint.** If idempotency was topic 03 in Paylane,
the next domain doesn't get an idempotency post. Each domain earns its slot by teaching what
the previous one couldn't. That constraint is what keeps the series worth following at post 60.

## Continuity between series

- Keep one public index post linking every series and every topic. It compounds.
- Reference the previous domain when a pattern recurs: *"we solved this with an outbox in
  Paylane; here it doesn't work, because…"* — that's the kind of continuity that turns a
  content series into a body of work.
- Keep every repo public and cross-linked.
