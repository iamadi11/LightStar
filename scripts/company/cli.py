#!/usr/bin/env python3
"""LightStar Autonomous Company — durable state + cycle controller.

Single entry: ./scripts/autonomous-company

This process does NOT invent green Swift build results on Linux.
It discovers evidence-backed tasks, prioritizes, writes work orders,
and stops when no high-value work remains.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[2]
COMPANY = ROOT / "company"
DEFAULT_CONFIG = COMPANY / "config.yaml"


def utc_now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


def load_yaml(path: Path) -> dict[str, Any]:
    try:
        import yaml  # type: ignore
    except ImportError:
        # Minimal fallback for flat config if PyYAML missing
        return _minimal_config_fallback(path)
    with path.open() as f:
        data = yaml.safe_load(f)
    if not isinstance(data, dict):
        raise SystemExit(f"Invalid config: {path}")
    return data


def _minimal_config_fallback(path: Path) -> dict[str, Any]:
    """Enough defaults to run if PyYAML is unavailable."""
    print("warning: PyYAML not installed; using built-in defaults + raw config hints", file=sys.stderr)
    return {
        "version": 1,
        "execution": {
            "max_iterations": 3,
            "max_tasks_per_cycle": 2,
            "stop_when_no_high_value_work": True,
            "resume_from_durable_state": True,
        },
        "policy": {
            "require_evidence_for_tasks": True,
            "allow_high_impact": False,
            "forbid_claiming_unrun_validation": True,
            "lock_product_decisions": ["PD-001", "PD-002"],
        },
        "validation": {
            "company_self_tests": "python3 -m unittest discover -s company/tests -v",
            "unit_tests": "swift test --package-path LightStarCore",
        },
        "paths": {
            "state_dir": "company/state",
            "memory_dir": "company/memory",
            "reports_dir": "company/reports",
            "improvements_dir": "company/improvements",
        },
        "discovery": {
            "scan_engineering_docs": True,
            "scan_todo_fixme": True,
            "scan_agents_md": True,
        },
        "_config_path": str(path),
    }


def ensure_dirs(cfg: dict[str, Any]) -> dict[str, Path]:
    paths = cfg.get("paths", {})
    mapping = {
        "state": ROOT / paths.get("state_dir", "company/state"),
        "memory": ROOT / paths.get("memory_dir", "company/memory"),
        "reports": ROOT / paths.get("reports_dir", "company/reports"),
        "improvements": ROOT / paths.get("improvements_dir", "company/improvements"),
    }
    for p in mapping.values():
        p.mkdir(parents=True, exist_ok=True)
    (mapping["state"] / "work_orders").mkdir(parents=True, exist_ok=True)
    return mapping


def read_json(path: Path, default: Any) -> Any:
    if not path.exists():
        return default
    with path.open() as f:
        return json.load(f)


def write_json(path: Path, data: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    with tmp.open("w") as f:
        json.dump(data, f, indent=2, sort_keys=True)
        f.write("\n")
    tmp.replace(path)


def swift_available() -> bool:
    return shutil.which("swift") is not None and shutil.which("xcodebuild") is not None


def next_task_id(tasks: list[dict[str, Any]]) -> str:
    nums = []
    for t in tasks:
        m = re.match(r"T-(\d+)$", t.get("id", ""))
        if m:
            nums.append(int(m.group(1)))
    return f"T-{(max(nums) if nums else 0) + 1:04d}"


@dataclass
class DiscoveryHit:
    title: str
    category: str
    evidence: list[dict[str, str]]
    priority_rationale: str
    acceptance: list[str]


def discover(cfg: dict[str, Any]) -> list[DiscoveryHit]:
    hits: list[DiscoveryHit] = []
    disc = cfg.get("discovery", {})

    # 0) Company self-test — always first-class when present
    if (ROOT / "company/tests").exists():
        hits.append(
            DiscoveryHit(
                title="Run autonomous-company self-tests",
                category="process",
                evidence=[{"kind": "repo", "ref": "company/tests"}],
                priority_rationale="The company tooling itself must stay honest and tested.",
                acceptance=["python3 -m unittest discover -s company/tests -v exits 0"],
            )
        )

    # 1) Engineering tracker open items (docs)
    if disc.get("scan_engineering_docs", True):
        tracker = ROOT / "engineering-improvement-tracker.md"
        roadmap = ROOT / "engineering-roadmap.md"
        for path in (tracker, roadmap):
            if not path.exists():
                continue
            text = path.read_text(encoding="utf-8", errors="replace")
            # Deferred / follow-up lines are candidates, not automatic work
            if "Deferred" in text or "Follow-up" in text:
                hits.append(
                    DiscoveryHit(
                        title="Review deferred engineering items for newly available evidence",
                        category="process",
                        evidence=[
                            {
                                "kind": "doc",
                                "ref": str(path.relative_to(ROOT)),
                                "note": "Deferred/follow-up sections exist; promote only with new evidence",
                            }
                        ],
                        priority_rationale=(
                            "Existing engineering process already parked items. Revisit only if "
                            "new measurements or failures appear; otherwise leave deferred."
                        ),
                        acceptance=[
                            "Either promote one deferred item with new evidence, or record NO ACTION",
                        ],
                    )
                )
                break

    # 2) TODO/FIXME in Swift (cap)
    if disc.get("scan_todo_fixme", True):
        todo_re = re.compile(r"\b(TODO|FIXME|HACK)\b")
        count = 0
        examples: list[str] = []
        for path in (ROOT / "LightStarCore").rglob("*.swift"):
            try:
                for i, line in enumerate(path.read_text(encoding="utf-8", errors="replace").splitlines(), 1):
                    if todo_re.search(line):
                        count += 1
                        if len(examples) < 5:
                            examples.append(f"{path.relative_to(ROOT)}:{i}:{line.strip()[:120]}")
            except OSError:
                continue
        if count:
            hits.append(
                DiscoveryHit(
                    title=f"Triage {count} TODO/FIXME/HACK markers in LightStarCore",
                    category="debt",
                    evidence=[
                        {"kind": "repo", "ref": "LightStarCore/**/*.swift", "note": "; ".join(examples) or f"{count} markers"}
                    ],
                    priority_rationale=(
                        "Markers may indicate unfinished work, but many are intentional. "
                        "Triage beats blind cleanup."
                    ),
                    acceptance=[
                        "Classify each sampled marker: keep / ticket / remove",
                        "Do not mass-delete comments without understanding",
                    ],
                )
            )

    # 3) Alexa bridge without Swift compile proof on this host
    alexa = ROOT / "LightStarCore/Sources/LightStarCore/AlexaHueBridge.swift"
    if alexa.exists() and not swift_available():
        hits.append(
            DiscoveryHit(
                title="Confirm Alexa Hue bridge via macOS CI (cannot validate Swift on Linux agent)",
                category="test",
                evidence=[
                    {"kind": "repo", "ref": "LightStarCore/Sources/LightStarCore/AlexaHueBridge.swift"},
                    {"kind": "ci", "ref": ".github/workflows/ci.yml", "note": "macos-15 required"},
                ],
                priority_rationale=(
                    "New network-facing bridge shipped; Linux agents must not claim build success. "
                    "CI green + manual Echo discovery remain the proof."
                ),
                acceptance=[
                    "CI job for main includes LightStarCore tests + macOS build",
                    "Manual M12 Alexa checks remain documented until hardware available",
                ],
            )
            )

    return hits


def prioritize(hits: list[DiscoveryHit], existing: list[dict[str, Any]], max_tasks: int) -> list[dict[str, Any]]:
    """Deterministic prioritization with explicit rationale — not a fake ML score."""
    # Skip any title already in the pool (including done/blocked) to avoid duplicate work orders.
    existing_titles = {t.get("title") for t in existing}
    ranked: list[tuple[int, DiscoveryHit]] = []
    for h in hits:
        if h.title in existing_titles:
            continue
        # Higher is more urgent
        score = 0
        if h.category in {"security", "bug"}:
            score += 50
        if h.category == "test":
            score += 40
        if h.category == "process":
            score += 30
            if "self-tests" in h.title.lower():
                score += 25  # keep the company tooling honest first
        if h.category == "debt":
            score += 10
        if any(e.get("kind") == "ci" for e in h.evidence):
            score += 15
        ranked.append((score, h))
    ranked.sort(key=lambda x: (-x[0], x[1].title))

    out: list[dict[str, Any]] = []
    tasks = list(existing)
    for score, h in ranked[:max_tasks]:
        tid = next_task_id(tasks + out)
        task = {
            "id": tid,
            "title": h.title,
            "status": "proposed",
            "category": h.category,
            "evidence": h.evidence,
            "priority_rationale": f"{h.priority_rationale} (rank_score={score}, non-authoritative)",
            "owner_role": "controller",
            "acceptance": h.acceptance,
            "non_goals": ["Do not invent additional scope"],
            "risks": ["Acting without Mac/CI proof where required"],
            "validation_plan": list(h.acceptance),
            "created_at": utc_now(),
            "updated_at": utc_now(),
            "rank_score": score,
        }
        out.append(task)
    return out


def challenge_task(task: dict[str, Any], cfg: dict[str, Any]) -> dict[str, Any]:
    """Strategy-lite gate: reject weak tasks."""
    policy = cfg.get("policy", {})
    if policy.get("require_evidence_for_tasks", True) and not task.get("evidence"):
        task["status"] = "rejected"
        task["blocked_reason"] = "No evidence"
        return task
    # Reject pure deferred-review if no new evidence markers beyond the doc itself
    if task["title"].startswith("Review deferred engineering"):
        task["status"] = "deferred"
        task["blocked_reason"] = (
            "NO ACTIONABLE HIGH-VALUE TASK without new measurements; "
            "keeping deferred list as memory only"
        )
    elif task["category"] == "process" and "self-tests" in task["title"].lower():
        task["status"] = "accepted"
        task["owner_role"] = "qa"
    elif task["category"] == "test" and "Alexa" in task["title"]:
        task["status"] = "accepted"
        task["owner_role"] = "qa"
    elif task["category"] == "debt":
        task["status"] = "deferred"
        task["blocked_reason"] = "Triage debt only when capacity; markers alone are not enough"
    return task


def write_work_order(state_dir: Path, task: dict[str, Any]) -> Path:
    path = state_dir / "work_orders" / f"{task['id']}.json"
    order = {
        "task_id": task["id"],
        "title": task["title"],
        "owner_role": task.get("owner_role"),
        "acceptance": task.get("acceptance", []),
        "validation_plan": task.get("validation_plan", []),
        "created_at": utc_now(),
        "instructions": [
            "Read company/memory/CONTEXT.md and agents.md before changing product code.",
            "Answer anti-slop questions before coding.",
            "Record commands run and outcomes in completion_evidence.",
            "Do not claim Swift validation on Linux.",
        ],
    }
    write_json(path, order)
    return path


def run_company_self_tests() -> tuple[bool, str]:
    cmd = [sys.executable, "-m", "unittest", "discover", "-s", "company/tests", "-v"]
    try:
        proc = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, timeout=120)
    except subprocess.TimeoutExpired:
        return False, "self-tests timed out"
    ok = proc.returncode == 0
    out = (proc.stdout or "") + (proc.stderr or "")
    return ok, out[-4000:]


def cmd_init(cfg: dict[str, Any]) -> None:
    paths = ensure_dirs(cfg)
    runtime = {
        "version": 1,
        "phase": "idle",
        "cycle": 0,
        "updated_at": utc_now(),
        "swift_toolchain_available": swift_available(),
        "last_conclusion": None,
        "active_task_id": None,
    }
    if not (paths["state"] / "runtime.json").exists() or not cfg.get("execution", {}).get("resume_from_durable_state", True):
        write_json(paths["state"] / "runtime.json", runtime)
    if not (paths["state"] / "task_pool.json").exists():
        write_json(paths["state"] / "task_pool.json", {"version": 1, "tasks": [], "updated_at": utc_now()})
    print("initialized", paths["state"])


def cmd_status(cfg: dict[str, Any]) -> None:
    paths = ensure_dirs(cfg)
    runtime = read_json(paths["state"] / "runtime.json", {})
    pool = read_json(paths["state"] / "task_pool.json", {"tasks": []})
    print(json.dumps({"runtime": runtime, "task_count": len(pool.get("tasks", [])), "tasks": pool.get("tasks", [])}, indent=2))


def cmd_cycle(cfg: dict[str, Any], iterations: int | None = None) -> int:
    paths = ensure_dirs(cfg)
    exec_cfg = cfg.get("execution", {})
    max_iter = iterations if iterations is not None else int(exec_cfg.get("max_iterations", 3))
    max_tasks = int(exec_cfg.get("max_tasks_per_cycle", 2))

    runtime = read_json(paths["state"] / "runtime.json", {})
    if not runtime:
        cmd_init(cfg)
        runtime = read_json(paths["state"] / "runtime.json", {})

    pool = read_json(paths["state"] / "task_pool.json", {"version": 1, "tasks": []})
    tasks: list[dict[str, Any]] = pool.get("tasks", [])

    conclusions: list[str] = []
    for i in range(max_iter):
        runtime["cycle"] = int(runtime.get("cycle", 0)) + 1
        runtime["phase"] = "discovery"
        runtime["updated_at"] = utc_now()
        write_json(paths["state"] / "runtime.json", runtime)

        hits = discover(cfg)
        proposed = prioritize(hits, tasks, max_tasks=max_tasks)
        challenged = [challenge_task(t, cfg) for t in proposed]

        # Merge new tasks
        for t in challenged:
            if any(x["id"] == t["id"] for x in tasks):
                continue
            tasks.append(t)

        accepted = [t for t in challenged if t.get("status") == "accepted"]
        runtime["phase"] = "execution"
        write_json(paths["state"] / "runtime.json", runtime)

        if not accepted:
            conclusion = "NO ACTIONABLE HIGH-VALUE TASK IDENTIFIED"
            if any(t.get("status") == "deferred" for t in challenged):
                conclusion += " (deferred candidates retained as memory)"
            conclusions.append(conclusion)
            runtime["last_conclusion"] = conclusion
            runtime["phase"] = "idle"
            runtime["active_task_id"] = None
            runtime["updated_at"] = utc_now()
            write_json(paths["state"] / "runtime.json", runtime)
            write_json(paths["state"] / "task_pool.json", {"version": 1, "tasks": tasks, "updated_at": utc_now()})
            if exec_cfg.get("stop_when_no_high_value_work", True):
                break
            continue

        for task in accepted:
            runtime["active_task_id"] = task["id"]
            task["status"] = "in_progress"
            task["updated_at"] = utc_now()
            wo = write_work_order(paths["state"], task)

            # Built-in executors for process/self-test tasks only (safe automation)
            if "self-tests" in task["title"].lower():
                ok, log = run_company_self_tests()
                task["completion_evidence"] = [
                    f"command: python3 -m unittest discover -s company/tests -v",
                    f"exit_ok={ok}",
                    log[:1500],
                ]
                if ok:
                    task["status"] = "done"
                    conclusions.append(f"{task['id']} done: company self-tests passed")
                else:
                    task["status"] = "blocked"
                    task["blocked_reason"] = "self-tests failed"
                    conclusions.append(f"{task['id']} blocked: self-tests failed")
            elif "Alexa" in task["title"] and not swift_available():
                # Honest gate: mark review required; do not fake CI
                task["status"] = "blocked"
                task["blocked_reason"] = (
                    "Swift/Xcode unavailable on this host; await GitHub Actions macos-15 results"
                )
                task["completion_evidence"] = [
                    f"swift_available={swift_available()}",
                    "work_order=" + str(wo.relative_to(ROOT)),
                ]
                conclusions.append(f"{task['id']} blocked: deferred_to_ci")
            else:
                task["status"] = "blocked"
                task["blocked_reason"] = (
                    "No safe auto-executor for this category; agent must implement via /autonomous-company skill"
                )
                conclusions.append(f"{task['id']} awaiting agent execution")

            task["updated_at"] = utc_now()

        runtime["phase"] = "idle"
        runtime["active_task_id"] = None
        runtime["last_conclusion"] = " | ".join(conclusions[-3:])
        runtime["updated_at"] = utc_now()
        write_json(paths["state"] / "runtime.json", runtime)
        write_json(paths["state"] / "task_pool.json", {"version": 1, "tasks": tasks, "updated_at": utc_now()})

    report = {
        "generated_at": utc_now(),
        "swift_toolchain_available": swift_available(),
        "conclusions": conclusions,
        "task_snapshot": tasks,
    }
    report_path = paths["reports"] / f"cycle-{datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')}.json"
    write_json(report_path, report)
    print(json.dumps(report, indent=2))
    # Exit 0 even when no work — that is a valid engineering outcome
    return 0


def cmd_self_test(cfg: dict[str, Any]) -> int:
    ok, log = run_company_self_tests()
    print(log)
    return 0 if ok else 1


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="LightStar Autonomous Company")
    parser.add_argument(
        "command",
        nargs="?",
        default="cycle",
        choices=["init", "status", "cycle", "resume", "self-test"],
        help="init|status|cycle|resume|self-test (default: cycle)",
    )
    parser.add_argument("--config", default=str(DEFAULT_CONFIG))
    parser.add_argument("--iterations", type=int, default=None)
    args = parser.parse_args(argv)

    cfg_path = Path(args.config)
    if not cfg_path.is_absolute():
        cfg_path = ROOT / cfg_path
    if not cfg_path.exists():
        print(f"missing config: {cfg_path}", file=sys.stderr)
        return 2
    cfg = load_yaml(cfg_path)

    if args.command == "init":
        cmd_init(cfg)
        return 0
    if args.command == "status":
        cmd_status(cfg)
        return 0
    if args.command in {"cycle", "resume"}:
        return cmd_cycle(cfg, iterations=args.iterations)
    if args.command == "self-test":
        return cmd_self_test(cfg)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
