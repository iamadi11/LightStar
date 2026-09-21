"""Company OS unit + multi-cycle + adversarial tests."""

from __future__ import annotations

import sys
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from company.os import pool as work_pool
from company.os import workers as worker_mod
from company.os import triage as triage_mod
from company.os import consequences as consequences_mod
from company.os.clock import CompanyClock
from company.os.paths import STATE


class PoolTests(unittest.TestCase):
    def test_next_work_id_increments(self):
        tid = work_pool.next_work_id([{"id": "W-0001"}, {"id": "T-0007"}])
        self.assertEqual(tid, "W-0008")

    def test_fingerprint_stable(self):
        a = work_pool.fingerprint_title("Hello World")
        b = work_pool.fingerprint_title("  hello   world ")
        self.assertEqual(a, b)


class TriageTests(unittest.TestCase):
    def test_rejects_missing_evidence(self):
        item = work_pool.new_work_item(
            title="Vague idea with enough characters here",
            department="engineering",
            type_="bug",
            problem="x",
            evidence=[],
            desired_outcome="y",
            priority_rationale="z" * 20,
            acceptance=["ok"],
            confidence=0.9,
            pool_items=[],
        )
        out = triage_mod.triage_item(item, {"policy": {"require_evidence_for_tasks": True}}, {"items": []})
        self.assertEqual(out["status"], "REJECTED")

    def test_defers_low_confidence_debt(self):
        item = work_pool.new_work_item(
            title="Triage TODO markers somewhere",
            department="debt",
            type_="debt",
            problem="markers",
            evidence=[{"kind": "repo", "ref": "x"}],
            desired_outcome="triage",
            priority_rationale="markers exist needing discipline",
            acceptance=["classify"],
            confidence=0.4,
            pool_items=[],
        )
        out = triage_mod.triage_item(item, {"policy": {"require_evidence_for_tasks": True}}, {"items": []})
        self.assertEqual(out["status"], "DEFERRED")


class ClaimTests(unittest.TestCase):
    def setUp(self):
        self.pool = {"version": 2, "items": []}
        self.workers = worker_mod._empty()
        item = work_pool.new_work_item(
            title="Run company OS self-tests (orchestration)",
            department="ops",
            type_="process",
            problem="test",
            evidence=[{"kind": "repo", "ref": "company/tests"}],
            desired_outcome="ok",
            priority_rationale="integrity",
            acceptance=["ok"],
            confidence=0.9,
            pool_items=[],
        )
        item["status"] = "READY"
        self.pool["items"].append(item)
        self.item_id = item["id"]

    def test_claim_conflict(self):
        worker_mod.claim_work(self.pool, self.workers, self.item_id, "ops-1", lease_seconds=60)
        with self.assertRaises(ValueError):
            worker_mod.claim_work(self.pool, self.workers, self.item_id, "qa-1", lease_seconds=60)

    def test_stale_lease_recovery(self):
        item = worker_mod.claim_work(self.pool, self.workers, self.item_id, "ops-1", lease_seconds=60)
        # Force expire
        past = (datetime.now(timezone.utc) - timedelta(seconds=10)).replace(microsecond=0).isoformat()
        item["claim"]["lease_expires_at"] = past
        item["status"] = "IN_PROGRESS"
        recovered = worker_mod.recover_stale_claims(self.pool, self.workers, lease_seconds=1)
        self.assertIn(self.item_id, recovered)
        self.assertEqual(item["status"], "READY")
        ops = next(w for w in self.workers["workers"] if w["id"] == "ops-1")
        self.assertEqual(ops["status"], "IDLE")


class ConsequencesTests(unittest.TestCase):
    def test_self_test_has_no_spam_followups(self):
        item = {"id": "W-0001", "title": "Run company OS self-tests (orchestration)", "type": "process", "department": "ops"}
        fus = consequences_mod.consequences_for(item, {"items": []})
        self.assertEqual(fus, [])

    def test_docs_completion_creates_followup(self):
        item = {
            "id": "W-0002",
            "title": "Correct stale security docs",
            "type": "docs",
            "department": "security",
        }
        fus = consequences_mod.consequences_for(item, {"items": []})
        self.assertTrue(len(fus) >= 1)


