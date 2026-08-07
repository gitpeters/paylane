# Paylane repo scaffold — setup

Drop these into the root of your new Paylane repo:

```
paylane/
├── CLAUDE.md
├── docs/
│   ├── topic-workflow.md        ← the heart of it: 6 phases, 5 gates
│   ├── conventions.md
│   ├── architecture.md
│   ├── domain-model.md
│   ├── testing.md
│   ├── content-capture.md
│   ├── new-domain-checklist.md
│   └── domain/paylane.md
├── .claude/
│   ├── agents/{architect,backend,qa,adversary}.md
│   └── commands/{topic-start,capture-evidence,topic-close}.md
└── content/topics/_TEMPLATE/NOTES.md
```

Then:

1. `git init`, commit the scaffold before any code.
2. Add to `.gitignore`: `.env`, `*.log`, `content/**/evidence/*.png` if they get large.
3. Open in IntelliJ, start Claude Code, run `/topic-start 01 why-system-design-matters`.

## Why CLAUDE.md is short

Your current setup has one large CLAUDE.md holding everything, and it's grown unwieldy.
This scaffold splits it: CLAUDE.md is a ~120-line router that's always in context, and the
detail lives in `docs/`, loaded only when a task needs it. Conventions get read when writing
Java; the domain doc gets read when touching money; neither burns context the rest of the time.

Keep CLAUDE.md under ~150 lines permanently. When you're tempted to add to it, add to a
`docs/` file and add a row to the pointer table instead.

## The one thing that matters most

The boxed rule at the top of CLAUDE.md — *build the broken version first, and do not
improve it* — is the reason this scaffold exists. Coding agents will silently add the
idempotency check, the lock, the timeout. That instinct is correct everywhere except here,
where it destroys the evidence the post depends on. That rule is repeated in CLAUDE.md,
in topic-workflow.md, and in the backend agent, deliberately.
