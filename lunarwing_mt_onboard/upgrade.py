"""In-place upgrade orchestration: wrapper around ``upgrade-tenant-version.sh``.

``UpgradeConfig`` captures every choice for upgrading an existing tenant in
place (tenant name, target version, source override, preflight/force flags)
and serializes to/from JSON so an upgrade session can be saved and resumed.

The wrapper defaults to *dry-run* (``apply=False``) - operators must opt in
with ``--apply``/``apply=True`` to mutate the tenant.
"""

from __future__ import annotations

import json
import os
import re
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

UPGRADE_SCRIPT = os.environ.get(
    "LUNARWING_UPGRADE_SCRIPT",
    os.path.join(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
        "ic",
        "scripts",
        "upgrade-tenant-version.sh",
    ),
)

PREFLIGHT_SCRIPT = os.environ.get(
    "LUNARWING_PREFLIGHT_SCRIPT",
    os.path.join(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
        "ic",
        "scripts",
        "upgrade-preflight.sh",
    ),
)

_TARGET_TAG_RE = re.compile(r"^v\d+\.\d+\.\d+$")
UpgradeValue = str | bool


def validate_target_tag(tag: str) -> str | None:
    """Return an error message if *tag* is invalid, ``None`` if OK.

    Empty *tag* is accepted (operator will rely on the script's built-in
    resolution). Branches (``main``) and pre-releases (``v1.1.9-rc1``) are
    rejected; in-place upgrades must target an exact release tag.
    """
    if not tag:
        return None
    if _TARGET_TAG_RE.match(tag):
        return None
    return (
        "target tag must be an exact release like v1.1.9 "
        "(no branches or pre-releases)"
    )


class UpgradeConfigFormatError(Exception):
    pass


