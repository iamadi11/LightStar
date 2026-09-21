"""Triage gate — discovery ≠ automatic READY work."""

from __future__ import annotations

from typing import Any

from company.os import pool as work_pool


def triage_item(item: dict[str, Any], cfg: dict[str, Any], pool: dict[str, Any]) -> dict[str, Any]:
    """Return item with updated status: READY | REJECTED | DEFERRED."""
    policy = cfg.get("policy", {})

    if policy.get("require_evidence_for_tasks", True) and not item.get("evidence"):
        item["status"] = "REJECTED"
        item["blocked_reason"] = "No evidence"
        work_pool.append_decision(item, "triage_reject", "triage", "missing evidence")
        return item

    # Duplicate fingerprint already terminal or active
    fp = item.get("fingerprint")
    for other in pool.get("items", []):
        if other.get("id") == item.get("id"):
            continue
        if other.get("fingerprint") == fp and other.get("status") not in {
            "REJECTED",
            "ABANDONED",
            "COMPLETED",
        }:
            item["status"] = "REJECTED"
            item["blocked_reason"] = f"Duplicate of {other.get('id')}"
            work_pool.append_decision(item, "triage_reject", "triage", item["blocked_reason"])
            return item

    title = (item.get("title") or "").lower()
    typ = item.get("type", "")
    dept = item.get("department", "")

    # Speculative / low confidence
    if float(item.get("confidence", 0)) < 0.45:
        item["status"] = "DEFERRED"
        item["blocked_reason"] = "Confidence too low without stronger evidence"
        work_pool.append_decision(item, "triage_defer", "triage", item["blocked_reason"])
        return item

    # Deferred engineering review without new measurements
    if "deferred engineering" in title:
        item["status"] = "DEFERRED"
        item["blocked_reason"] = "No new measurements; keep as memory"
        work_pool.append_decision(item, "triage_defer", "triage", item["blocked_reason"])
        return item

    # Debt markers alone
    if dept == "debt" or typ == "debt":
        if float(item.get("confidence", 0)) < 0.7:
            item["status"] = "DEFERRED"
            item["blocked_reason"] = "Debt markers alone are not enough"
            work_pool.append_decision(item, "triage_defer", "triage", item["blocked_reason"])
            return item

    # PD locks — refuse proposals that flip pairing/TLS by default
    locked = set(policy.get("lock_product_decisions", []))
    if "PD-001" in locked and any(
        k in title for k in ("pairing on by default", "requirepairing=true", "enable tls by default")
    ):
        item["status"] = "REJECTED"
        item["blocked_reason"] = "Violates locked PD-001 without ADR"
        work_pool.append_decision(item, "triage_reject", "triage", item["blocked_reason"])
        return item

    item["status"] = "READY"
    work_pool.append_decision(item, "triage_ready", "triage", "passed quality gate")
    return item


def value_class(pool: dict[str, Any]) -> str:
    """HIGH_VALUE | LOW_VALUE | SPECULATIVE_ONLY | NOTHING_MEANINGFUL."""
    ready = [i for i in pool.get("items", []) if i.get("status") == "READY"]
    in_flight = [
        i
        for i in pool.get("items", [])
        if i.get("status") in {"CLAIMED", "IN_PROGRESS", "REVIEW", "VALIDATION"}
    ]
    if ready or in_flight:
        high = [i for i in ready if float(i.get("confidence", 0)) >= 0.6]
        if high or in_flight:
            return "HIGH_VALUE_WORK_EXISTS"
        return "LOW_VALUE_WORK_EXISTS"
    deferred = [i for i in pool.get("items", []) if i.get("status") == "DEFERRED"]
    if deferred:
        return "ONLY_SPECULATIVE_OR_DEFERRED"
    return "NOTHING_MEANINGFUL_CURRENTLY_EXISTS"
