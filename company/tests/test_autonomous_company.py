#!/usr/bin/env python3
"""Unit tests for autonomous-company discovery/prioritization helpers."""

from __future__ import annotations

import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "company" / "cli.py"


def load_module():
    spec = importlib.util.spec_from_file_location("autonomous_company", SCRIPT)
    assert spec and spec.loader
    mod = importlib.util.module_from_spec(spec)
    sys.modules["autonomous_company"] = mod
    spec.loader.exec_module(mod)
    return mod


class AutonomousCompanyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.mod = load_module()

    def test_next_task_id_increments(self):
        tid = self.mod.next_task_id([{"id": "T-0001"}, {"id": "T-0007"}])
        self.assertEqual(tid, "T-0008")

    def test_prioritize_skips_duplicate_titles(self):
        hit = self.mod.DiscoveryHit(
            title="Run autonomous-company self-tests",
            category="process",
            evidence=[{"kind": "repo", "ref": "company/tests"}],
            priority_rationale="x" * 25,
            acceptance=["ok"],
        )
        existing = [{"id": "T-0001", "title": hit.title, "status": "proposed"}]
        out = self.mod.prioritize([hit], existing, max_tasks=5)
        self.assertEqual(out, [])

    def test_prioritize_skips_done_titles(self):
        hit = self.mod.DiscoveryHit(
            title="Run autonomous-company self-tests",
            category="process",
            evidence=[{"kind": "repo", "ref": "company/tests"}],
            priority_rationale="x" * 25,
            acceptance=["ok"],
        )
        existing = [{"id": "T-0002", "title": hit.title, "status": "done"}]
        out = self.mod.prioritize([hit], existing, max_tasks=5)
        self.assertEqual(out, [])

    def test_challenge_rejects_missing_evidence(self):
        task = {
            "id": "T-0001",
            "title": "Something vague enough to pass length",
            "status": "proposed",
            "category": "docs",
            "evidence": [],
            "priority_rationale": "not enough evidence really",
        }
        cfg = {"policy": {"require_evidence_for_tasks": True}}
        out = self.mod.challenge_task(task, cfg)
        self.assertEqual(out["status"], "rejected")

    def test_challenge_defers_debt_without_capacity_claim(self):
        task = {
            "id": "T-0002",
            "title": "Triage TODO markers",
            "status": "proposed",
            "category": "debt",
            "evidence": [{"kind": "repo", "ref": "x"}],
            "priority_rationale": "markers exist but need triage discipline here",
        }
        out = self.mod.challenge_task(task, {"policy": {"require_evidence_for_tasks": True}})
        self.assertEqual(out["status"], "deferred")

    def test_discover_returns_list(self):
        cfg = load_module().load_yaml(ROOT / "company" / "config.yaml") if False else {
            "discovery": {
                "scan_engineering_docs": True,
                "scan_todo_fixme": True,
                "scan_agents_md": True,
            }
        }
        # Use real discover against repo
        hits = self.mod.discover(cfg)
        self.assertIsInstance(hits, list)
        self.assertTrue(any("self-tests" in h.title.lower() for h in hits))

    def test_config_exists(self):
        self.assertTrue((ROOT / "company" / "config.yaml").exists())
        self.assertTrue((ROOT / "company" / "adr" / "0001-autonomous-company-architecture.md").exists())


if __name__ == "__main__":
    unittest.main()
