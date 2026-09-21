---
name: autonomous-company
description: Start the LightStar autonomous software company OS — durable work pool, workers, continuous discovery, and multi-tick operation. Use when the user invokes /autonomous-company or asks to run the autonomous company.
---
# Autonomous Company (Company OS)

This skill is the **Cursor entry point** for LightStar’s **Company Operating System** — a living engineering organization, **not** a one-task coding loop.

## One command

```bash
./scripts/autonomous-company          # start / resume the company (default)
./scripts/autonomous-company status   # dashboard
./scripts/autonomous-company tick     # single clock tick
./scripts/autonomous-company stop     # pause; state persists
./scripts/autonomous-company self-test
```

Default `start` runs multiple company-clock ticks until **IDLE_MONITORING** or tick budget.

## Mental model

```
ONE COMMAND → Company Clock → Work Pool + Workers + Memory
     → discover / triage / claim / execute / consequences / reprioritize
     → continue until idle (not until one task finishes)
```

Architecture: `company/adr/0002-company-operating-system.md`

## Before product code changes

1. Read `company/memory/CONTEXT.md` and `agents.md`.
2. Read ADR 0001 (safety) + ADR 0002 (OS).
3. Run `./scripts/autonomous-company status`.
4. Pull READY work from the pool (do not invent a side quest).

## When the OS blocks for LLM work

If status shows `BLOCKED` with “Requires Cursor agent”:

1. Claim context from `company/state/work_pool.json`.
2. Execute per role card under `company/agents/`.
3. Record `completion_evidence` (commands, diffs, CI links).
4. Mark work COMPLETED (or leave evidence for `tick` to reconcile).
5. Run `./scripts/autonomous-company tick` so consequences + rediscovery continue.

**Do not stop after one implementation.** Return to the company clock.

## Anti-slop gate

Before implementing: problem, evidence, why this, what breaks, verify how, reject if.

## Safety

- Do not weaken tests to raise completion.
- Do not flip PD-001 / PD-002 without ADR.
- Do not claim Swift/Xcode results without running them (or CI evidence).
- Do not invent customers, metrics, or research.
- High-impact actions need `policy.allow_high_impact: true` **and** human confirmation in `company/state/`.

## Matt Pocock skills

Optional **worker capabilities** (`/tdd`, `/code-review`, `/diagnosing-bugs`) — never the orchestrator. See `company/memory/tooling.md`.

## Durable state

- `company/state/company.json` — mode, cycle
- `company/state/work_pool.json` — work universe
- `company/state/workers.json` — claims / leases
- `company/state/memory.json` — decisions / rejects / learnings
- `company/reports/tick-*.json` — tick audits
