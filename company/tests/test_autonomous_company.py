"""Backward-compat smoke tests (v1 helpers removed; Company OS is canonical). """

from __future__ import annotations

import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from company.os import pool as work_pool
from company.os import triage as triage_mod


class LegacyCompatTests(unittest.TestCase):
    def test_duplicate_fingerprint_rejected_on_triage(self):
        existing = work_pool.new_work_item(
            title="Run company OS self-tests (orchestration)",
            department="ops",
            type_="process",
            problem="x",
            evidence=[{"kind": "repo", "ref": "company/tests"}],
            desired_outcome="ok",
            priority_rationale="integrity gate for company tooling",
            acceptance=["ok"],
            confidence=0.9,
            pool_items=[],
        )
        existing["status"] = "READY"
        dup = work_pool.new_work_item(
            title="Run company OS self-tests (orchestration)",
            department="ops",
            type_="process",
            problem="x",
            evidence=[{"kind": "repo", "ref": "company/tests"}],
            desired_outcome="ok",
            priority_rationale="integrity gate for company tooling",
            acceptance=["ok"],
            confidence=0.9,
            pool_items=[existing],
        )
        out = triage_mod.triage_item(
            dup,
            {"policy": {"require_evidence_for_tasks": True}},
            {"items": [existing]},
        )
        self.assertEqual(out["status"], "REJECTED")

    def test_config_exists(self):
        self.assertTrue((ROOT / "company" / "config.yaml").exists())


if __name__ == "__main__":
    unittest.main()
