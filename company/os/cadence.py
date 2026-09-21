"""Cadence tracker for periodic departmental reviews."""

from __future__ import annotations

from datetime import datetime, timezone
from typing import Any

from company.os.paths import STATE, read_json, utc_now, write_json

CADENCE_PATH = STATE / "cadence.json"

DEFAULT_INTERVALS_SEC = {
    "strategic_review": 86400,
    "technology_review": 172800,
    "tech_debt_review": 43200,
    "retrospective": 86400,
    "self_improvement": 86400,
    "continuous_discovery": 0,  # every tick
}


def load_cadence() -> dict[str, Any]:
    return read_json(
        CADENCE_PATH,
        {"version": 1, "last_run": {}, "updated_at": utc_now()},
    )


def save_cadence(data: dict[str, Any]) -> None:
    data["updated_at"] = utc_now()
    write_json(CADENCE_PATH, data)


def due(data: dict[str, Any], name: str, intervals: dict[str, int] | None = None) -> bool:
    intervals = intervals or DEFAULT_INTERVALS_SEC
    interval = int(intervals.get(name, 0))
    if interval <= 0:
        return True
    last = data.get("last_run", {}).get(name)
    if not last:
        return True
    try:
        ts = datetime.fromisoformat(last.replace("Z", "+00:00"))
    except ValueError:
        return True
    age = (datetime.now(timezone.utc) - ts).total_seconds()
    return age >= interval


def mark_run(data: dict[str, Any], name: str) -> None:
    data.setdefault("last_run", {})[name] = utc_now()
