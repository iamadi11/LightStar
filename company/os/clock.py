"""Company Clock — autonomous operating loop.

Completing a task is an event inside a tick, not process exit.
Hard idle: no READY/in-flight + no meaningful value class → IDLE_MONITORING.
"""

from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor, as_completed
from typing import Any

from company.os import cadence as cadence_mod
from company.os import consequences as consequences_mod
from company.os import discovery as discovery_mod
from company.os import executors
from company.os import feedback as feedback_mod
from company.os import deliberation as deliberation_mod
from company.os import memory as memory_mod
from company.os import pool as work_pool
from company.os import triage as triage_mod
from company.os import workers as worker_mod
from company.os.dashboard import render_status
from company.os.paths import STATE, ensure_state_dirs, read_json, utc_now, write_json

COMPANY_PATH = STATE / "company.json"
IDLE_VALUE_CLASSES = {
    "NOTHING_MEANINGFUL_CURRENTLY_EXISTS",
    "ONLY_SPECULATIVE_OR_DEFERRED",
}


def load_company() -> dict[str, Any]:
    return read_json(
        COMPANY_PATH,
        {
            "version": 1,
            "mode": "STOPPED",
            "cycle": 0,
            "stop_reason": None,
            "idle_streak": 0,
            "updated_at": utc_now(),
            "last_tick_summary": None,
        },
    )


def save_company(data: dict[str, Any]) -> None:
    data["updated_at"] = utc_now()
    write_json(COMPANY_PATH, data)


def _should_idle(pool: dict[str, Any], summary: dict[str, Any], vc: str) -> tuple[bool, str]:
    """Return (idle?, reason). Never invent work to stay busy."""
    ready = any(i.get("status") == "READY" for i in pool.get("items", []))
    in_flight = any(
        i.get("status") in {"CLAIMED", "IN_PROGRESS", "REVIEW", "VALIDATION"}
        for i in pool.get("items", [])
    )
    if ready or in_flight:
        return False, ""
    # Productive tick still running consequences next — don't idle mid-burst
    if summary.get("completed") or summary.get("followups"):
        # Follow-ups already triaged; if none became READY, idle is OK
        if any(i.get("status") == "READY" for i in pool.get("items", [])):
            return False, ""
    if vc in IDLE_VALUE_CLASSES:
        return True, vc
    if not summary.get("discovered") and not summary.get("triaged_ready"):
        return True, "NO_HIGH_VALUE_READY_WORK"
    return True, "NO_HIGH_VALUE_READY_WORK"


