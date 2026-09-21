---
name: autonomous-company-product-gap
description: Diagnoses why LightStar /autonomous-company idles on ops/docs instead of shipping product improvements and features, and remediates discovery/triage/skill handoff so Selected roadmap work becomes READY. Use when the company enters IDLE_MONITORING with no product READY work, when the user asks why autonomous-company is not improving the product or implementing features, or when fixing Company OS discovery toward engineering delivery.
---

# Why `/autonomous-company` is not shipping product

The Company OS is working **as coded** — it is **not** a product-delivery loop yet. It optimizes for honesty and anti-slop, then idles. That is the bug relative to “improve LightStar / ship features.”

## Quick diagnosis (run these)

```bash
./scripts/autonomous-company status
./scripts/autonomous-company self-test
```

If status shows `ONLY_SPECULATIVE_OR_DEFERRED` / `IDLE_MONITORING` with **Ready: 0** and work titled self-tests / Alexa CI / M12 / “deferred engineering” — you hit the product gap.

## Root causes (structural)

| # | Failure | Where | Effect |
|---|---------|-------|--------|
| 1 | Discovery never proposes **Selected** roadmap work | `company/os/discovery.py` → `discover_engineering` only reacts to “Deferred” / “Follow-up” and creates a *review* item | EE-00x implementables never become READY |
| 2 | Skill forbids side quests | `.cursor/skills/autonomous-company/SKILL.md` “Pull READY… do not invent” | Agent stops when pool is empty of product READY |
| 3 | Executors are ops-only | `company/os/executors.py` | Auto-complete = self-tests / CI deferral / ADR existence — no Swift feature path |
| 4 | LLM handoff only for blocked docs | Executor → `BLOCKED` “Requires Cursor agent” mainly on security docs | Feature work never reaches Cursor |
| 5 | Triage parks low-confidence debt | `company/os/triage.py` + debt/customer scanners | TODOs / unchecked M12 stay DEFERRED forever |
| 6 | Linux honesty without a delivery bridge | CONTEXT.md + Alexa QA discovery | “Confirm on CI” and hardware gates crowd out *implement then prove on CI* |
| 7 | Strategy focus is reliability locks | `company/state/memory.json` goals | Prefer evidence/PD locks over feature throughput |

**Not the cause:** “Agent forgot to code.” The clock correctly refuses invented demand; discovery simply never feeds real Selected engineering.

Evidence snapshot: `engineering-roadmap.md` has a **Selected (implement this pass)** table (EE-001…), while discovery only emits “Review deferred engineering items…”.

## Anti-slop still applies

Do **not** invent customers, metrics, or TLS/pairing defaults (PD-001/PD-002).  
Do **not** mass-implement Deferred rows that lack measurements.  
**Do** treat **Selected** roadmap rows (and explicit ADRs / failing product tests) as evidence-backed product work.

## Remediation workflow (Cursor agent)

Copy and track:

```
Product-gap Progress:
- [ ] 1. Confirm gap via status + pool titles
- [ ] 2. Fix discovery to emit Selected EE items as DISCOVERED
- [ ] 3. Ensure triage marks Selected implementables READY (not deferred review)
- [ ] 4. Executor or skill handoff: BLOCKED “Requires Cursor agent” for Swift EE work
- [ ] 5. Implement one READY EE item per engineering role card
- [ ] 6. Evidence: company tests locally; Swift → CI link (never fake xcodebuild on Linux)
- [ ] 7. Mark COMPLETED + ./scripts/autonomous-company tick
- [ ] 8. Repeat until Selected queue empty or tick budget — then idle honestly
```

### 1) Fix discovery (required)

In `discover_engineering`, parse `engineering-roadmap.md` **Selected** table rows (`EE-xxx`). For each ID not already COMPLETED/IN_PROGRESS in the pool:

- `department`: `engineering`
- `type`: `feature` or `fix` (from title)
- `confidence`: ≥ 0.8
- `evidence`: `[{kind: doc, ref: engineering-roadmap.md, note: EE-xxx Selected}]`
- `title`: include EE id + roadmap title (stable fingerprint per EE id)
- `acceptance`: from roadmap “Why” + “unit tests / CI” validation strategy

Keep a separate, lower-confidence item for Deferred *review* only when new measurements exist.

### 2) Skill handoff when READY is engineering

When pool has READY `department=engineering` / EE-* work:

1. Claim the highest-confidence READY item.
2. Follow `company/agents/engineering.md` + `agents.md`.
3. Implement the focused diff; do not widen scope.
4. Record `completion_evidence` (commands, paths, CI URL when available).
5. `./scripts/autonomous-company tick` — do not exit after one EE.

### 3) Linux validation bridge

- Company OS / Python: run `./scripts/autonomous-company self-test`.
- Swift: push and cite GitHub Actions macos-15; if CI is billing-blocked, keep product item IN_PROGRESS or BLOCKED on CI — do not mark COMPLETED without evidence, and do not invent greens.

### 4) Update `/autonomous-company` behavior when idle

If `start` would idle with Ready: 0 but Selected EE rows remain unimplemented:

- Load **this** skill and remediate discovery/pool first.
- Only then enter IDLE_MONITORING.

## Reject if

- Promoting Deferred rows without new measurements
- Flipping PD-001 / PD-002 without ADR
- “Implement something” with no roadmap/ADR/failing-test evidence
- Claiming Swift success from Linux without CI

## Additional resources

- Structural map and examples: [reference.md](reference.md)
- OS ADR: `company/adr/0002-company-operating-system.md`
- Roadmap source of truth: `engineering-roadmap.md`
