"""Kawarimi export orchestration: wrapper around ``export-tenant.sh``.

``ExportConfig`` captures every choice for exporting (migrating) a tenant
off the current host.  Serializes to/from JSON so an export session can be
saved and resumed.

Defaults to dry-run (``apply=False``) — operators must opt in with
``--apply``/``apply=True`` to actually stop the tenant and write the bundle.
"""

from __future__ import annotations

import json
import os
import shutil
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path

from lunarwing_mt_onboard.config import TenantConfig
from lunarwing_mt_onboard.provisioner import (
    PhaseResult,
    ProvisionResult,
    run_command,
)

EXPORT_SCRIPT = os.environ.get(
    "LUNARWING_EXPORT_SCRIPT",
    os.path.join(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
        "ic",
        "scripts",
        "export-tenant.sh",
    ),
)

DEFAULT_OUT_DIR = "/var/lib/lunarwing-migrate"

ExportValue = str | bool


class ExportConfigFormatError(Exception):
    pass


@dataclass
class ExportConfig:
    """All parameters for a Kawarimi tenant export."""

    tenant: str = ""
    out_dir: str = DEFAULT_OUT_DIR
    apply: bool = False
    no_quiesce: bool = False

    def validate(self) -> str | None:
        err = TenantConfig.validate_name(self.tenant)
        if err:
            return err
        if not self.out_dir:
            return "output directory must not be empty"
        return None

    def to_dict(self) -> dict[str, ExportValue]:
        return {
            "tenant": self.tenant,
            "out_dir": self.out_dir,
            "apply": self.apply,
            "no_quiesce": self.no_quiesce,
        }

    def to_json(self, path: str | Path) -> None:
        p = Path(path)
        fd = os.open(str(p), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as f:
            _ = f.write(json.dumps(self.to_dict(), indent=2) + "\n")

    @classmethod
    def from_dict(cls, data: dict[str, ExportValue]) -> ExportConfig:
        return cls(
            tenant=_str_value(data.get("tenant", "")),
            out_dir=_str_value(data.get("out_dir", DEFAULT_OUT_DIR)),
            apply=_bool_value(data.get("apply", False)),
            no_quiesce=_bool_value(data.get("no_quiesce", False)),
        )

    @classmethod
    def from_json(cls, path: str | Path) -> ExportConfig:
        raw: ExportJson = json.loads(Path(path).read_text())
        if not isinstance(raw, dict):
            raise ExportConfigFormatError("export config JSON must be an object")
        data: dict[str, ExportValue] = {}
        for key, value in raw.items():
            if isinstance(key, str) and isinstance(value, (str, bool)):
                data[key] = value
        return cls.from_dict(data)


def _str_value(value: ExportValue) -> str:
    return value if isinstance(value, str) else ""


def _bool_value(value: ExportValue) -> bool:
    return value if isinstance(value, bool) else False


def ensure_export_script() -> str:
    if os.path.isfile(EXPORT_SCRIPT) and os.access(EXPORT_SCRIPT, os.X_OK):
        return EXPORT_SCRIPT
    found = shutil.which("export-tenant.sh")
    if found:
        return found
    raise FileNotFoundError(
        f"export-tenant.sh not found at {EXPORT_SCRIPT}. Set LUNARWING_EXPORT_SCRIPT env var."
    )


def build_export_args(cfg: ExportConfig) -> list[str]:
    script = ensure_export_script()
    args: list[str] = [script, cfg.tenant]
    if cfg.out_dir:
        args.extend(["--out-dir", cfg.out_dir])
    if cfg.no_quiesce:
        args.append("--no-quiesce")
    if not cfg.apply:
        args.append("--dry-run")
    return args


def run_export(
    cfg: ExportConfig,
    *,
    on_output: Callable[[str], None] | None = None,
) -> ProvisionResult:
    result = ProvisionResult()
    export = run_command(
        build_export_args(cfg),
        on_output=on_output,
        phase_name="export",
    )
    result.phases.append(export)
    return result


ExportJson = dict[str, str | bool] | list[str | bool] | str | bool | int | float | None
