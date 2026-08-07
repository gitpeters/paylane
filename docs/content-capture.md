# Content Capture

The build exists to feed the series. Evidence that isn't captured at the moment it happens
is gone — you cannot reconstruct a failure convincingly after the fix is in.

**The rule: capture before you fix. Always.**

---

## Folder per topic

```
content/topics/03-idempotency-keys/
├── NOTES.md              ← the single source for writing the post
├── evidence/
│   ├── 01-test-failure.txt
│   ├── 02-duplicate-ledger-rows.txt      (actual SQL output)
│   ├── 03-logs-double-charge.txt
│   ├── 04-explain-analyze-before.txt
│   └── 05-grafana-latency.png
├── before/
│   └── screenshot-targets.md             ← file + line ranges to capture
└── after/
    └── screenshot-targets.md
```

## What counts as evidence

Ranked by how well it performs in a post:

1. **Actual data rows** — two ledger entries where there should be one. Nothing is more
   convincing than a `SELECT` result.
2. **A failing test with a clear assertion message** — "expected 2 but was 4".
3. **`EXPLAIN ANALYZE` output** — before and after, same query, real row counts.
4. **A metrics graph** — connection pool exhaustion, latency spike, queue depth climbing.
5. **A trace waterfall** — the one span consuming 90% of the request.
6. **Log lines** — weakest on its own; strong when paired with the data it produced.

Narration is not evidence. "The balance became incorrect" is worthless; the row showing
`available_minor = -45000` is the post.

## Capturing SQL output

Run in DBeaver, but save the **text** result too — text pastes into a code visual cleanly
and survives compression better than a screenshot of a grid.

```
-- Include the query in the capture file. The query is half the story.
SELECT id, direction, amount_minor, created_at
FROM ledger_entry WHERE transaction_id = '...';
```

Keep result sets to ≤ 6 rows and ≤ 5 columns. Select only the columns that prove the point —
a 14-column dump proves nothing at phone size.

## Code screenshots (IntelliJ)

Settings that make code readable after LinkedIn's compression:

- Darcula theme, JetBrains Mono, **font size 18–20**
- Window width ≤ 900px; no horizontal scroll in frame
- Distraction-free mode (`View → Appearance → Enter Distraction-Free Mode`)
- Hide line numbers unless the post refers to a specific line
- Crop out the IDE chrome unless the file path adds context
- Capture at 2× (Win+Shift+S then don't downscale; or IntelliJ's built-in screenshot)

Content limits per screenshot:
- **≤ 20 lines.** If the method is longer, capture the relevant block only.
- **≤ 100 chars per line.** Reformat for width if needed — this is the one time reformatting
  for aesthetics is allowed, and behaviour must not change.
- Remove unrelated imports and annotations from frame.
- The changed lines in the "after" shot should be visually obvious. Consider capturing the
  IntelliJ diff view (`Compare with Branch → topic/nn-slug/before`) instead of two shots.

## `screenshot-targets.md` format

Claude fills this in at Phase 5 so I'm not hunting for what to capture:

```markdown
## Slide 3 — "This looks fine"
File: src/main/java/com/paylane/charge/ChargeService.java
Lines: 34–52 (method `initiate`)
Note: fold the imports; the point is the missing idempotency check on line 38

## Slide 4 — "Here's what happens"
File: content/topics/03-.../evidence/02-duplicate-ledger-rows.txt
Note: paste as text into a code visual, don't screenshot DBeaver's grid
```

## Naming

`<order>-<what-it-shows>.<ext>` — `02-duplicate-ledger-rows.txt`, not `Screenshot_2026-08-05.png`.
Ordered by the sequence they'll appear in the carousel.

## Sanitising before capture

Every capture gets checked for: real API keys, real customer names, provider credentials,
internal URLs, your own email. Use obviously-fake merchants (`Acme Stores Ltd`,
`merchant_test_01`) from the start so this never becomes a problem.

## What Claude produces at Phase 5

1. `NOTES.md`, fully filled from the template
2. `before/screenshot-targets.md` and `after/screenshot-targets.md`
3. A flag on anything visually messy, with an offer to reformat for readability only
4. One paragraph: *what surprised you during this topic* — that's usually the post's hook
