"""Company memory — decisions, rejects, failures, learnings."""

from __future__ import annotations

from typing import Any

from company.os.paths import STATE, read_json, utc_now, write_json

MEMORY_PATH = STATE / "memory.json"


def load_memory() -> dict[str, Any]:
    data = read_json(
        MEMORY_PATH,
        {
            "version": 1,
            "decisions": [],
            "rejects": [],
            "failures": [],
            "learnings": [],
            "strategy_focus": [
                "Keep BC/55 BLE controller reliable",
                "Honor PD-001 / PD-002",
                "Prefer evidence over task count",
            ],
            "updated_at": utc_now(),
        },
    )
    return data


def save_memory(data: dict[str, Any]) -> None:
    data["updated_at"] = utc_now()
    write_json(MEMORY_PATH, data)


def remember_decision(data: dict[str, Any], decision: str, rationale: str, confidence: float = 0.7) -> None:
    data.setdefault("decisions", []).append(
        {"at": utc_now(), "decision": decision, "rationale": rationale, "confidence": confidence}
    )
    # Cap growth
    data["decisions"] = data["decisions"][-200:]


def remember_reject(data: dict[str, Any], title: str, reason: str) -> None:
    data.setdefault("rejects", []).append({"at": utc_now(), "title": title, "reason": reason})
    data["rejects"] = data["rejects"][-200:]


def remember_failure(data: dict[str, Any], work_id: str, detail: str) -> None:
    data.setdefault("failures", []).append({"at": utc_now(), "work_id": work_id, "detail": detail})
    data["failures"] = data["failures"][-200:]


def remember_learning(data: dict[str, Any], learning: str) -> None:
    data.setdefault("learnings", []).append({"at": utc_now(), "learning": learning})
    data["learnings"] = data["learnings"][-100:]