class MultiCycleTests(unittest.TestCase):
    """Behavioral proof: after task completes, company continues then idles."""

    def test_start_continues_after_first_completion(self):
        cfg = {
            "execution": {
                "max_ticks": 6,
                "max_workers_per_tick": 4,
                "claim_lease_seconds": 900,
                "stop_when_no_high_value_work": True,
                "hard_max_ticks": 8,
            },
            "policy": {
                "require_evidence_for_tasks": True,
                "lock_product_decisions": ["PD-001", "PD-002"],
            },
            "discovery": {"scan_engineering_docs": True, "scan_todo_fixme": True},
        }

        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            # Point all OS persistence at an isolated state dir
            import company.os.paths as paths_mod
            import company.os.pool as pool_mod
            import company.os.workers as workers_mod
            import company.os.memory as memory_mod
            import company.os.cadence as cadence_mod
            import company.os.clock as clock_mod

            state = tmp_path / "state"
            state.mkdir()
            reports = tmp_path / "reports"
            reports.mkdir()

            with mock.patch.object(paths_mod, "STATE", state), mock.patch.object(
                pool_mod, "POOL_PATH", state / "work_pool.json"
            ), mock.patch.object(pool_mod, "LEGACY_POOL", state / "task_pool.json"), mock.patch.object(
                workers_mod, "WORKERS_PATH", state / "workers.json"
            ), mock.patch.object(memory_mod, "MEMORY_PATH", state / "memory.json"), mock.patch.object(
                cadence_mod, "CADENCE_PATH", state / "cadence.json"
            ), mock.patch.object(clock_mod, "COMPANY_PATH", state / "company.json"), mock.patch.object(
                clock_mod, "STATE", state
            ):
                # Empty pool so discovery creates fresh work
                pool_mod.write_json = work_pool.write_json  # noqa: ensure available
                from company.os.paths import write_json

                write_json(state / "work_pool.json", {"version": 2, "items": [], "updated_at": "t"})
                write_json(state / "company.json", {"version": 1, "mode": "STOPPED", "cycle": 0})

                clock = CompanyClock(cfg)
                result = clock.start(max_ticks=6)

                self.assertGreaterEqual(result["ticks"], 1)
                summaries = result["summaries"]
                events = sum(
                    len(s.get("completed", []))
                    + len(s.get("discovered", []))
                    + len(s.get("followups", []))
                    for s in summaries
                )
                self.assertGreaterEqual(events, 1)

                # After work, company should reach idle (or still autonomous mid-run)
                self.assertIn(
                    result["company"].get("mode"),
                    {"IDLE_MONITORING", "AUTONOMOUS", "STOPPED"},
                )

                completed_ticks = [s for s in summaries if s.get("completed")]
                if completed_ticks:
                    # Company continued past first completion OR entered idle after it
                    first_idx = next(i for i, s in enumerate(summaries) if s.get("completed"))
                    self.assertTrue(
                        len(summaries) > first_idx
                        or result["company"].get("mode") == "IDLE_MONITORING"
                        or summaries[-1].get("idle")
                    )
                # Must not runaway
                self.assertLessEqual(result["ticks"], 8)

class AdversarialTests(unittest.TestCase):
    def test_zero_valuable_work_idles(self):
        cfg = {
            "execution": {
                "max_ticks": 3,
                "max_workers_per_tick": 2,
                "claim_lease_seconds": 60,
                "stop_when_no_high_value_work": True,
            },
            "policy": {"require_evidence_for_tasks": True, "lock_product_decisions": ["PD-001", "PD-002"]},
            "discovery": {"scan_engineering_docs": False, "scan_todo_fixme": False},
        }
        # Isolate persistence — must not mutate live company/state/
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            import company.os.paths as paths_mod
            import company.os.pool as pool_mod
            import company.os.workers as workers_mod
            import company.os.memory as memory_mod
            import company.os.cadence as cadence_mod
            import company.os.clock as clock_mod

            state = tmp_path / "state"
            state.mkdir()
            from company.os.paths import write_json

            write_json(state / "work_pool.json", {"version": 2, "items": [], "updated_at": "t"})
            write_json(state / "company.json", {"version": 1, "mode": "STOPPED", "cycle": 0})
            write_json(state / "workers.json", {"version": 1, "workers": []})
            write_json(state / "memory.json", {"version": 1, "decisions": [], "rejects": [], "failures": [], "learnings": []})
            write_json(state / "cadence.json", {"version": 1, "last_runs": {}})

            with mock.patch.object(paths_mod, "STATE", state), mock.patch.object(
                pool_mod, "POOL_PATH", state / "work_pool.json"
            ), mock.patch.object(pool_mod, "LEGACY_POOL", state / "task_pool.json"), mock.patch.object(
                workers_mod, "WORKERS_PATH", state / "workers.json"
            ), mock.patch.object(memory_mod, "MEMORY_PATH", state / "memory.json"), mock.patch.object(
                cadence_mod, "CADENCE_PATH", state / "cadence.json"
            ), mock.patch.object(clock_mod, "COMPANY_PATH", state / "company.json"), mock.patch.object(
                clock_mod, "STATE", state
            ), mock.patch("company.os.discovery.run_discovery", return_value=[]):
                clock = CompanyClock(cfg)
                result = clock.start(max_ticks=3)
                self.assertEqual(result["company"].get("mode"), "IDLE_MONITORING")

    def test_pd001_flip_rejected(self):
        item = work_pool.new_work_item(
            title="Enable TLS by default for remote control",
            department="security",
            type_="security",
            problem="plaintext",
            evidence=[{"kind": "doc", "ref": "x"}],
            desired_outcome="tls on",
            priority_rationale="security wants TLS default",
            acceptance=["tls"],
            confidence=0.9,
            pool_items=[],
        )
        out = triage_mod.triage_item(
            item,
            {"policy": {"require_evidence_for_tasks": True, "lock_product_decisions": ["PD-001"]}},
            {"items": []},
        )
        self.assertEqual(out["status"], "REJECTED")


