# ADR 0002 — Company Operating System (true autonomy)

Date: 2026-09-21  
Status: Accepted  
Supersedes (behavior): ADR 0001 §2 Option B sequential “one cycle → stop” habit  
Preserves: PD-001/PD-002 locks, evidence gates, Linux honesty, Matt Pocock as worker capability

## 1. Limitations of v1 (ADR 0001 CLI)

| Limitation | Evidence in `scripts/company/cli.py` | Why it blocks autonomy |
|------------|--------------------------------------|-------------------------|
| Sequential Controller | `cmd_cycle`: discover → accept → execute → idle | Completing a task ends organizational life |
| No workers | Role cards are markdown only | No claim/pull concurrency |
| Thin task schema | `proposed/accepted/done/blocked` | No review/validation/claim/lease lifecycle |
| Discovery once per cycle | Fixed 3 scanners | No continuous departmental discovery |
| No consequences | Done tasks stay done forever | No follow-up work after completion |
| Title dedupe = death | Done titles never rediscovered | Pool freezes after first honest idle |
| Fake “multi-iteration” | Loop only re-runs same accept path | Not an org clock |
| Cursor skill = human loop | Skill lists 8 steps then Stop | User must re-invoke `/autonomous-company` |

**Verdict:** v1 is a disciplined **task runner**, not a company. Patching “continue” would fail the user’s §23 / §30 tests.

## 2. Selected architecture — Company OS

```
./scripts/autonomous-company start|run
            │
            ▼
     company/os/clock.py   ← Company Clock (durable)
            │
   ┌────────┼────────┬──────────┬────────────┐
   ▼        ▼        ▼          ▼            ▼
 recover  discover  triage   workers.pull  consequences
   │        │        │          │            │
   └────────┴────────┴──── work_pool ────────┘
                 │
          company/state/*
                 │
        departments (plugins)
```

### Durable artifacts

| File | Role |
|------|------|
| `company/state/company.json` | Mode, cycle, strategy focus, stop reason |
| `company/state/work_pool.json` | Full work universe (rich lifecycle) |
| `company/state/workers.json` | Worker registry, leases, specialization |
| `company/state/memory.json` | Decisions, rejects, failures, learnings |
| `company/state/cadence.json` | Last-run timestamps for periodic reviews |
| `company/state/task_pool.json` | **Legacy** — migrated once into work_pool |

### Work lifecycle

`DISCOVERED → PROPOSED → TRIAGED → READY → CLAIMED → IN_PROGRESS → REVIEW → VALIDATION → COMPLETED`  
(+ `BLOCKED`, `DEFERRED`, `REJECTED`, `ABANDONED`, `READY_TO_MERGE`)

### Workers

Logical workers (not LLM role-play): `qa`, `engineering`, `security`, `product`, `debt`, `research`, `architecture`, `review`, `ops`.  
They **claim** READY work with leases; stale leases return to READY (recovery).

### Company clock (one tick)

1. Recover stale claims / reconcile  
2. Departmental discovery (cadence-aware)  
3. Triage / reject low-value  
4. Assign claims to idle compatible workers  
5. Execute claimable auto-work (safe executors)  
6. Consequence pass on newly COMPLETED items → follow-ups  
7. Cadence reviews (debt / research / retrospective / self-improve)  
8. Persist + dashboard  
9. Decide: continue | idle | stop(reason)

**Task completion is an event inside the tick, not process exit.**

### Idle vs fake work

If triage finds no READY/high-value work and discovery yields only rejects/deferred → mode `IDLE_MONITORING`.  
No invented customers, metrics, or Swift greens on Linux.

## 3. Concurrency model (honest)

This host cannot spawn unlimited Cursor subagents from Python. The OS therefore:

- Supports **true concurrent claims** and parallel **safe executors** (ThreadPoolExecutor for process/tests).
- Exposes `pull` / `claim` / `complete` APIs for Cursor agents / future subagents.
- Never pretends one prompt is 20 employees.

Matt Pocock skills remain **worker capabilities** invoked by the Cursor skill when an ENGINEERING claim needs LLM implementation — not the orchestrator.

## 4. Migration

On first `start`/`run`, migrate legacy `task_pool.json` tasks into `work_pool.json` with mapped statuses (`done→COMPLETED`, `deferred→DEFERRED`, …). Keep legacy file for audit.

## 5. Non-goals (unchanged)

- Fake customer feedback / fabricated CI  
- Flipping PD-001/PD-002 without ADR  
- Vendoring all Matt Pocock skills  
- Claiming macOS validation on Linux  

## 6. Acceptance (behavioral)

Multi-cycle harness must show: discover → claim → complete → consequences/follow-ups → reprioritize → idle when empty; plus stale-claim recovery and dual-claim conflict refusal.
