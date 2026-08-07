# Topic Workflow

Every topic in the series runs through the same six phases. Each **GATE** is a hard stop:
present, then wait for my explicit approval. Never cross a gate on your own initiative.

Announce the phase you're in at the start of every response during a topic.

---

## Phase 0 — Frame

**Goal:** agree on what this topic teaches before any code exists.

Produce:
1. **The concept** in one paragraph — the mechanism, not the definition.
2. **The naive approach** — what a competent engineer or coding agent would write here,
   and why it looks correct.
3. **The failure** — precisely how it breaks. Which two operations interleave, which
   assumption fails, at what scale.
4. **How we'll prove it** — the exact reproduction: a concurrent test, a killed consumer,
   a 40M-row table, a stalled provider. Must be deterministic, not "run it a few times".
5. **The fix** — the design, and the alternatives rejected with reasons.
6. **The trade-off** — what the fix costs. Measurable if possible.
7. **Blast radius** — files and migrations affected.

> ### 🚦 GATE 0 — I approve the frame before anything is written.

---

## Phase 1 — Build the naive version

**Goal:** a realistic wrong implementation.

- Write it into the normal source tree — not a scratch folder. It has to look like real code.
- **Do not harden it.** Re-read the boxed rule in `CLAUDE.md`. No guard clauses, no
  "just in case" checks, no warning comments.
- It must compile, pass a happy-path test, and be something you'd sign off on in review if
  you weren't looking for this specific flaw.
- Commit it on a branch: `topic/<nn>-<slug>/before`.

Report: what you built, and one line confirming you did not add the missing safeguard.

> ### 🚦 GATE 1 — I review the naive code before we break it.

---

## Phase 2 — Capture the failure

**Goal:** evidence that will go into the post.

- Write the reproduction from Phase 0 as a **real, repeatable test** (see `docs/testing.md`).
  Concurrency uses `CountDownLatch` / `ExecutorService`, not `Thread.sleep` and hope.
- Run it. Capture, per `docs/content-capture.md`:
  - Failing test output
  - The corrupted data — actual SQL result rows, not a description of them
  - Logs, metrics, trace, or `EXPLAIN ANALYZE` where relevant
- Save everything to `content/topics/<nn>-<slug>/evidence/`.
- Write the raw numbers into `NOTES.md`. Numbers you actually observed, nothing rounded up.

**If it doesn't fail:** stop. Do not tune the test until it breaks. Tell me — either the
reproduction is wrong or the naive version is accidentally safe, and both are interesting.

> ### 🚦 GATE 2 — evidence captured and saved. Nothing is fixed until I've seen it.

---

## Phase 3 — Fix it

**Goal:** the smallest correct change.

- Minimal diff. The reader has to see the fix in one screenshot, so touch as few lines as
  possible. If the fix exceeds ~40 lines, propose splitting the topic.
- The Phase 2 test now passes **without being modified.** If you changed the test to make it
  pass, you didn't fix anything — flag it.
- Branch: `topic/<nn>-<slug>/after`.
- Quantify the cost: run the benchmark, measure the write slowdown, count the extra rows.
  If you can't measure it, say "not measured" rather than estimating.

> ### 🚦 GATE 3 — I review the fix and the measured trade-off.

---

## Phase 4 — Harden

**Goal:** make it production-real, not just post-real.

Hand to the `adversary` agent. It attacks the fix for:
- races the fix didn't consider · ordering assumptions · partial failure and retry paths ·
  cross-tenant leakage · unbounded growth · error paths that swallow money

Then: tests to cover what it found, `docs/testing.md` standards, update the domain doc if
an invariant changed.

Anything the adversary finds that's *too good to waste* gets logged in `NOTES.md` as a
candidate for a future topic — don't fix scope-creep findings now, record them.

> ### 🚦 GATE 4 — I approve before we close the topic.

---

## Phase 5 — Capture for content

**Goal:** everything the post needs, so I never have to reconstruct it later.

- Fill in `content/topics/<nn>-<slug>/NOTES.md` completely (template in
  `content/topics/_TEMPLATE/`).
- List **exactly which files and line ranges I should screenshot**, for both before and
  after, and in what order.
- Flag anything visually messy — long lines, deep nesting, imports in the way — and offer to
  restructure *for readability only*, without changing behaviour.
- Update the **Current state** section in `CLAUDE.md`.
- One paragraph: what surprised you during this topic. That paragraph is usually the post's
  best hook.

---

## Rules that apply across all phases

- **Never skip a phase, never merge two.** Especially not 1 and 3 — building the fix while
  building the naive version is the single most common way this workflow fails.
- **Never fix a flaw you notice in passing.** If you spot a bug from a future topic, note it
  in `NOTES.md` under "spotted early" and leave it alone. That bug is a future post.
- **Branches:** `topic/<nn>-<slug>/before` → `/after` → merge to `main`. The `before` branch
  is never deleted; the post depends on it existing.
- **If we're mid-topic and I ask for something unrelated,** say which phase we're parked at
  before switching, so we can resume cleanly.
