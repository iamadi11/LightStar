# Company OS Upgrade Audit

Date: 2026-09-21

## What changed

Replaced v1 one-shot Controller cycle with a **Company Operating System**:

| Component | Path |
|-----------|------|
| ADR | `company/adr/0002-company-operating-system.md` |
| Clock | `company/os/clock.py` |
| Work pool | `company/os/pool.py` + `company/state/work_pool.json` |
| Workers / claims | `company/os/workers.py` |
| Discovery departments | `company/os/discovery.py` |
| Triage | `company/os/triage.py` |
| Consequences | `company/os/consequences.py` |
| Deliberation | `company/os/deliberation.py` |
| Product feedback | `company/os/feedback.py` |
| Memory / cadence / dashboard | `company/os/memory.py`, `cadence.py`, `dashboard.py` |
| CLI | `./scripts/autonomous-company start\|status\|tick\|stop` |
| Skill | `.cursor/skills/autonomous-company/SKILL.md` |

## Behavioral proof

- Unit tests: 14/14 OK (`company/tests`)
- Multi-cycle: start → discover/claim/complete → continue → idle (isolated state)
- Adversarial: claim conflict, stale lease recovery, zero-value idle, PD-001 reject
- Live `./scripts/autonomous-company start --ticks 6` → **IDLE_MONITORING** when only speculative/deferred work remains (does not invent busywork)
- Hard caps: `hard_max_ticks`, idle streak, no per-tick report flood (gitignore `tick-20*.json`)

## Honest limitations

- Python OS cannot spawn Cursor LLM subagents; BLOCKED items needing product code await Cursor skill handoff while the clock keeps running.
- Linux host cannot prove Swift/Xcode; CI / deferred_to_ci remains.
- Matt Pocock skills remain optional worker capabilities, not the orchestrator.

## Self-critique

Compared to a small software company: there is now a durable work pool, concurrent claims, departmental discovery, consequences after completion, and idle-when-empty. It is **not** “one LLM task then stop.” Remaining gap: rich LLM engineering workers still attach via Cursor when auto-executors cannot implement Swift safely.
