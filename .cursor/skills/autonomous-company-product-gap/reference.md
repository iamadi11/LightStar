# Product-gap reference

## Discovery path today

```
discover_engineering(roadmap)
  if "Deferred" or "Follow-up" in file:
      emit ONE item: "Review deferred engineering items…"
  # Selected table is ignored
```

Triage then defers any title containing `"deferred engineering"` → permanent DEFERRED memory, never EE implementation.

## What “product work” means here

LightStar product work is **Swift** changes in `LightStarCore/`, `LightStar/`, `LightStariOS/` that improve controller behavior (BLE, sync, remote, Alexa bridge UX, reliability fixes in Selected EE list).

It is **not**:

- Re-running company self-tests
- Re-confirming Alexa CI honesty on Linux
- Researching Matt Pocock skills
- Inventing new OEM-app parity features without roadmap/ADR evidence

## Selected vs Deferred (roadmap contract)

| Section | Company must |
|---------|----------------|
| **Selected** | Discover → READY → implement (or BLOCKED for Cursor) |
| **Follow-up** | Discover after Selected clears, or if dependent |
| **Deferred** | Leave until new measurements; do not promote casually |
| **Rejected** | Never rediscover as READY |

## Fingerprint guidance

Prefer titles like:

`EE-001: Gate pointer injection on authentication`

so each EE id has a stable fingerprint and can COMPLETE without blocking rediscovery of EE-002.

## Executor vs Cursor

| Work | Owner |
|------|--------|
| unittest company OS | auto executor |
| CI billing annotation | auto executor → BLOCKED external |
| EE Swift fix | Cursor agent (engineering card) |
| PD-001 flip | REJECTED without ADR |

## Idle is honest only when

1. Selected table empty **or** every Selected EE is COMPLETED/REJECTED with evidence, **and**
2. No READY/in-flight product work, **and**
3. Remaining items are truly Deferred/external (hardware, billing).

If Selected rows exist and pool Ready=0 → **product gap**, not success idle.
