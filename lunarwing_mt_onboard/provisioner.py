"""Provisioning orchestration: subprocess wrapper around ``lunarwing-mt-admin.sh``.

Each phase (add-tenant, build-tenant, start-tenant) runs as a single
subprocess, streaming merged stdout/stderr back to the caller via a
callback so callers can render live output via ``rich.live.Live``.
"""

from __future__ import annotations

import os
import shutil
import subprocess
from collections.abc import Callable
from dataclasses import dataclass, field

# ``lunarwing-mt-admin.sh`` lives next to the main LunarWing repo tree.
MT_ADMIN_SCRIPT = os.environ.get(
    "LUNARWING_MT_ADMIN",
    os.path.join(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
        "ic",
        "scripts",
        "lunarwing-mt-admin.sh",
    ),
)


@dataclass
class PhaseResult:
    """Outcome of a single provisioning phase."""

    name: str
    returncode: int
    stdout: str = ""
    stderr: str = ""

    @property
    def ok(self) -> bool:
        return self.returncode == 0


@dataclass
class ProvisionResult:
    """Aggregate result for an entire provisioning run."""

    phases: list[PhaseResult] = field(default_factory=list)

    @property
    def ok(self) -> bool:
        return all(p.ok for p in self.phases)

    def summary(self) -> list[tuple[str, bool, int]]:
        """Return [(phase_name, ok, returncode)] for display."""
        return [(p.name, p.ok, p.returncode) for p in self.phases]


# Low-level runner ----------------------------------------------------------


def _run(
    args: list[str],
    *,
    env: dict[str, str] | None = None,
    on_output: Callable[[str], None] | None = None,
) -> PhaseResult:
    """Execute *args* merged stdout→stderr, calling *on_output* per line.

    Returns a PhaseResult with merged stdout+stderr and the return code.
    """
    merged_env = os.environ.copy()
    if env:
        merged_env.update(env)

    proc = subprocess.Popen(
        args,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        env=merged_env,
        bufsize=1,
    )

    lines: list[str] = []
    try:
        assert proc.stdout is not None
        for line in proc.stdout:
            line = line.rstrip("\n")
            lines.append(line)
            if on_output:
                on_output(line)
        proc.wait()
    finally:
        if proc.poll() is None:
            proc.terminate()
            proc.wait()

    return PhaseResult(
        name=args[1] if len(args) > 1 else args[0],
        returncode=proc.returncode,
        stdout="\n".join(lines),
    )


def ensure_mt_admin() -> str:
    """Return the mt-admin.sh path, raising if not found."""
    if os.path.isfile(MT_ADMIN_SCRIPT) and os.access(MT_ADMIN_SCRIPT, os.X_OK):
        return MT_ADMIN_SCRIPT
    found = shutil.which("lunarwing-mt-admin.sh")
    if found:
        return found
    raise FileNotFoundError(
        f"lunarwing-mt-admin.sh not found at {MT_ADMIN_SCRIPT}. "
        "Set LUNARWING_MT_ADMIN env var."
    )


def build_add_tenant_args(config: "TenantConfig") -> list[str]:
    """Construct the argv list for ``mt-admin add-tenant``."""
    script = ensure_mt_admin()
    args: list[str] = [script, "add-tenant", config.name]

    if config.docker_group:
        args.append("--docker-group")
    if config.gateway_host and config.gateway_host != "127.0.0.1":
        args.extend(["--gateway-host", config.gateway_host])
    if config.xmpp_enabled and config.xmpp_jid:
        args.extend(["--xmpp-jid", config.xmpp_jid])
        if config.xmpp_password:
            args.extend(["--xmpp-password", config.xmpp_password])
        if config.xmpp_allow_from:
            args.extend(["--xmpp-allow-from", ",".join(config.xmpp_allow_from)])
    if config.gotify_enabled and config.gotify_url:
        args.extend(["--gotify-url", config.gotify_url])
        if config.gotify_title:
            args.extend(["--gotify-title", config.gotify_title])
    if config.tensorzero_url:
        args.extend(["--tensorzero-url", config.tensorzero_url])
    if config.llm_api_key:
        args.extend(["--llm-api-key", config.llm_api_key])
    if config.llm_model:
        args.extend(["--llm-model", config.llm_model])
    if config.enable_darkirc:
        args.append("--enable-darkirc")
    if config.no_ssh:
        args.append("--no-ssh")
    if config.no_health:
        args.append("--no-health")
    return args


def build_build_tenant_args(config: "TenantConfig") -> list[str]:
    """Construct the argv list for ``mt-admin build-tenant``."""
    script = ensure_mt_admin()
    args: list[str] = [script, "build-tenant", config.name, "--with-wasm"]
    if WorkerType.NANOCODE in config.workers:
        args.append("--with-nanocode")
    if WorkerType.PEBBLE in config.workers:
        args.append("--with-pebble")
    if WorkerType.OPENCODE in config.workers:
        args.append("--with-opencode")
    if config.toolchains:
        args.append("--with-toolchains")
    return args


def build_start_tenant_args(config: "TenantConfig") -> list[str]:
    """Construct the argv list for ``mt-admin start-tenant``."""
    script = ensure_mt_admin()
    return [script, "start-tenant", config.name]




def provision(
    config: "TenantConfig",
    *,
    on_output: Callable[[str], None] | None = None,
    skip_build: bool = False,
    skip_start: bool = False,
) -> ProvisionResult:
    """Run add-tenant -> build-tenant -> start-tenant and return results.

    *on_output* is called for every line of merged output across all phases.
    If a phase fails, the run stops immediately and returns the partial result.
    """
    result = ProvisionResult()

    add_args = build_add_tenant_args(config)
    result.phases.append(_run(add_args, on_output=on_output))
    if not result.phases[-1].ok:
        return result

    if not skip_build:
        build_args = build_build_tenant_args(config)
        result.phases.append(_run(build_args, on_output=on_output))
        if not result.phases[-1].ok:
            return result

    if not skip_start:
        start_args = build_start_tenant_args(config)
        result.phases.append(_run(start_args, on_output=on_output))

    return result


# Late import to avoid circular dependency at module load time
from lunarwing_mt_onboard.config import TenantConfig, WorkerType  # noqa: E402
