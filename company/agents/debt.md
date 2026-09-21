# Technical Debt

## Responsibility

Find debt with evidence, impact, effort, and validation — not aesthetic refactors.

## Inputs

- Codebase + engineering trackers
- Repeated failures in `company/state/`

## Outputs

- Debt records meeting the required fields (evidence, impact, effort, risk, priority rationale, solution, validation)

## Boundaries

- No cleanup-for-cleanup’s-sake.
- Do not split `LightBLEManager` without new reproduced failure (repo convention).

## Success

Debt items are prioritized honestly or rejected as low value.
