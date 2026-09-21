"""Product feedback loop after completion — celebrate only with structure."""

from __future__ import annotations

from typing import Any

from company.os.paths import utc_now


def product_feedback(item: dict[str, Any]) -> dict[str, Any]:
    """BEFORE/AFTER/VALIDATION/FOLLOW-UP record for a completed item."""
    evidence = item.get("completion_evidence") or []
    has_evidence = bool(evidence)
    return {
        "at": utc_now(),
        "work_id": item.get("id"),
        "before": {
            "problem": item.get("problem") or item.get("title"),
            "believed_outcome": item.get("desired_outcome"),
        },
        "after": {
            "status": item.get("status"),
            "evidence_count": len(evidence),
        },
        "validation": {
            "has_completion_evidence": has_evidence,
            "acceptance": item.get("acceptance", []),
            "notes": "Evidence present" if has_evidence else "WARNING: completed without evidence",
        },
        "product_review": {
            "solves_stated_problem": has_evidence,
            "note": "Heuristic — Linux host cannot prove Swift runtime behavior",
        },
        "user_review": {
            "journey_improved": "unknown",
            "note": "No fabricated user feedback",
        },
        "engineering_review": {
            "complexity_added": item.get("type") not in {"process", "docs", "test"},
            "risks": item.get("risks", []),
        },
        "follow_up": {
            "related": item.get("related_work", []),
            "remaining": "See consequences pass for child work",
        },
        "summary": (
            f"{item.get('id')}: problem={str(item.get('problem') or '')[:60]} "
            f"evidence={len(evidence)} status={item.get('status')}"
        ),
    }