@dataclass
class UpgradeConfig:
    """All parameters for an in-place tenant upgrade."""

    tenant: str = ""
    target: str = ""
    apply: bool = False
    auto_yes: bool = False
    force: bool = False
    source_version_override: str = ""
    run_preflight: bool = True

    # ------------------------------------------------------------------
    # Validation
    # ------------------------------------------------------------------

    @staticmethod
    def validate_target_tag(tag: str) -> str | None:
        """Return an error message if *tag* is invalid, ``None`` if OK."""
        return validate_target_tag(tag)

    def validate(self) -> str | None:
        """Return an error message if this config is invalid, ``None`` if OK."""
        err = TenantConfig.validate_name(self.tenant)
        if err:
            return err
        err = validate_target_tag(self.target)
        if err:
            return err
        return validate_target_tag(self.source_version_override)

    # ------------------------------------------------------------------
    # Serialization
    # ------------------------------------------------------------------

    def to_dict(self) -> dict[str, UpgradeValue]:
        """Return a plain ``dict`` suitable for JSON dumps."""
        return {
            "tenant": self.tenant,
            "target": self.target,
            "apply": self.apply,
            "auto_yes": self.auto_yes,
            "force": self.force,
            "source_version_override": self.source_version_override,
            "run_preflight": self.run_preflight,
        }

    def to_json(self, path: str | Path) -> None:
        """Write this config to *path* as JSON with 0600 at creation time."""
        p = Path(path)
        fd = os.open(str(p), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as f:
            _ = f.write(json.dumps(self.to_dict(), indent=2) + "\n")

    @classmethod
    def from_dict(cls, data: dict[str, UpgradeValue]) -> UpgradeConfig:
        """Reconstruct a config from a deserialized dict."""
        return cls(
            tenant=_str_value(data.get("tenant", "")),
            target=_str_value(data.get("target", "")),
            apply=_bool_value(data.get("apply", False)),
            auto_yes=_bool_value(data.get("auto_yes", False)),
            force=_bool_value(data.get("force", False)),
            source_version_override=_str_value(data.get("source_version_override", "")),
            run_preflight=_bool_value(data.get("run_preflight", True)),
        )

    @classmethod
    def from_json(cls, path: str | Path) -> UpgradeConfig:
        """Load a config previously written by :meth:`to_json`."""
        raw: UpgradeJson = json.loads(Path(path).read_text())
        if not isinstance(raw, dict):
            raise UpgradeConfigFormatError("upgrade config JSON must be an object")
        data: dict[str, UpgradeValue] = {}
        for key, value in raw.items():
            if isinstance(key, str) and isinstance(value, (str, bool)):
                data[key] = value
        return cls.from_dict(data)


def _str_value(value: UpgradeValue) -> str:
    return value if isinstance(value, str) else ""


def _bool_value(value: UpgradeValue) -> bool:
    return value if isinstance(value, bool) else False


# Script resolution ----------------------------------------------------------


def ensure_upgrade_script() -> str:
    """Return the upgrade-script path, raising if not found."""
    if os.path.isfile(UPGRADE_SCRIPT) and os.access(UPGRADE_SCRIPT, os.X_OK):
        return UPGRADE_SCRIPT
    found = shutil.which("upgrade-tenant-version.sh")
    if found:
        return found
    raise FileNotFoundError(
        f"upgrade-tenant-version.sh not found at {UPGRADE_SCRIPT}. Set LUNARWING_UPGRADE_SCRIPT env var."
    )


def ensure_preflight_script() -> str:
    """Return the preflight-script path, raising if not found."""
    if os.path.isfile(PREFLIGHT_SCRIPT) and os.access(PREFLIGHT_SCRIPT, os.X_OK):
        return PREFLIGHT_SCRIPT
    found = shutil.which("upgrade-preflight.sh")
    if found:
        return found
    raise FileNotFoundError(
        f"upgrade-preflight.sh not found at {PREFLIGHT_SCRIPT}. Set LUNARWING_PREFLIGHT_SCRIPT env var."
    )


# Argv builders --------------------------------------------------------------


def build_preflight_args(cfg: UpgradeConfig) -> list[str]:
    """Construct the argv list for ``upgrade-preflight.sh``."""
    script = ensure_preflight_script()
    return [script, cfg.tenant]


def build_upgrade_args(cfg: UpgradeConfig) -> list[str]:
    """Construct the argv list for ``upgrade-tenant-version.sh``.

    ``--apply`` is omitted by default (dry-run). Only included when
    ``cfg.apply`` is true.
    """
    script = ensure_upgrade_script()
    args: list[str] = [script, cfg.tenant]
    if cfg.apply:
        args.append("--apply")
    if cfg.target:
        args.extend(["--target", cfg.target])
    if cfg.source_version_override:
        args.extend(["--source-version-override", cfg.source_version_override])
    if cfg.force:
        args.append("--force")
    if cfg.auto_yes:
        args.append("--yes")
    return args


# Run helpers ----------------------------------------------------------------


def run_preflight(
    cfg: UpgradeConfig,
    *,
    on_output: Callable[[str], None] | None = None,
) -> PhaseResult:
    """Run the preflight script for *cfg* and return a single PhaseResult."""
    return run_command(build_preflight_args(cfg), on_output=on_output)


def run_upgrade(
    cfg: UpgradeConfig,
    *,
    on_output: Callable[[str], None] | None = None,
) -> ProvisionResult:
    """Run preflight (if enabled) then the upgrade, returning aggregate result.

    When ``cfg.run_preflight`` is true, the preflight runs first. If preflight
    fails and ``cfg.force`` is false, the run stops before the upgrade. When
    ``cfg.force`` is true, a failed preflight is logged but the upgrade
    proceeds anyway.
    """
    result = ProvisionResult()

    if cfg.run_preflight:
        preflight = run_preflight(cfg, on_output=on_output)
        result.phases.append(preflight)
        if not preflight.ok and not cfg.force:
            return result

    upgrade = run_command(build_upgrade_args(cfg), on_output=on_output)
    result.phases.append(upgrade)
    return result


UpgradeJson = dict[str, str | bool] | list[str | bool] | str | bool | int | float | None
