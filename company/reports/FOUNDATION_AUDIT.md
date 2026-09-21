# Autonomous Company — Foundation Audit Report

Date: 2026-09-21  
Command: `./scripts/autonomous-company`

## What was implemented

- Architecture + research ADR comparing orchestration options (`company/adr/0001-…`)
- Durable config, schemas, memory, role cards
- Single CLI entry `./scripts/autonomous-company`
- Cursor skill `/autonomous-company` (`.cursor/skills/autonomous-company/SKILL.md`)
- Unit tests for discovery/prioritization honesty gates
- Explicit refusal to invent Swift validation on Linux

## Architecture overview

Durable JSON state + lean role cards + Cursor skill. Rejected mega-prompt loops and heavy external multi-agent frameworks for v1.

## Single-command usage

```bash
chmod +x ./scripts/autonomous-company
./scripts/autonomous-company init
./scripts/autonomous-company cycle
./scripts/autonomous-company status
./scripts/autonomous-company self-test
```

In Cursor: `/autonomous-company`

## Supported capabilities (v1)

| Capability | Status |
|------------|--------|
| Init / resume durable state | Implemented |
| Evidence-oriented discovery | Implemented (docs, TODO scan, Alexa/CI honesty) |
| Prioritization with rationale | Implemented (non-authoritative rank_score) |
| Reject/defer low-value work | Implemented |
| Auto-run company self-tests | Implemented |
| Full Swift implement→CI loop | Partial — requires macOS CI / Mac host |
| Matt Pocock skills vendored | Not vendored; optional install documented |
| Unrestricted production deploy | **Not claimed** |

## Agent responsibilities

See `company/agents/*.md` (controller, strategy, product, end-user, architect, engineering, review, QA, security, research, debt).

## Validation performed

- `python3 -m unittest discover -s company/tests -v` (run during foundation delivery)
- `./scripts/autonomous-company cycle` smoke (run during foundation delivery)
- Swift/Xcode: **not executed** on Linux agent (environment limitation)

## Known limitations

1. CLI auto-executors only cover safe process tasks; product code still needs the Cursor skill / human-supervised agent.
2. Echo Dot / BLE hardware validation not available here.
3. SSDP/Hue behaviour of Alexa bridge not runtime-tested on this host.
4. No parallel multi-agent runtime scheduler beyond role cards + work orders.

## Security / operational risks

- Alexa Hue emulator expands LAN attack surface when enabled (existing feature); company loop must not enable `allow_high_impact` casually.
- Durable state under `company/state/` may contain environment facts — do not put secrets there.

## Remaining work

- Wire richer discovery (CI status via `gh`, failing tests corpus).
- Agent execution packs that update work orders after real diffs.
- Self-improvement proposals with rollback once cycles produce failure patterns.
- Optional operator install of Matt Pocock skills for TDD/review discipline.

## Verdict

Foundation is **real and runnable**, not a toy prompt dump. It is **not** a fully autonomous software company that can ship Swift features unattended on Linux. That limitation is intentional and documented.
