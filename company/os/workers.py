"""Worker registry, claims, and leases."""

from __future__ import annotations

import threading
from datetime import datetime, timedelta, timezone
from typing import Any

from company.os import pool as work_pool
from company.os.paths import STATE, read_json, utc_now, write_json

WORKERS_PATH = STATE / "workers.json"
_lock = threading.RLock()

DEFAULT_WORKERS = [
    {"id": "ops-1", "role": "ops", "skills": ["process", "self-test"], "status": "IDLE"},
    {"id": "qa-1", "role": "qa", "skills": ["test", "validation"], "status": "IDLE"},
    {"id": "eng-1", "role": "engineering", "skills": ["implementation", "docs"], "status": "IDLE"},
    {"id": "sec-1", "role": "security", "skills": ["security", "docs"], "status": "IDLE"},
    {"id": "product-1", "role": "product", "skills": ["product", "ux"], "status": "IDLE"},
    {"id": "debt-1", "role": "debt", "skills": ["debt", "triage"], "status": "IDLE"},
    {"id": "research-1", "role": "research", "skills": ["research"], "status": "IDLE"},
    {"id": "arch-1", "role": "architecture", "skills": ["architecture"], "status": "IDLE"},
    {"id": "review-1", "role": "review", "skills": ["review"], "status": "IDLE"},
]

ROLE_COMPAT = {
    "ops": {"ops", "process", "qa"},
    "qa": {"qa", "test", "process", "ops"},
    "engineering": {"engineering", "bug", "docs", "process"},
    "security": {"security", "docs"},
    "product": {"product", "ux"},
    "debt": {"debt"},
    "research": {"research"},
    "architecture": {"architecture"},
    "review": {"review", "engineering", "docs", "security"},
}


def _empty() -> dict[str, Any]:
    workers = []
    for w in DEFAULT_WORKERS:
        workers.append(
            {
                **w,
                "current_work_id": None,
                "lease_expires_at": None,
                "last_heartbeat": utc_now(),
                "completed_count": 0,
            }
        )
    return {"version": 1, "workers": workers, "updated_at": utc_now()}


def load_workers() -> dict[str, Any]:
    with _lock:
        data = read_json(WORKERS_PATH, None)
        if data is None:
            data = _empty()
            write_json(WORKERS_PATH, data)
        return data


def save_workers(data: dict[str, Any]) -> None:
    with _lock:
        data["updated_at"] = utc_now()
        write_json(WORKERS_PATH, data)


def worker_counts(data: dict[str, Any]) -> dict[str, int]:
    counts = {"IDLE": 0, "ACTIVE": 0, "BLOCKED": 0}
    for w in data.get("workers", []):
        s = w.get("status", "IDLE")
        if s == "IDLE":
            counts["IDLE"] += 1
        elif s in {"CLAIMED", "IN_PROGRESS", "ACTIVE"}:
            counts["ACTIVE"] += 1
        elif s == "BLOCKED":
            counts["BLOCKED"] += 1
        else:
            counts.setdefault(s, 0)
            counts[s] = counts.get(s, 0) + 1
    return counts


def compatible(worker: dict[str, Any], item: dict[str, Any]) -> bool:
    role = worker.get("role", "")
    dept = item.get("department", "")
    typ = item.get("type", "")
    allowed = ROLE_COMPAT.get(role, set())
    return dept in allowed or typ in allowed or role == dept


def _parse_ts(ts: str | None) -> datetime | None:
    if not ts:
        return None
    try:
        return datetime.fromisoformat(ts.replace("Z", "+00:00"))
    except ValueError:
        return None


def recover_stale_claims(pool: dict[str, Any], workers: dict[str, Any], lease_seconds: int = 900) -> list[str]:
    """CLAIMED/IN_PROGRESS with expired lease → READY; worker → IDLE."""
    recovered: list[str] = []
    now = datetime.now(timezone.utc)
    by_id = {w["id"]: w for w in workers.get("workers", [])}
    for item in pool.get("items", []):
        if item.get("status") not in {"CLAIMED", "IN_PROGRESS"}:
            continue
        claim = item.get("claim") or {}
        expires = _parse_ts(claim.get("lease_expires_at"))
        if expires and expires < now:
            wid = claim.get("worker_id")
            item["status"] = "READY"
            item["claim"] = None
            item["owner_worker"] = None
            work_pool.append_decision(item, "lease_expired", "recovery", f"stale claim by {wid}")
            recovered.append(item["id"])
            if wid and wid in by_id:
                by_id[wid]["status"] = "IDLE"
                by_id[wid]["current_work_id"] = None
                by_id[wid]["lease_expires_at"] = None
    return recovered


def claim_work(
    pool: dict[str, Any],
    workers: dict[str, Any],
    work_id: str,
    worker_id: str,
    lease_seconds: int = 900,
) -> dict[str, Any]:
    """Atomically claim READY work. Raises ValueError on conflict."""
    with _lock:
        item = work_pool.get_item(pool, work_id)
        if not item:
            raise ValueError(f"unknown work {work_id}")
        if item.get("status") != "READY":
            raise ValueError(f"{work_id} not READY (status={item.get('status')})")
        if item.get("claim"):
            raise ValueError(f"{work_id} already claimed by {item['claim'].get('worker_id')}")

        worker = next((w for w in workers["workers"] if w["id"] == worker_id), None)
        if not worker:
            raise ValueError(f"unknown worker {worker_id}")
        if worker.get("status") not in {"IDLE", None}:
            raise ValueError(f"worker {worker_id} not IDLE")
        if not compatible(worker, item):
            raise ValueError(f"worker {worker_id} incompatible with {work_id}")

        # dependency gate
        for dep in item.get("dependencies", []):
            dep_item = work_pool.get_item(pool, dep)
            if dep_item and dep_item.get("status") != "COMPLETED":
                raise ValueError(f"{work_id} blocked on dependency {dep}")

        expires = (datetime.now(timezone.utc) + timedelta(seconds=lease_seconds)).replace(microsecond=0).isoformat()
        item["status"] = "CLAIMED"
        item["owner_worker"] = worker_id
        item["claim"] = {
            "worker_id": worker_id,
            "claimed_at": utc_now(),
            "lease_expires_at": expires,
        }
        work_pool.append_decision(item, "claimed", worker_id, "lease acquired")
        worker["status"] = "ACTIVE"
        worker["current_work_id"] = work_id
        worker["lease_expires_at"] = expires
        worker["last_heartbeat"] = utc_now()
        return item


def select_ready_for_worker(pool: dict[str, Any], worker: dict[str, Any]) -> dict[str, Any] | None:
    """Pick highest-confidence READY compatible item without dependency blockers."""
    candidates = []
    for item in pool.get("items", []):
        if item.get("status") != "READY":
            continue
        if not compatible(worker, item):
            continue
        blocked = False
        for dep in item.get("dependencies", []):
            dep_item = work_pool.get_item(pool, dep)
            if dep_item and dep_item.get("status") != "COMPLETED":
                blocked = True
                break
        if blocked:
            continue
        # Workers may refuse low-confidence speculative work
        if float(item.get("confidence", 0)) < 0.4:
            continue
        candidates.append(item)
    if not candidates:
        return None
    candidates.sort(key=lambda x: (-float(x.get("confidence", 0)), x.get("id", "")))
    return candidates[0]


def release_worker(workers: dict[str, Any], worker_id: str) -> None:
    for w in workers.get("workers", []):
        if w["id"] == worker_id:
            w["status"] = "IDLE"
            w["current_work_id"] = None
            w["lease_expires_at"] = None
            w["last_heartbeat"] = utc_now()
            return
