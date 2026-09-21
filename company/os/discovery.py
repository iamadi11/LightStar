"""Departmental discovery plugins — continuous, evidence-based."""

from __future__ import annotations

import re
import shutil
from pathlib import Path
from typing import Any, Callable

from company.os import pool as work_pool
from company.os.paths import ROOT


DiscoveryFn = Callable[[dict[str, Any], dict[str, Any]], list[dict[str, Any]]]


def _swift_available() -> bool:
    return shutil.which("swift") is not None and shutil.which("xcodebuild") is not None


def discover_ops(cfg: dict[str, Any], pool: dict[str, Any]) -> list[dict[str, Any]]:
    items: list[dict[str, Any]] = []
    if (ROOT / "company/tests").exists():
        # Only propose if not already COMPLETED recently with same fingerprint of base title
        items.append(
            work_pool.new_work_item(
                title="Run company OS self-tests (orchestration)",
                department="ops",
                type_="process",
                problem="Company OS must stay honest; regressions in pool/claims break autonomy",
                evidence=[{"kind": "repo", "ref": "company/tests"}, {"kind": "repo", "ref": "company/os"}],
                desired_outcome="python3 -m unittest discover -s company/tests -v exits 0",
                priority_rationale="Tooling integrity gates all other autonomy",
                acceptance=["unittest suite exits 0"],
                confidence=0.9,
                estimated_effort="S",
                status="DISCOVERED",
                pool_items=pool.get("items", []),
            )
        )
    return items


def discover_qa(cfg: dict[str, Any], pool: dict[str, Any]) -> list[dict[str, Any]]:
    items: list[dict[str, Any]] = []
    alexa = ROOT / "LightStarCore/Sources/LightStarCore/AlexaHueBridge.swift"
    if alexa.exists() and not _swift_available():
        items.append(
            work_pool.new_work_item(
                title="Confirm Alexa Hue bridge via macOS CI (Linux cannot compile Swift)",
                department="qa",
                type_="test",
                problem="Network-facing Alexa bridge needs macOS CI evidence, not Linux claims",
                evidence=[
                    {"kind": "repo", "ref": "LightStarCore/Sources/LightStarCore/AlexaHueBridge.swift"},
                    {"kind": "ci", "ref": ".github/workflows/ci.yml"},
                ],
                desired_outcome="CI includes LightStarCore tests + macOS build; manual M12 documented",
                priority_rationale="Honesty gate for Alexa surface",
                acceptance=["CI green or explicitly deferred_to_ci with link", "M12 matrix remains documented"],
                confidence=0.75,
                estimated_effort="S",
                status="DISCOVERED",
                pool_items=pool.get("items", []),
            )
        )
    return items


def discover_debt(cfg: dict[str, Any], pool: dict[str, Any]) -> list[dict[str, Any]]:
    if not cfg.get("discovery", {}).get("scan_todo_fixme", True):
        return []
    todo_re = re.compile(r"\b(TODO|FIXME|HACK)\b")
    count = 0
    examples: list[str] = []
    core = ROOT / "LightStarCore"
    if not core.exists():
        return []
    for path in core.rglob("*.swift"):
        try:
            for i, line in enumerate(path.read_text(encoding="utf-8", errors="replace").splitlines(), 1):
                if todo_re.search(line):
                    count += 1
                    if len(examples) < 3:
                        examples.append(f"{path.relative_to(ROOT)}:{i}")
        except OSError:
            continue
    if not count:
        return []
    return [
        work_pool.new_work_item(
            title=f"Triage {count} TODO/FIXME/HACK markers in LightStarCore",
            department="debt",
            type_="debt",
            problem="Markers may hide unfinished work; blind cleanup is harmful",
            evidence=[{"kind": "repo", "ref": "LightStarCore/**/*.swift", "note": "; ".join(examples)}],
            desired_outcome="Classify sample: keep / ticket / remove — no mass delete",
            priority_rationale="Debt awareness without premature optimization",
            acceptance=["Sample classified with rationale"],
            confidence=0.4,
            estimated_effort="M",
            status="DISCOVERED",
            pool_items=pool.get("items", []),
        )
    ]


