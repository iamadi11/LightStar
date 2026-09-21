"""Post-completion consequences — task done is an event, not the end."""

from __future__ import annotations

from typing import Any

from company.os import pool as work_pool


def consequences_for(item: dict[str, Any], pool: dict[str, Any]) -> list[dict[str, Any]]:
    """Propose follow-up work items after COMPLETED work. Caller triages."""
    followups: list[dict[str, Any]] = []
    title = item.get("title", "")
    typ = item.get("type", "")
    dept = item.get("department", "")
    related = [item["id"]]

    # Always consider documentation drift for product/docs changes
    if typ in {"docs", "security", "bug"} or dept in {"engineering", "security"}:
        followups.append(
            work_pool.new_work_item(
                title=f"Review follow-up: validate impact of {item['id']}",
                department="qa",
                type_="test",
                problem=f"Completed work {item['id']} may need validation beyond unit self-checks",
                evidence=[
                    {"kind": "work", "ref": item["id"], "note": title},
                    {"kind": "repo", "ref": "company/os"},
                ],
                desired_outcome="Confirm acceptance criteria still hold; record evidence or defer_to_ci",
                priority_rationale="Completed change without closed-loop validation risks silent drift",
                acceptance=[
                    f"Inspect completion_evidence for {item['id']}",
                    "Mark deferred_to_ci if Swift-only",
                ],
                confidence=0.55,
                related_work=related,
                estimated_effort="S",
                status="DISCOVERED",
                pool_items=pool.get("items", []) + followups,
            )
        )

    # Self-test completion → process learning only if failures existed (skip spam)
    if "self-test" in title.lower():
        # No automatic spam follow-up; learning recorded by clock instead
        return []

    # Security doc revalidation → optional architecture note (low confidence → likely deferred)
    if "security" in title.lower() and "pairing" in title.lower():
        followups.append(
            work_pool.new_work_item(
                title="Monitor TLS/session residual risks (PD-001 locked)",
                department="security",
                type_="security",
                problem="Plaintext LAN + unused sessionToken remain after pairing fix docs",
                evidence=[
                    {"kind": "doc", "ref": "docs/validation/security-review.md"},
                    {"kind": "work", "ref": item["id"]},
                ],
                desired_outcome="Keep residual risks visible; do not flip PD-001 without ADR",
                priority_rationale="Security residual tracking; not an implementation mandate",
                acceptance=["Confirm PD-001 lock still documented", "No silent TLS flip"],
                confidence=0.35,
                related_work=related,
                estimated_effort="S",
                status="DISCOVERED",
                pool_items=pool.get("items", []) + followups,
            )
        )

    return followups
