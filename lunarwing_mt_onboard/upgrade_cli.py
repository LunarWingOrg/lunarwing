from __future__ import annotations

import argparse
from dataclasses import dataclass

from rich.console import Console
from rich.panel import Panel
from rich.table import Table
from rich.text import Text

from lunarwing_mt_onboard.config import TenantConfig
from lunarwing_mt_onboard.provisioner import ProvisionResult
from lunarwing_mt_onboard.upgrade import (
    UpgradeConfig,
    ensure_preflight_script,
    ensure_upgrade_script,
    run_upgrade,
)
from lunarwing_mt_onboard.verify import CheckResult, verify_tenant

console = Console()


@dataclass(frozen=True, slots=True)
class UpgradeCliArgs:
    tenant: str | None = None
    target: str = ""
    source_version_override: str = ""
    apply: bool = False
    yes: bool = False
    force: bool = False
    no_preflight: bool = False
    non_interactive: bool = False
    accept_defaults: bool = False
    resume: str | None = None
    save: str | None = None

    @classmethod
    def from_namespace(cls, args: argparse.Namespace) -> UpgradeCliArgs:
        return cls(
            tenant=_optional_str(getattr(args, "tenant", None)),
            target=_str_arg(getattr(args, "target", "")),
            source_version_override=_str_arg(getattr(args, "source_version_override", "")),
            apply=_bool_arg(getattr(args, "apply", False)),
            yes=_bool_arg(getattr(args, "yes", False)),
            force=_bool_arg(getattr(args, "force", False)),
            no_preflight=_bool_arg(getattr(args, "no_preflight", False)),
            non_interactive=_bool_arg(getattr(args, "non_interactive", False)),
            accept_defaults=_bool_arg(getattr(args, "accept_defaults", False)),
            resume=_optional_str(getattr(args, "resume", None)),
            save=_optional_str(getattr(args, "save", None)),
        )


def _str_arg(value: str | bool | None) -> str:
    return value if isinstance(value, str) else ""


def _optional_str(value: str | bool | None) -> str | None:
    return value if isinstance(value, str) else None


def _bool_arg(value: str | bool | None) -> bool:
    return value if isinstance(value, bool) else False


def _q_text(label: str, *, default: str = "") -> str:
    try:
        import questionary

        result = questionary.text(label, default=default).ask()
        if result is None:
            raise KeyboardInterrupt
        return str(result)
    except KeyboardInterrupt:
        raise
    except Exception:
        prompt = f"{label}: " if not default else f"{label} [{default}]: "
        raw = input(prompt).strip()
        return raw or default


def _q_confirm(label: str, *, default: bool = False) -> bool:
    try:
        import questionary

        answer = questionary.confirm(label, default=default).ask()
        if answer is None:
            raise KeyboardInterrupt
        return bool(answer)
    except KeyboardInterrupt:
        raise
    except Exception:
        suffix = " [Y/n]" if default else " [y/N]"
        raw = input(f"{label}{suffix}: ").strip().lower()
        if not raw:
            return default
        return raw in ("y", "yes")


def gather_upgrade_config(config: UpgradeConfig) -> UpgradeConfig:
    console.print(
        Panel.fit(
                Text(
                (
                    "LunarWing In-Place Tenant Upgrade\n================================\n"
                    "Upgrades an existing tenant in place using the bundled\nupgrade-tenant-version.sh wrapper. "
                    "Defaults to dry-run;\npass --apply to actually mutate the tenant.\n"
                ),
                style="bold",
            ),
            title="lunarwing-mt-upgrade",
            border_style="yellow",
        )
    )

    tenant = _q_text("Tenant name (lowercase, e.g. 'sphinx')", default=config.tenant)
    err = TenantConfig.validate_name(tenant)
    while err:
        console.print(f"[red]{err}[/]")
        tenant = _q_text("Tenant name", default=config.tenant)
        err = TenantConfig.validate_name(tenant)
    config.tenant = tenant

    target = _q_text(
        "Target tag (exact release like v1.1.9; empty uses script default)",
        default=config.target,
    )
    while True:
        ferr = UpgradeConfig.validate_target_tag(target)
        if ferr is None:
            break
        console.print(f"[red]{ferr}[/]")
        target = _q_text("Target tag")
    config.target = target

    config.source_version_override = _q_text(
        "Source version override (empty skips)",
        default=config.source_version_override,
    )
    while True:
        ferr = UpgradeConfig.validate_target_tag(config.source_version_override)
        if ferr is None:
            break
        console.print(f"[red]{ferr}[/]")
        config.source_version_override = _q_text("Source version override")
    config.run_preflight = _q_confirm(
        "Run preflight before upgrade?", default=config.run_preflight
    )
    config.apply = _q_confirm(
        "Apply changes? (no = dry-run)", default=config.apply
    )
    if config.apply:
        config.auto_yes = _q_confirm(
            "Auto-confirm (--yes)?", default=config.auto_yes
        )
    config.force = _q_confirm(
        "Continue even if preflight fails (--force)?", default=config.force
    )

    return config


