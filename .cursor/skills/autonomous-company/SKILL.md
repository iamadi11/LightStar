---
name: autonomous-company
description: Run the LightStar autonomous software company loop — discover, prioritize, execute, validate, and remember engineering work via durable company/ state. Use when the user invokes /autonomous-company or asks to run the autonomous company.
---
# Autonomous Company

This skill is the **Cursor entry point** for LightStar’s autonomous engineering company.

Prefer the shell command when available:

```bash
./scripts/autonomous-company          # one cycle (default)
./scripts/autonomous-company status
./scripts/autonomous-company init
./scripts/autonomous-company self-test
```

## Mission

Operate like a disciplined product engineering company for **this repository only**.

Value > task count. Evidence > assumptions. Honesty > greenwashing.

## Before any product code change

1. Read `company/memory/CONTEXT.md` and `agents.md`.
2. Read `company/adr/0001-autonomous-company-architecture.md`.
3. Run `./scripts/autonomous-company status` (or `init` then `cycle`).
4. Load the active work order from `company/state/work_orders/` if present.

## Cycle (when acting as Controller)

1. **Discover** — use CLI discovery + your inspection; do not invent demand.
2. **Prioritize** — explain rationale; challenge weak tasks.
3. **Decide** — accept, defer, reject, or conclude **NO ACTIONABLE HIGH-VALUE TASK IDENTIFIED**.
4. **Execute** — only accepted tasks; follow the matching role card in `company/agents/`.
5. **Validate** — run real commands; on Linux mark Swift gates `deferred_to_ci`.
6. **Review** — independent pass on the diff (Review role).
7. **Remember** — update `company/state/*`, write a short report under `company/reports/`.
8. **Stop** — when limits hit, blocked on permissions, or no valuable work remains.

## Anti-slop gate (required before implementation)

Answer explicitly in the work order or report:

- What problem are we solving?
- What evidence supports it?
- Why this implementation?
- What could break?
- How will we verify?
- What would make us reject this approach?

## Safety

- Do not weaken tests to increase completion.
- Do not flip PD-001 / PD-002 without ADR.
- Do not claim Swift/Xcode results without running them (or CI evidence).
- Do not modify company safety policy merely to go faster.
- High-impact actions require `policy.allow_high_impact: true` **and** a human confirmation note in `company/state/`.

## Optional companions

If Matt Pocock skills are installed in the environment, you may invoke `/tdd`, `/code-review`, or `/diagnosing-bugs` for discipline — they are **not** required for this skill to function. See `company/memory/tooling.md`.

## Outputs

Always leave durable artifacts:

- `company/state/runtime.json`
- `company/state/task_pool.json`
- `company/reports/cycle-*.json` (CLI) and/or a Markdown audit note when you performed agent execution
