"""Multi-perspective deliberation — significant proposals are not single-agent truth."""

from __future__ import annotations

from typing import Any

from company.os.paths import utc_now


def deliberate(item: dict[str, Any], memory: dict[str, Any]) -> dict[str, Any]:
    """Structured mini-board. Returns decision record."""
    title = (item.get("title") or "").lower()
    typ = item.get("type", "")
    evidence = item.get("evidence") or []

    perspectives = {
        "product": _product_view(title, typ),
        "engineering": _engineering_view(title, typ, evidence),
        "security": _security_view(title, typ),
        "architecture": _architecture_view(title, typ),
        "user": _user_view(title, typ),
    }

    votes_adopt = sum(1 for p in perspectives.values() if p["vote"] == "adopt")
    votes_reject = sum(1 for p in perspectives.values() if p["vote"] == "reject")
    votes_monitor = sum(1 for p in perspectives.values() if p["vote"] == "monitor")

    if votes_reject >= 2:
        decision = "reject"
        confidence = 0.7
        reasoning = "Multiple perspectives rejected; record and do not auto-execute"
    elif votes_adopt >= 3 and evidence:
        decision = "adopt"
        confidence = 0.75
        reasoning = "Broad support with evidence — proceed to triage"
    else:
        decision = "monitor"
        confidence = 0.55
        reasoning = "Insufficient consensus — keep as research/monitor, not forced READY"

    # Locked PD checks
    if any(k in title for k in ("tls by default", "pairing on by default", "requirepairing=true")):
        decision = "reject"
        confidence = 0.95
        reasoning = "Conflicts with locked PD-001 without ADR"

    record = {
        "at": utc_now(),
        "work_title": item.get("title"),
        "perspectives": perspectives,
        "decision": decision,
        "reasoning": reasoning,
        "confidence": confidence,
        "alternatives": ["adopt", "reject", "monitor"],
        "risks": item.get("risks", []),
    }
    memory.setdefault("decisions", []).append(
        {
            "at": utc_now(),
            "decision": f"deliberation:{decision}",
            "rationale": reasoning,
            "confidence": confidence,
        }
    )
    memory["decisions"] = memory["decisions"][-200:]
    return record


def _product_view(title: str, typ: str) -> dict[str, str]:
    if typ in {"docs", "process"}:
        return {"vote": "adopt", "note": "Low blast radius; improves honesty"}
    if "rewrite" in title or "migrate" in title:
        return {"vote": "monitor", "note": "Migration needs measured bottleneck"}
    return {"vote": "adopt", "note": "Default product lean-in if evidenced"}


def _engineering_view(title: str, typ: str, evidence: list) -> dict[str, str]:
    if not evidence:
        return {"vote": "reject", "note": "No evidence"}
    if "todo" in title or "fixme" in title:
        return {"vote": "monitor", "note": "Markers need triage capacity"}
    return {"vote": "adopt", "note": "Actionable with evidence"}


def _security_view(title: str, typ: str) -> dict[str, str]:
    if typ == "security":
        if "tls" in title and "default" in title:
            return {"vote": "reject", "note": "PD-001 lock"}
        return {"vote": "adopt", "note": "Security surface deserves attention"}
    return {"vote": "monitor", "note": "No direct security claim"}


def _architecture_view(title: str, typ: str) -> dict[str, str]:
    if "split lightblemanager" in title or "god object" in title:
        return {"vote": "reject", "note": "Prior architecture rejection stands"}
    if typ == "architecture":
        return {"vote": "adopt", "note": "Architecture docs/ADRs are cheap and durable"}
    return {"vote": "monitor", "note": "No architectural change required"}


def _user_view(title: str, typ: str) -> dict[str, str]:
    if typ in {"docs", "test", "process"}:
        return {"vote": "adopt", "note": "Improves trust/validation without UX churn"}
    if "fake customer" in title:
        return {"vote": "reject", "note": "No invented customers"}
    return {"vote": "monitor", "note": "Need journey evidence"}
