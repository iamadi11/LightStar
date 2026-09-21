"""LightStar Company Operating System — package root."""

from company.os.clock import CompanyClock
from company.os.dashboard import render_status

__all__ = ["CompanyClock", "render_status"]