def _show_upgrade_summary(config: UpgradeConfig) -> bool:
    """Render a summary table and prompt for confirmation."""
    table = Table(
        title=f"Upgrade summary: {config.tenant}",
        show_lines=True,
    )
    table.add_column("Field", style="bold cyan")
    table.add_column("Value", style="white")
    table.add_row("Tenant", config.tenant)
    table.add_row(
        "Target tag",
        config.target if config.target else "script default",
    )
    table.add_row(
        "Source version override",
        config.source_version_override or "(none)",
    )
    table.add_row("Preflight", "yes" if config.run_preflight else "no")
    table.add_row("Force", "yes" if config.force else "no")
    table.add_row(
        "Mode",
        "APPLY" if config.apply else "DRY-RUN",
    )
    console.print(table)
    return _q_confirm("Proceed with upgrade?", default=True)


def _display_upgrade_results(result: ProvisionResult) -> None:
    """Mirror ``cli._display_results`` for upgrade results."""
    table = Table(title="Upgrade result")
    table.add_column("Phase", style="bold cyan")
    table.add_column("Status", justify="center")
    table.add_column("Code", justify="right")
    for name, ok, code in result.summary():
        status_text = Text("OK", style="green") if ok else Text("FAIL", style="red")
        table.add_row(name, status_text, str(code))
    console.print(table)
    console.print(
        "Upgrade completed successfully." if result.ok else "Upgrade FAILED.",
        style="bold green" if result.ok else "bold red",
    )


def _show_verify(results: list[CheckResult]) -> None:
    table = Table(title="Post-upgrade verification")
    table.add_column("Check", style="bold cyan")
    table.add_column("Status", justify="center")
    for check in results:
        status = Text("PASS", style="green") if check.ok else Text("FAIL", style="red")
        table.add_row(check.label, status)
    console.print(table)


def run_upgrade_flow(args: UpgradeCliArgs) -> int:
    config = UpgradeConfig()
    if args.resume:
        try:
            config = UpgradeConfig.from_json(args.resume)
        except Exception as exc:
            console.print(f"[red]Failed to load --resume file:[/] {exc}")
            return 1
    elif not (args.non_interactive or args.accept_defaults):
        try:
            config = gather_upgrade_config(config)
        except KeyboardInterrupt:
            console.print("\nAborted.")
            return 130

    # Overlay CLI flags onto the config
    if args.tenant:
        config.tenant = args.tenant
    if args.target:
        config.target = args.target
    if args.source_version_override:
        config.source_version_override = args.source_version_override
    if args.apply:
        config.apply = args.apply
    if args.yes:
        config.auto_yes = args.yes
    if args.force:
        config.force = args.force
    if args.no_preflight:
        config.run_preflight = not args.no_preflight

    err = config.validate()
    if err:
        console.print(f"[red]Invalid config:[/] {err}")
        return 1

    try:
        _ = ensure_upgrade_script()
        if config.run_preflight:
            _ = ensure_preflight_script()
    except FileNotFoundError as exc:
        console.print(f"[red]{exc}[/]")
        return 1

    if args.save:
        config.to_json(args.save)
        console.print(f"Saved config to [cyan]{args.save}[/]")

    if not config.apply:
        console.print(
            Panel.fit(
                Text(
                    "DRY-RUN - no changes will be applied.\nRe-run with --apply to execute the upgrade.",
                    style="bold yellow",
                ),
                title="dry-run",
                border_style="yellow",
            )
        )

    should_run = args.non_interactive or args.accept_defaults or _show_upgrade_summary(config)
    if should_run:
        result: ProvisionResult = run_upgrade(
            config,
            on_output=lambda line: console.print(line, highlight=False),
        )
        _display_upgrade_results(result)
        if result.ok and config.apply:
            _show_verify(verify_tenant(config.tenant))
        return 0 if result.ok else 2
    else:
        console.print("Aborted.")
        return 130