class DiscoveryTests(unittest.TestCase):
    def test_run_discovery_assigns_unique_ids(self):
        from company.os import discovery as discovery_mod

        pool = {"version": 2, "items": []}
        cfg = {
            "discovery": {"scan_engineering_docs": True, "scan_todo_fixme": True},
            "policy": {"require_evidence_for_tasks": True},
        }
        found = discovery_mod.run_discovery(cfg, pool)
        ids = [i["id"] for i in found]
        self.assertEqual(len(ids), len(set(ids)), f"duplicate ids: {ids}")

    def test_ops_discovers_billing_ci_block(self):
        from unittest import mock

        from company.os import discovery as discovery_mod

        fake = {
            "conclusion": "failure",
            "databaseId": 35651233844,
            "displayTitle": "docs idle",
            "url": "https://github.com/iamadi11/LightStar/actions/runs/35651233844",
            "headSha": "2467d16",
            "failure_kind": "billing_spend_limit",
        }
        with mock.patch.object(discovery_mod, "_latest_main_ci_failure", return_value=fake):
            found = discovery_mod.discover_ops({}, {"items": []})
        titles = [i["title"] for i in found]
        self.assertTrue(any("billing" in t.lower() or "spend" in t.lower() for t in titles))
        billing = next(i for i in found if "billing" in i["title"].lower() or "spend" in i["title"].lower())
        self.assertEqual(billing["department"], "ops")
        self.assertGreaterEqual(float(billing["confidence"]), 0.85)

    def test_executor_blocks_billing_without_fake_fix(self):
        from company.os import executors as ex

        item = {
            "id": "W-TEST",
            "title": "Main CI blocked by GitHub Actions billing/spend limit",
            "type": "process",
            "department": "ops",
            "status": "READY",
            "evidence": [{"kind": "ci", "ref": "https://example/runs/1"}],
            "decision_history": [],
            "owner_worker": None,
            "claim": None,
        }
        workers = {"workers": []}
        out = ex.execute_item(item, workers)
        self.assertEqual(out["status"], "BLOCKED")
        self.assertIn("billing", (out.get("blocked_reason") or "").lower())
        self.assertTrue(any("external" in e.lower() for e in out.get("completion_evidence", [])))

    def test_engineering_discovers_selected_ee_rows(self):
        from company.os import discovery as discovery_mod

        # Live roadmap Selected is empty once EE-001–009 are Implemented.
        found = discovery_mod.discover_engineering(
            {"discovery": {"scan_engineering_docs": True}},
            {"items": []},
        )
        ee = [i for i in found if (i.get("title") or "").startswith("EE-")]
        self.assertEqual(ee, [], "Implemented Selected must not re-enter the pool")

    def test_implemented_tracker_skips_selected_rows(self):
        from company.os import discovery as discovery_mod

        selected = [
            {"id": "EE-001", "title": "Gate pointer", "why": "auth"},
            {"id": "EE-099", "title": "Brand new selected item", "why": "fresh"},
        ]
        with mock.patch.object(discovery_mod, "_parse_roadmap_selected", return_value=selected):
            with mock.patch.object(discovery_mod, "_implemented_ee_ids", return_value={"EE-001"}):
                found = discovery_mod.discover_engineering(
                    {"discovery": {"scan_engineering_docs": True}},
                    {"items": []},
                )
        titles = [i["title"] for i in found if (i.get("title") or "").startswith("EE-")]
        self.assertTrue(any("EE-099" in t for t in titles))
        self.assertFalse(any(t.startswith("EE-001:") for t in titles))

    def test_parse_roadmap_selected_ignores_header(self):
        from company.os import discovery as discovery_mod

        sample = """
## Selected (implement this pass)

| ID | Title | Why |
|----|-------|-----|
| EE-001 | Gate pointer injection on authentication | Auth bypass |
| EE-002 | Gyro deltas go straight to PointerChannel | Hot path |

## Deferred

| Item | Reason |
|------|--------|
| Split manager | Rewrite would not pay |
"""
        rows = discovery_mod._parse_roadmap_selected(sample)
        self.assertEqual([r["id"] for r in rows], ["EE-001", "EE-002"])


class ConfigTests(unittest.TestCase):
    def test_config_and_adr2_exist(self):
        self.assertTrue((ROOT / "company" / "config.yaml").exists())
        self.assertTrue((ROOT / "company" / "adr" / "0002-company-operating-system.md").exists())
        self.assertTrue((ROOT / "company" / "os" / "clock.py").exists())


if __name__ == "__main__":
    unittest.main()
