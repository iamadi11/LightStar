# Autonomous Company — Architecture & Research

Date: 2026-09-21  
Repo: LightStar (`iamadi11/LightStar`)  
Status: Foundation decision record

## 0. Investigation findings

### Product & stack (verified)

| Fact | Evidence |
|------|----------|
| Native Swift 6 macOS/iOS LED controller for **BC/55** BLE | `README.md`, `agents.md` |
| Shared package `LightStarCore`; apps `LightStar`, `LightStariOS` | repo layout |
| CI: macOS-15, xcodegen, `swift test`, unsigned builds | `.github/workflows/ci.yml` |
| Strong evidence discipline already exists | `engineering-*.md`, `docs/validation/*` |
| AI knowledge base | `agents.md` (not CLAUDE.md) |
| No in-repo Cursor/Claude skills before this work | glob for `SKILL.md` → none |
| No Matt Pocock skills present | no `.agents/`, no `skills/` from mattpocock |
| This Cloud Agent VM has Python/Node, **no Swift/Xcode** | `which swift` fails |

### Existing workflow (do not replace)

1. Humans/agents edit Swift + docs.
2. Push to `main` (owner preference) or PR.
3. GitHub Actions validates on macOS.
4. Hardware BLE / iPhone / Accessibility validation is **manual / unavailable** on Linux agents.

### Matt Pocock skills (researched, not blindly copied)

Official source: https://github.com/mattpocock/skills (MIT).

Install options (2026 docs):

- Claude Code plugin: `claude plugins install mattpocock-skills`
- Editable copy: `npx skills@latest add mattpocock/skills` (include `setup-matt-pocock-skills`)

**Decision:** Do **not** vendor the entire mattpocock skill set into this repo in v1.

Reasons:

- Would duplicate dozens of skills unrelated to LightStar’s SDLC autonomy goal.
- Owner preference is a **single** autonomous-company command, not a skill menu.
- LightStar already has stricter product evidence conventions than generic “grill-me” flows.

**Reuse selectively (conventions, not file dumps):**

- Domain glossary → `company/memory/CONTEXT.md` (compatible with grill-with-docs spirit).
- ADRs under `company/adr/`.
- Composable discipline pointers: prefer `/tdd`, `/code-review`, `/diagnosing-bugs` **when those skills are installed by the operator**.
- Document optional install path in `company/memory/tooling.md`.

## 1. Problem statement

We need a **repository-level autonomous engineering company** that:

- Starts with **one command**.
- Discovers, prioritizes, executes, validates, and remembers work.
- Prefers **valuable software** over task volume.
- Honors LightStar’s stack, CI, and safety boundaries.
- Resumes from durable state.

## 2. Orchestration alternatives

### Option A — Conversational mega-loop

Ask an LLM for tasks → code → “test” → repeat.

| Pros | Cons |
|------|------|
| Fast to demo | No durable state; duplicates work; invents tasks; weak gates |

**Reject.** Explicitly insufficient per requirements.

### Option B — Durable state machine + Cursor skill + lean role cards (selected)

```
./scripts/autonomous-company   OR   /autonomous-company (Cursor skill)
                 │
                 ▼
     company/state/*.json  (durable)
                 │
     ┌───────────┼───────────┐
     ▼           ▼           ▼
  discovery  prioritizer  execution controller
     │           │           │
     └──── structured artifacts ────┘
                 │
        specialized role cards
        (strategy, PM, eng, review, QA, security, research, debt)
```

| Pros | Cons |
|------|------|
| Fits Cursor Cloud Agents | Does not magically spawn unlimited parallel agents without host support |
| Resumable JSON state | Swift validation must be delegated to CI/macOS |
| Integrates existing `engineering-*` evidence | Operator must still grant permissions for high-impact actions |
| No heavy third-party orchestrator | |

**Select for v1.**

### Option C — External multi-agent framework (LangGraph/CrewAI/etc.)

| Pros | Cons |
|------|------|
| Mature graphs | Extra deps; poor fit for Swift/Xcode; reinvents Cursor agent tooling |

**Reject for v1.** Revisit only with measured need.

## 3. Organization (justified roles)

Fewer agents than the max list. Each maps to a role card under `company/agents/`.

| Role | Why required for LightStar |
|------|----------------------------|
| Controller | Single execution owner; prevents multi-writer chaos |
| Strategy | Keeps BLE/product mission; rejects busywork |
| Product | Opportunities vs PD-001/PD-002 constraints |
| End-user | Journey critique without inventing customers |
| Architect | Protects LightStarCore seams / BLE protocol |
| Engineering | Implements against tickets |
| Review | Independent diff review |
| QA | Defines gates using **actual** repo commands |
| Security | Pairing/LAN/Alexa bridge surface |
| Research | Optional; tech adoption with citations |
| Debt | Evidence-backed debt only |

UX/Design is folded into End-user + Product for this native SwiftUI app (no separate web design system). Platform/DB/ML roles omitted — not in stack.

## 4. Single command

| Interface | Command |
|-----------|---------|
| Shell | `./scripts/autonomous-company` |
| Cursor skill | `/autonomous-company` |

Both load `company/config.yaml`, resume `company/state/runtime.json`, and refuse to invent work when none is justified.

## 5. Safety policy (non-negotiable)

- No weakening of validation to raise “completion rate”.
- No secret exfiltration; no `.env` commits.
- No claiming Swift/Xcode results on Linux.
- No destructive git history rewrites.
- High-impact actions (release notarize, entitlement changes, pairing-default flips) require `policy.allow_high_impact: true` **and** explicit human confirmation artifact.
- Product decisions PD-001 / PD-002 are locked unless Strategy records an ADR reversing them with evidence.

## 6. Incremental delivery plan

1. **Foundation** (this change): research doc, config, state schemas, CLI, Cursor skill, role cards, memory seed, unit tests for CLI.
2. **Discovery**: evidence scanners over `engineering-*`, CI, TODO/FIXME, docs gaps.
3. **Execution packs**: work-order schema + gates tied to CI commands.
4. **Self-improvement**: proposals under `company/improvements/` with rollback.
5. **Audit report**: honest limitations.

## 7. Non-goals (v1)

- Replacing GitHub Actions.
- Running full macOS UI tests on Linux Cloud Agents.
- Vendoring all Matt Pocock skills.
- Claiming unrestricted autonomous production deploy.

## 8. Sources

- Repo files cited above (2026-09-21).
- https://github.com/mattpocock/skills README (fetched 2026-09-21).
- https://skills.sh/mattpocock/skills (installer docs via search snippets 2026-09-21).
