"""Durable work pool — heart of the Company OS."""

from __future__ import annotations

import hashlib
import re
import threading
from copy import deepcopy
from typing import Any

from company.os.paths import STATE, read_json, utc_now, write_json

POOL_PATH = STATE / "work_pool.json"
LEGACY_POOL = STATE / "task_pool.json"

STATUSES = (
    "DISCOVERED",
    "PROPOSED",
    "TRIAGED",
    "READY",
    "CLAIMED",
    "IN_PROGRESS",
    "BLOCKED",
    "REVIEW",
    "VALIDATION",
    "READY_TO_MERGE",
    "COMPLETED",
    "REJECTED",
    "DEFERRED",
    "ABANDONED",
)

_LEGACY_MAP = {
    "proposed": "PROPOSED",
    "accepted": "READY",
    "in_progress": "IN_PROGRESS",
    "done": "COMPLETED",
    "blocked": "BLOCKED",
    "deferred": "DEFERRED",
    "rejected": "REJECTED",
}

_lock = threading.RLock()


def _empty_pool() -> dict[str, Any]:
    return {"version": 2, "items": [], "updated_at": utc_now()}


def load_pool() -> dict[str, Any]:
    with _lock:
        pool = read_json(POOL_PATH, None)
        if pool is None:
            pool = _migrate_legacy()
            write_json(POOL_PATH, pool)
        pool.setdefault("version", 2)
        pool.setdefault("items", [])
        return pool


def save_pool(pool: dict[str, Any]) -> None:
    with _lock:
        pool["updated_at"] = utc_now()
        write_json(POOL_PATH, pool)


def _migrate_legacy() -> dict[str, Any]:
    legacy = read_json(LEGACY_POOL, {"tasks": []})
    items = []
    for t in legacy.get("tasks", []):
        items.append(legacy_task_to_item(t))
    return {"version": 2, "items": items, "updated_at": utc_now(), "migrated_from": "task_pool.json"}


def legacy_task_to_item(t: dict[str, Any]) -> dict[str, Any]:
    status = _LEGACY_MAP.get(str(t.get("status", "proposed")).lower(), "PROPOSED")
    return {
        "id": t.get("id") or next_work_id([]),
        "title": t.get("title", "untitled"),
        "status": status,
        "department": _category_to_dept(t.get("category", "engineering")),
        "type": t.get("category", "process"),
        "problem": t.get("title", ""),
        "evidence": t.get("evidence", []),
        "desired_outcome": "; ".join(t.get("acceptance", [])),
        "priority_rationale": t.get("priority_rationale", ""),
        "confidence": 0.6,
        "dependencies": [],
        "risks": t.get("risks", []),
        "estimated_effort": "S",
        "owner_worker": None,
        "reviewer_worker": None,
        "claim": None,
        "related_work": [],
        "acceptance": t.get("acceptance", []),
        "validation_requirements": t.get("validation_plan", []),
        "decision_history": [],
        "completion_evidence": t.get("completion_evidence", []),
        "blocked_reason": t.get("blocked_reason"),
        "created_at": t.get("created_at", utc_now()),
        "updated_at": t.get("updated_at", utc_now()),
        "fingerprint": fingerprint_title(t.get("title", "")),
    }


def _category_to_dept(cat: str) -> str:
    return {
        "process": "ops",
        "test": "qa",
        "debt": "debt",
        "security": "security",
        "docs": "engineering",
        "bug": "engineering",
    }.get(cat, "engineering")


def fingerprint_title(title: str) -> str:
    norm = re.sub(r"\s+", " ", title.strip().lower())
    return hashlib.sha256(norm.encode()).hexdigest()[:16]


def next_work_id(items: list[dict[str, Any]]) -> str:
    nums = []
    for t in items:
        m = re.match(r"W-(\d+)$", t.get("id", ""))
        if m:
            nums.append(int(m.group(1)))
        m2 = re.match(r"T-(\d+)$", t.get("id", ""))
        if m2:
            nums.append(int(m2.group(1)))
    return f"W-{(max(nums) if nums else 0) + 1:04d}"


def find_by_fingerprint(items: list[dict[str, Any]], fp: str) -> dict[str, Any] | None:
    for it in items:
        if it.get("fingerprint") == fp:
            return it
    return None


def count_by_status(pool: dict[str, Any]) -> dict[str, int]:
    out: dict[str, int] = {}
    for it in pool.get("items", []):
        s = it.get("status", "?")
        out[s] = out.get(s, 0) + 1
    return out


def get_item(pool: dict[str, Any], work_id: str) -> dict[str, Any] | None:
    for it in pool.get("items", []):
        if it.get("id") == work_id:
            return it
    return None


def upsert_item(pool: dict[str, Any], item: dict[str, Any]) -> dict[str, Any]:
    items = pool.setdefault("items", [])
    for i, existing in enumerate(items):
        if existing.get("id") == item.get("id"):
            items[i] = item
            return item
    items.append(item)
    return item


def new_work_item(
    *,
    title: str,
    department: str,
    type_: str,
    problem: str,
    evidence: list[dict[str, str]],
    desired_outcome: str,
    priority_rationale: str,
    acceptance: list[str],
    confidence: float = 0.5,
    risks: list[str] | None = None,
    dependencies: list[str] | None = None,
    related_work: list[str] | None = None,
    estimated_effort: str = "M",
    status: str = "DISCOVERED",
    pool_items: list[dict[str, Any]] | None = None,
) -> dict[str, Any]:
    items = pool_items or []
    return {
        "id": next_work_id(items),
        "title": title,
        "status": status,
        "department": department,
        "type": type_,
        "problem": problem,
        "evidence": evidence,
        "desired_outcome": desired_outcome,
        "priority_rationale": priority_rationale,
        "confidence": confidence,
        "dependencies": dependencies or [],
        "risks": risks or [],
        "estimated_effort": estimated_effort,
        "owner_worker": None,
        "reviewer_worker": None,
        "claim": None,
        "related_work": related_work or [],
        "acceptance": acceptance,
        "validation_requirements": list(acceptance),
        "decision_history": [
            {"at": utc_now(), "event": "created", "by": department, "note": "discovered"}
        ],
        "completion_evidence": [],
        "blocked_reason": None,
        "created_at": utc_now(),
        "updated_at": utc_now(),
        "fingerprint": fingerprint_title(title),
    }


def append_decision(item: dict[str, Any], event: str, by: str, note: str) -> None:
    item.setdefault("decision_history", []).append(
        {"at": utc_now(), "event": event, "by": by, "note": note}
    )
    item["updated_at"] = utc_now()


def snapshot(pool: dict[str, Any]) -> dict[str, Any]:
    return deepcopy(pool)
