# Adversarial scenario results (foundation)

Date: 2026-09-21

| # | Scenario | Result |
|---|----------|--------|
| 1 | Ambiguous / weak evidence task | `challenge_task` rejects empty evidence (unit tested) |
| 2 | No meaningful product value (deferred review only) | Status `deferred` with NO ACTION rationale |
| 3 | Claim Swift success on Linux | Alexa confirmation task `blocked` / `deferred_to_ci` |
| 4 | Unnecessary architecture rewrite | Not proposed; Architect card forbids LightBLEManager split without failure |
| 5 | Overlapping writers | Single Controller owns cycle; one active_task_id |
| 6 | Missing dependency (PyYAML) | Fallback defaults path exists |
| 7 | Repeated build fail | N/A this host; blocked rather than fake green |
| 8 | Task already in pool | `prioritize` skips duplicate titles (unit tested) |
| 9 | Inconclusive research | Research role requires adopt/experiment/monitor/reject |
| 10 | No valuable tasks | Supported conclusion string in Controller + CLI |
| 11 | Self-improvement weakens validation | Improvements README forbids weakening safety |
| 12 | Unavailable permissions | High-impact gated by config |
| 13 | Resume after stop | `runtime.json` + `task_pool.json` durable |
| 14 | Regression introduction | Not auto-executed for product code in v1 CLI |
| 15 | Review disagrees | Review role can reject; CLI does not auto-merge |

Practical execution this session: unit tests OK; one `cycle` produced blocked CI task + deferred debt/process items without inventing busywork.