def discover_engineering(cfg: dict[str, Any], pool: dict[str, Any]) -> list[dict[str, Any]]:
    if not cfg.get("discovery", {}).get("scan_engineering_docs", True):
        return []
    roadmap = ROOT / "engineering-roadmap.md"
    if not roadmap.exists():
        return []
    text = roadmap.read_text(encoding="utf-8", errors="replace")
    if "Deferred" not in text and "Follow-up" not in text:
        return []
    return [
        work_pool.new_work_item(
            title="Review deferred engineering items for newly available evidence",
            department="engineering",
            type_="process",
            problem="Deferred roadmap items must not be promoted without measurements",
            evidence=[{"kind": "doc", "ref": "engineering-roadmap.md"}],
            desired_outcome="Promote one item with evidence OR record no action",
            priority_rationale="Prevents silent bitrot of deferred list",
            acceptance=["Promotion with evidence or explicit no-action"],
            confidence=0.5,
            estimated_effort="S",
            status="DISCOVERED",
            pool_items=pool.get("items", []),
        )
    ]


def discover_security(cfg: dict[str, Any], pool: dict[str, Any]) -> list[dict[str, Any]]:
    """Look for stale CRITICAL fake-pairing claims (regression of T-0005)."""
    review = ROOT / "docs/validation/security-review.md"
    if not review.exists():
        return []
    text = review.read_text(encoding="utf-8", errors="replace")
    # Live false claims
    if re.search(r"Accepts any 4-digit|NO REAL VERIFICATION", text) and "FIXED" not in text[:800]:
        return [
            work_pool.new_work_item(
                title="Correct stale security docs that still claim fake 4-digit pairing",
                department="security",
                type_="docs",
                problem="Docs contradict production pairing implementation",
                evidence=[
                    {"kind": "doc", "ref": "docs/validation/security-review.md"},
                    {"kind": "repo", "ref": "LightStarCore/Sources/LightStarCore/RemoteControlServer.swift"},
                ],
                desired_outcome="Docs match PD-002 pairing; PD-001 untouched",
                priority_rationale="False CRITICAL findings invent demand and PD violations",
                acceptance=["No live fake-pairing CRITICAL claims"],
                confidence=0.85,
                estimated_effort="S",
                status="DISCOVERED",
                pool_items=pool.get("items", []),
            )
        ]
    return []


def discover_product(cfg: dict[str, Any], pool: dict[str, Any]) -> list[dict[str, Any]]:
    """Product coherence: Alexa manual matrix exists when bridge exists."""
    alexa = ROOT / "LightStarCore/Sources/LightStarCore/AlexaHueBridge.swift"
    manual = ROOT / "docs/testing/manual-mac-validation.md"
    if alexa.exists() and manual.exists():
        text = manual.read_text(encoding="utf-8", errors="replace")
        if "Alexa Hue Bridge" not in text and "M12" not in text:
            return [
                work_pool.new_work_item(
                    title="Document Alexa Hue bridge manual validation matrix",
                    department="product",
                    type_="docs",
                    problem="Alexa bridge shipped without M12 manual matrix",
                    evidence=[
                        {"kind": "repo", "ref": str(alexa.relative_to(ROOT))},
                        {"kind": "doc", "ref": str(manual.relative_to(ROOT))},
                    ],
                    desired_outcome="M12 checklist present in manual validation doc",
                    priority_rationale="Product surface without validation path",
                    acceptance=["M12 section exists"],
                    confidence=0.7,
                    estimated_effort="S",
                    status="DISCOVERED",
                    pool_items=pool.get("items", []),
                )
            ]
    return []


