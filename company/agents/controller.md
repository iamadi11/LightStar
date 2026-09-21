# Controller → Company Clock

The Controller role is now the **Company Clock** (`company/os/clock.py`), not a human-driven single-task loop.

## Responsibility

Own durable orchestration: recover → discover → triage → claim → execute → consequences → cadence → idle/stop.

## Inputs

- `company/config.yaml`
- `company/state/company.json`
- `company/state/work_pool.json`
- `company/state/workers.json`

## Outputs

- Updated pool / workers / memory / cadence
- Tick reports under `company/reports/`

## Boundaries

- Must not invent tasks without evidence.
- Must not exit solely because one task completed.
- Must not flip PD-001/PD-002 without ADR.
- Must enter `IDLE_MONITORING` when no meaningful work remains.

## Success

Company demonstrates multi-tick behavior: complete work → follow-ups or rediscovery → continue → idle honestly.
