# Company OS — work item schema (informational)

Work items live in `company/state/work_pool.json`.

## Statuses

DISCOVERED, PROPOSED, TRIAGED, READY, CLAIMED, IN_PROGRESS, BLOCKED,
REVIEW, VALIDATION, READY_TO_MERGE, COMPLETED, REJECTED, DEFERRED, ABANDONED

## Required fields

- id, title, status, department, type
- problem, evidence, desired_outcome
- priority_rationale, confidence
- acceptance, validation_requirements
- created_at, updated_at, fingerprint
- decision_history, completion_evidence

## Optional

- dependencies, risks, estimated_effort
- owner_worker, reviewer_worker, claim
- related_work, blocked_reason
