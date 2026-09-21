#!/usr/bin/env python3
"""LightStar Autonomous Company — Company OS entrypoint.

Single command starts the living company (not a one-task runner).

  ./scripts/autonomous-company           # start / continue autonomous run
  ./scripts/autonomous-company start
  ./scripts/autonomous-company status
  ./scripts/autonomous-company stop
  ./scripts/autonomous-company tick
  ./scripts/autonomous-company self-test
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[2]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from company.os.clock import CompanyClock, load_company, save_company  # noqa: E402
from company.os.dashboard import render_status, status_dict  # noqa: E402
from company.os.paths import DEFAULT_CONFIG, ensure_state_dirs, utc_now  # noqa: E402


def load_yaml(path: Path) -> dict[str, Any]:
    try:
        import yaml  # type: ignore
    except ImportError:
        return {
            "version": 2,
            "execution": {
                "max_ticks": 12,
                "max_workers_per_tick": 4,
                "claim_lease_seconds": 900,
                "stop_when_no_high_value_work": True,
            },
            "policy": {
                "require_evidence_for_tasks": True,
                "allow_high_impact": False,
                "lock_product_decisions": ["PD-001", "PD-002"],
            },
            "discovery": {
                "scan_engineering_docs": True,
                "scan_todo_fixme": True,
            },
        }
    with path.open() as f:
        data = yaml.safe_load(f)
    if not isinstance(data, dict):
        raise SystemExit(f"Invalid config: {path}")
    return data


def cmd_init(cfg: dict[str, Any]) -> None:
    ensure_state_dirs()
    from company.os import pool as work_pool
    from company.os import workers as worker_mod
    from company.os.memory import load_memory, save_memory

    work_pool.load_pool()
    worker_mod.load_workers()
    save_memory(load_memory())
    company = load_company()
    if company.get("mode") == "STOPPED" and company.get("cycle", 0) == 0:
        company["mode"] = "INITIALIZED"
        company["updated_at"] = utc_now()
        save_company(company)
    print("Company initialized.")
    print(render_status())


def cmd_status(_cfg: dict[str, Any]) -> None:
    ensure_state_dirs()
    print(render_status())
    if "--json" in sys.argv:
        print(json.dumps(status_dict(), indent=2))


def cmd_start(cfg: dict[str, Any], max_ticks: int | None) -> int:
    ensure_state_dirs()
    print("Company started.")
    clock = CompanyClock(cfg)
    result = clock.start(max_ticks=max_ticks)
    print()
    print(result["status_text"])
    print()
    print(
        json.dumps(
            {
                "ticks": result["ticks"],
                "mode": result["company"].get("mode"),
                "stop_reason": result["company"].get("stop_reason"),
                "summaries": [
                    {
                        "cycle": s.get("cycle"),
                        "discovered": s.get("discovered"),
                        "completed": s.get("completed"),
                        "followups": s.get("followups"),
                        "value_class": s.get("value_class"),
                    }
                    for s in result["summaries"]
                ],
            },
            indent=2,
        )
    )
    return 0


def cmd_tick(cfg: dict[str, Any]) -> int:
    ensure_state_dirs()
    clock = CompanyClock(cfg)
    company = load_company()
    company["mode"] = "AUTONOMOUS"
    save_company(company)
    summary = clock.tick()
    print(json.dumps(summary, indent=2))
    print()
    print(render_status())
    return 0


def cmd_stop(_cfg: dict[str, Any]) -> int:
    clock = CompanyClock({"execution": {}})
    clock.stop("explicit_stop")
    print("Company stopped. State persisted — next start resumes.")
    print(render_status())
    return 0


def cmd_self_test(_cfg: dict[str, Any]) -> int:
    import subprocess

    proc = subprocess.run(
        [sys.executable, "-m", "unittest", "discover", "-s", "company/tests", "-v"],
        cwd=ROOT,
    )
    return proc.returncode


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="LightStar Autonomous Company OS")
    parser.add_argument(
        "command",
        nargs="?",
        default="start",
        choices=["init", "status", "start", "run", "tick", "stop", "cycle", "resume", "self-test"],
        help="start|status|tick|stop|self-test (default: start)",
    )
    parser.add_argument("--config", default=str(DEFAULT_CONFIG))
    parser.add_argument("--ticks", type=int, default=None, help="Max company clock ticks")
    parser.add_argument("--iterations", type=int, default=None, help="Alias for --ticks (compat)")
    parser.add_argument("--json", action="store_true", help="Include JSON with status")
    args = parser.parse_args(argv)

    cfg_path = Path(args.config)
    if not cfg_path.is_absolute():
        cfg_path = ROOT / cfg_path
    if not cfg_path.exists():
        print(f"missing config: {cfg_path}", file=sys.stderr)
        return 2
    cfg = load_yaml(cfg_path)

    ticks = args.ticks if args.ticks is not None else args.iterations

    if args.command == "init":
        cmd_init(cfg)
        return 0
    if args.command == "status":
        # re-parse for --json already in argv
        print(render_status())
        return 0
    if args.command in {"start", "run", "cycle", "resume"}:
        # cycle/resume kept as aliases so old docs still work — they now start the OS
        return cmd_start(cfg, max_ticks=ticks)
    if args.command == "tick":
        return cmd_tick(cfg)
    if args.command == "stop":
        return cmd_stop(cfg)
    if args.command == "self-test":
        return cmd_self_test(cfg)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