def discover_research(cfg: dict[str, Any], pool: dict[str, Any]) -> list[dict[str, Any]]:
    """Research is proposal-only; low confidence unless tooling gap is real."""
    tooling = ROOT / "company/memory/tooling.md"
    if not tooling.exists():
        return []
    return [
        work_pool.new_work_item(
            title="Evaluate optional Matt Pocock skills as worker capabilities",
            department="research",
            type_="research",
            problem="Research whether /tdd /code-review skills are installed for workers",
            evidence=[{"kind": "doc", "ref": "company/memory/tooling.md"}],
            desired_outcome="Adopt / monitor / reject with citation — no blind vendor",
            priority_rationale="Skills are capabilities, not orchestrator",
            acceptance=["Record adopt|monitor|reject in company memory"],
            confidence=0.35,
            estimated_effort="S",
            status="DISCOVERED",
            pool_items=pool.get("items", []),
        )
    ]


def discover_architecture(cfg: dict[str, Any], pool: dict[str, Any]) -> list[dict[str, Any]]:
    adr = ROOT / "company/adr/0002-company-operating-system.md"
    if not adr.exists():
        return [
            work_pool.new_work_item(
                title="Record Company OS architecture ADR",
                department="architecture",
                type_="docs",
                problem="Autonomy redesign needs durable ADR",
                evidence=[{"kind": "repo", "ref": "company/os"}],
                desired_outcome="ADR 0002 present",
                priority_rationale="Architecture decisions must be durable",
                acceptance=["company/adr/0002-company-operating-system.md exists"],
                confidence=0.8,
                estimated_effort="S",
                status="DISCOVERED",
                pool_items=pool.get("items", []),
            )
        ]
    return []


def discover_customer(cfg: dict[str, Any], pool: dict[str, Any]) -> list[dict[str, Any]]:
    """End-user journey friction from documented manual matrix gaps — no invented users."""
    manual = ROOT / "docs/testing/manual-mac-validation.md"
    if not manual.exists():
        return []
    text = manual.read_text(encoding="utf-8", errors="replace")
    # Unchecked boxes in Alexa section are real friction signals
    if "M12." in text and "☐" in text:
        return [
            work_pool.new_work_item(
                title="Customer journey: Alexa M12 manual checks still unchecked",
                department="product",
                type_="ux",
                problem="Manual Alexa validation matrix exists but remains unchecked (no Echo on Linux agents)",
                evidence=[
                    {"kind": "doc", "ref": "docs/testing/manual-mac-validation.md", "note": "M12 unchecked"},
                ],
                desired_outcome="Keep deferred until Echo hardware; do not invent pass/fail",
                priority_rationale="Honest customer journey debt — hardware gated",
                acceptance=["Document deferral with hardware dependency"],
                confidence=0.45,
                estimated_effort="S",
                status="DISCOVERED",
                pool_items=pool.get("items", []),
            )
        ]
    return []


DEPARTMENTS: dict[str, DiscoveryFn] = {
    "ops": discover_ops,
    "qa": discover_qa,
    "debt": discover_debt,
    "engineering": discover_engineering,
    "security": discover_security,
    "product": discover_product,
    "research": discover_research,
    "architecture": discover_architecture,
    "customer": discover_customer,
}


def run_discovery(cfg: dict[str, Any], pool: dict[str, Any], enabled: list[str] | None = None) -> list[dict[str, Any]]:
    """Run selected departments; skip fingerprints already in pool (any status)."""
    existing_fp = {i.get("fingerprint") for i in pool.get("items", [])}
    found: list[dict[str, Any]] = []
    # Include in-batch items so IDs stay unique across departments in one tick
    id_source = list(pool.get("items", []))
    names = enabled or list(DEPARTMENTS.keys())
    for name in names:
        fn = DEPARTMENTS.get(name)
        if not fn:
            continue
        for item in fn(cfg, pool):
            if item.get("fingerprint") in existing_fp:
                continue
            # Re-issue ID against pool + already-found batch
            item["id"] = work_pool.next_work_id(id_source + found)
            existing_fp.add(item.get("fingerprint"))
            found.append(item)
    return found
