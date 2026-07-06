"""Post-start health verification for a freshly provisioned tenant."""

from __future__ import annotations

import socket
import subprocess
import time
from dataclasses import dataclass

DEFAULT_TIMEOUT = 90
POLL_INTERVAL = 3


@dataclass
class CheckResult:
    label: str
    ok: bool
    detail: str = ""


def check_port(host: str, port: int, timeout: float = 5.0) -> CheckResult:
    """Return a CheckResult for a TCP port reachability test."""
    try:
        with socket.create_connection((host, int(port)), timeout=timeout):
            return CheckResult(f"port {port}", True)
    except OSError as exc:
        return CheckResult(f"port {port}", False, str(exc))


def check_service_status(tenant: str) -> CheckResult:
    """Return a CheckResult for the tenant's service unit status."""
    unit = f"lunarwing-{tenant}"
    try:
        result = subprocess.run(
            ["systemctl", "is-active", unit],
            capture_output=True,
            text=True,
            timeout=10,
        )
    except FileNotFoundError:
        try:
            result = subprocess.run(
                ["rc-service", unit, "status"],
                capture_output=True,
                text=True,
                timeout=10,
            )
            started = "started" in result.stdout.lower()
            return CheckResult(
                f"service {unit}",
                started and result.returncode == 0,
                result.stdout.strip()[:200],
            )
        except (OSError, subprocess.SubprocessError) as exc:
            return CheckResult(f"service {unit}", False, str(exc))
    except (OSError, subprocess.SubprocessError) as exc:
        return CheckResult(f"service {unit}", False, str(exc))

    active = result.stdout.strip() == "active"
    return CheckResult(
        f"service {unit}", active, result.stdout.strip()[:200]
    )


def verify_tenant(
    tenant: str,
    host: str = "127.0.0.1",
    port: int = 0,
    *,
    timeout: int = DEFAULT_TIMEOUT,
) -> list[CheckResult]:
    """Poll the gateway port and service status until healthy or *timeout*.

    Returns a list of CheckResult items for display.
    """
    results: list[CheckResult] = []
    deadline = time.monotonic() + timeout

    while time.monotonic() < deadline:
        results.clear()
        if port:
            results.append(check_port(host, port))
        results.append(check_service_status(tenant))
        if all(r.ok for r in results):
            return results
        time.sleep(POLL_INTERVAL)

    return results