class CompanyClock:
    def __init__(self, cfg: dict[str, Any]):
        self.cfg = cfg
        ensure_state_dirs()
        self.lease_seconds = int(cfg.get("execution", {}).get("claim_lease_seconds", 900))
        self.max_workers_per_tick = int(cfg.get("execution", {}).get("max_workers_per_tick", 4))
        self.stop_when_idle = bool(cfg.get("execution", {}).get("stop_when_no_high_value_work", True))
        # Hard cap — never allow runaway clocks
        self.hard_max_ticks = int(cfg.get("execution", {}).get("hard_max_ticks", 32))

    def start(self, max_ticks: int | None = None) -> dict[str, Any]:
        """Run the company until idle/stop or max_ticks."""
        company = load_company()
        company["mode"] = "AUTONOMOUS"
        company["stop_reason"] = None
        company["idle_streak"] = 0
        save_company(company)

        exec_cfg = self.cfg.get("execution", {})
        ticks = max_ticks if max_ticks is not None else int(exec_cfg.get("max_ticks", 12))
        ticks = max(1, min(ticks, self.hard_max_ticks))
        summaries: list[dict[str, Any]] = []

        for _ in range(ticks):
            summary = self.tick()
            summaries.append(summary)
            company = load_company()
            if company.get("mode") in {"IDLE_MONITORING", "STOPPED"}:
                break
            # Belt-and-suspenders: honor summary flag even if mode race
            if summary.get("idle"):
                break

        return {
            "ticks": len(summaries),
            "summaries": summaries,
            "company": load_company(),
            "status_text": render_status(),
        }

    def stop(self, reason: str = "explicit_stop") -> None:
        company = load_company()
        company["mode"] = "STOPPED"
        company["stop_reason"] = reason
        save_company(company)

    def tick(self) -> dict[str, Any]:
        company = load_company()
        if company.get("mode") == "STOPPED":
            return {"cycle": company.get("cycle", 0), "idle": True, "skipped": "STOPPED"}

        company["cycle"] = int(company.get("cycle", 0)) + 1
        company["mode"] = "AUTONOMOUS"
        save_company(company)

        pool = work_pool.load_pool()
        workers = worker_mod.load_workers()
        memory = memory_mod.load_memory()
        cadence = cadence_mod.load_cadence()

        summary: dict[str, Any] = {
            "cycle": company["cycle"],
            "recovered": [],
            "discovered": [],
            "triaged_ready": [],
            "triaged_rejected": [],
            "triaged_deferred": [],
            "completed": [],
            "blocked": [],
            "followups": [],
            "deliberations": [],
            "feedback": [],
            "value_class": None,
            "idle": False,
        }

        # 1) Recover stale claims
        summary["recovered"] = worker_mod.recover_stale_claims(
            pool, workers, lease_seconds=self.lease_seconds
        )

        # 2) Departmental discovery (cadence-aware)
        enabled = list(discovery_mod.DEPARTMENTS.keys())
        if not cadence_mod.due(cadence, "tech_debt_review"):
            enabled = [e for e in enabled if e != "debt"]
        else:
            cadence_mod.mark_run(cadence, "tech_debt_review")
        if not cadence_mod.due(cadence, "technology_review"):
            enabled = [e for e in enabled if e != "research"]
        else:
            cadence_mod.mark_run(cadence, "technology_review")

        for item in discovery_mod.run_discovery(self.cfg, pool, enabled=enabled):
            if work_pool.find_by_fingerprint(pool["items"], item["fingerprint"]):
                continue
            # Significant proposals get multi-perspective deliberation before triage
            if float(item.get("confidence", 0)) >= 0.75 and item.get("type") in {
                "security",
                "architecture",
                "research",
            }:
                decision = deliberation_mod.deliberate(item, memory)
                summary["deliberations"].append(decision.get("decision"))
                if decision.get("decision") == "reject":
                    item["status"] = "REJECTED"
                    item["blocked_reason"] = decision.get("reasoning", "deliberation reject")
                    work_pool.append_decision(item, "deliberation_reject", "board", item["blocked_reason"])
                    pool["items"].append(item)
                    memory_mod.remember_reject(memory, item.get("title", ""), item["blocked_reason"])
                    continue
            pool["items"].append(item)
            summary["discovered"].append(item["id"])

        # 3) Triage
        for item in list(pool.get("items", [])):
            if item.get("status") in {"DISCOVERED", "PROPOSED"}:
                triage_mod.triage_item(item, self.cfg, pool)
                if item["status"] == "READY":
                    summary["triaged_ready"].append(item["id"])
                elif item["status"] == "REJECTED":
                    summary["triaged_rejected"].append(item["id"])
                    memory_mod.remember_reject(
                        memory, item.get("title", ""), item.get("blocked_reason") or ""
                    )
                elif item["status"] == "DEFERRED":
                    summary["triaged_deferred"].append(item["id"])

        # 4) Claim + execute concurrently
        idle_workers = [w for w in workers.get("workers", []) if w.get("status") == "IDLE"]
        claims: list[tuple[dict[str, Any], dict[str, Any]]] = []
        for worker in idle_workers:
            if len(claims) >= self.max_workers_per_tick:
                break
            candidate = worker_mod.select_ready_for_worker(pool, worker)
            if not candidate:
                continue
            try:
                claimed = worker_mod.claim_work(
                    pool, workers, candidate["id"], worker["id"], lease_seconds=self.lease_seconds
                )
                claims.append((claimed, worker))
            except ValueError:
                continue

        completed_this_tick: list[dict[str, Any]] = []

        def _run(pair: tuple[dict[str, Any], dict[str, Any]]) -> dict[str, Any]:
            item, _w = pair
            return executors.execute_item(item, workers)

        if claims:
            with ThreadPoolExecutor(max_workers=min(len(claims), self.max_workers_per_tick)) as ex:
                futs = [ex.submit(_run, c) for c in claims]
                for fut in as_completed(futs):
                    item = fut.result()
                    if item.get("status") == "COMPLETED":
                        summary["completed"].append(item["id"])
                        completed_this_tick.append(item)
                    elif item.get("status") == "BLOCKED":
                        summary["blocked"].append(item["id"])
                        memory_mod.remember_failure(
                            memory, item["id"], item.get("blocked_reason") or "blocked"
                        )

        # 5) Consequences + product feedback loop
        for item in completed_this_tick:
            fb = feedback_mod.product_feedback(item)
            summary["feedback"].append(fb)
            memory_mod.remember_learning(memory, fb.get("summary", f"feedback:{item['id']}"))

            for fu in consequences_mod.consequences_for(item, pool):
                if work_pool.find_by_fingerprint(pool["items"], fu["fingerprint"]):
                    continue
                pool["items"].append(fu)
                summary["followups"].append(fu["id"])
                triage_mod.triage_item(fu, self.cfg, pool)

            memory_mod.remember_decision(
                memory, f"completed:{item['id']}", item.get("title", "")[:120], confidence=0.8
            )

        # 6) Cadence: retrospective / self-improve
        if cadence_mod.due(cadence, "retrospective"):
            cadence_mod.mark_run(cadence, "retrospective")
            memory_mod.remember_learning(
                memory,
                f"Retro cycle {company['cycle']}: completed={len(summary['completed'])} "
                f"rejected={len(summary['triaged_rejected'])} deferred={len(summary['triaged_deferred'])}",
            )

        if cadence_mod.due(cadence, "self_improvement"):
            cadence_mod.mark_run(cadence, "self_improvement")
            rejects = len([i for i in pool["items"] if i.get("status") == "REJECTED"])
            total = max(1, len(pool["items"]))
            if rejects / total > 0.4:
                prop = work_pool.new_work_item(
                    title="Self-improve: reduce low-evidence discovery noise",
                    department="ops",
                    type_="process",
                    problem="High reject rate suggests discovery/triage mismatch",
                    evidence=[
                        {
                            "kind": "metric",
                            "ref": "work_pool",
                            "note": f"rejects={rejects} total={total}",
                        }
                    ],
                    desired_outcome="Tighten discovery scanners or raise evidence bar",
                    priority_rationale="Process improvement from measured reject rate",
                    acceptance=["Record improvement proposal under company/improvements/"],
                    confidence=0.5,
                    estimated_effort="S",
                    status="DISCOVERED",
                    pool_items=pool["items"],
                )
                if not work_pool.find_by_fingerprint(pool["items"], prop["fingerprint"]):
                    pool["items"].append(prop)
                    triage_mod.triage_item(prop, self.cfg, pool)

        # 7) Persist
        work_pool.save_pool(pool)
        worker_mod.save_workers(workers)
        memory_mod.save_memory(memory)
        cadence_mod.save_cadence(cadence)

        vc = triage_mod.value_class(pool)
        summary["value_class"] = vc

        # 8) Idle / stop — must not spin forever
        idle, reason = _should_idle(pool, summary, vc)
        if self.stop_when_idle and idle:
            streak = int(company.get("idle_streak", 0)) + 1
            company["idle_streak"] = streak
            # Enter idle immediately when value class says speculative/nothing
            if vc in IDLE_VALUE_CLASSES or streak >= 1:
                company["mode"] = "IDLE_MONITORING"
                company["stop_reason"] = reason
                summary["idle"] = True
        else:
            company["idle_streak"] = 0

        company["last_tick_summary"] = {
            "cycle": summary["cycle"],
            "completed": summary["completed"],
            "discovered": summary["discovered"],
            "followups": summary["followups"],
            "value_class": vc,
            "idle": summary["idle"],
        }
        save_company(company)

        # One report per tick is fine; gitignore bulk — also write rolling latest
        write_json(
            STATE.parent / "reports" / "tick-latest.json",
            {"generated_at": utc_now(), "summary": summary, "company": company},
        )
        return summary
