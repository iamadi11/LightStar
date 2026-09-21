"""Shared paths and JSON helpers for the Company OS."""

from __future__ import annotations

import json
import os
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

# Repo root: company/os/paths.py → parents[2]
ROOT = Path(__file__).resolve().parents[2]
COMPANY = ROOT / "company"
STATE = COMPANY / "state"
DEFAULT_CONFIG = COMPANY / "config.yaml"


def utc_now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


def read_json(path: Path, default: Any) -> Any:
    if not path.exists():
        return default
    with path.open() as f:
        return json.load(f)


def write_json(path: Path, data: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(dir=str(path.parent), prefix=path.name + ".", suffix=".tmp")
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(data, f, indent=2, sort_keys=True)
            f.write("\n")
        Path(tmp_name).replace(path)
    except Exception:
        try:
            os.unlink(tmp_name)
        except OSError:
            pass
        raise


def ensure_state_dirs() -> None:
    STATE.mkdir(parents=True, exist_ok=True)
    (STATE / "work_orders").mkdir(parents=True, exist_ok=True)
    (COMPANY / "reports").mkdir(parents=True, exist_ok=True)
    (COMPANY / "memory").mkdir(parents=True, exist_ok=True)
