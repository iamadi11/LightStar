"""Company status dashboard (observability)."""

from __future__ import annotations

from typing import Any

from company.os import pool as work_pool
from company.os import workers as worker_mod
from company.os.memory import load_memory
from company.os.paths import STATE, read_json
from company.os.triage import value_class


def load_company() -> dict[str, Any]:
    return read_json(
        STATE / "company.json",
        {
            "version": 1,
            "mode": "STOPPED",
            "cycle": 0,
            "stop_reason": None,
        },
    )


def render_status() -> str:
    company = load_company()
    pool = work_pool.load_pool()
    workers = worker_mod.load_workers()
    memory = load_memory()
    counts = work_pool.count_by_status(pool)
    wc = worker_mod.worker_counts(workers)
    vc = value_class(pool)

    focus = memory.get("strategy_focus", [])
    recent_decisions = memory.get("decisions", [])[-5:]
    recent_rejects = memory.get("rejects", [])[-5:]

    lines = [
        "COMPANY STATUS",
        "─────────────────────────",
        f"Mode: {company.get('mode', '?')}",
        f"Cycle: #{company.get('cycle', 0)}",
        f"Value class: {vc}",
        f"Stop reason: {company.get('stop_reason') or '—'}",
        "Workers:",
        f"  Active: {wc.get('ACTIVE', 0)}",
        f"  Idle: {wc.get('IDLE', 0)}",
        f"  Blocked: {wc.get('BLOCKED', 0)}",
        "Work Pool:",
        f"  Ready: {counts.get('READY', 0)}",
        f"  In Progress: {counts.get('IN_PROGRESS', 0) + counts.get('CLAIMED', 0)}",
        f"  Review: {counts.get('REVIEW', 0)}",
        f"  Blocked: {counts.get('BLOCKED', 0)}",
        f"  Completed: {counts.get('COMPLETED', 0)}",
        f"  Deferred: {counts.get('DEFERRED', 0)}",
        f"  Rejected: {counts.get('REJECTED', 0)}",
        "Strategic Goals:",
    ]
    for i, g in enumerate(focus[:5], 1):
        lines.append(f"  {i}. {g}")
    lines.append("Recent Decisions:")
    if not recent_decisions:
        lines.append("  —")
    for d in recent_decisions:
        lines.append(f"  - {d.get('decision')}: {d.get('rationale', '')[:80]}")
    lines.append("Recent Rejects:")
    if not recent_rejects:
        lines.append("  —")
    for r in recent_rejects:
        lines.append(f"  - {r.get('title', '')[:60]} ({r.get('reason', '')[:40]})")
    lines.append("In-flight:")
    inflight = [
        i
        for i in pool.get("items", [])
        if i.get("status") in {"CLAIMED", "IN_PROGRESS", "REVIEW", "VALIDATION"}
    ]
    if not inflight:
        lines.append("  —")
    for i in inflight[:8]:
        lines.append(f"  - {i.get('id')} [{i.get('status')}] {i.get('title', '')[:50]}")
    return "\n".join(lines)


def status_dict() -> dict[str, Any]:
    company = load_company()
    pool = work_pool.load_pool()
    workers = worker_mod.load_workers()
    return {
        "company": company,
        "value_class": value_class(pool),
        "work_counts": work_pool.count_by_status(pool),
        "worker_counts": worker_mod.worker_counts(workers),
        "items": pool.get("items", []),
        "workers": workers.get("workers", []),
    }
