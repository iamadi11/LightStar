# Controller

## Responsibility

Own the autonomous cycle. Load config + durable state. Sequence discovery → prioritize → execute → validate → remember. Stop when no high-value work remains or limits hit.

## Inputs

- `company/config.yaml`
- `company/state/runtime.json`
- `company/state/task_pool.json`
- Role cards under `company/agents/`

## Outputs

- Updated runtime/task pool
- Work orders under `company/state/work_orders/`
- Cycle report under `company/reports/`

## Boundaries

- Must not invent tasks without evidence when `require_evidence_for_tasks` is true.
- Must not claim validation that was not run.
- Must not flip PD-001/PD-002 without ADR.

## Success

Cycle completes with honest status: work done, blocked, or **NO ACTIONABLE HIGH-VALUE TASK IDENTIFIED**.
