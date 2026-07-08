from __future__ import annotations

import argparse
from dataclasses import dataclass

from rich.console import Console
from rich.panel import Panel
from rich.table import Table
from rich.text import Text

from lunarwing_mt_onboard.config import TenantConfig
from lunarwing_mt_onboard.export import (
    DEFAULT_OUT_DIR,
    ExportConfig,
    ensure_export_script,
    run_export,
)
from lunarwing_mt_onboard.provisioner import ProvisionResult

console = Console()


@dataclass(frozen=True, slots=True)
class ExportCliArgs:
    tenant: str | None = None
    out_dir: str = DEFAULT_OUT_DIR
    apply: bool = False
    no_quiesce: bool = False
    non_interactive: bool = False
    accept_defaults: bool = False
    resume: str | None = None
    save: str | None = None

    @classmethod
    def from_namespace(cls, args: argparse.Namespace) -> ExportCliArgs:
        return cls(
            tenant=_optional_str(getattr(args, "tenant", None)),
            out_dir=_str_arg(getattr(args, "out_dir", DEFAULT_OUT_DIR)) or DEFAULT_OUT_DIR,
            apply=_bool_arg(getattr(args, "apply", False)),
            no_quiesce=_bool_arg(getattr(args, "no_quiesce", False)),
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


def gather_export_config(config: ExportConfig) -> ExportConfig:
    console.print(
        Panel.fit(
            Text(
                (
                    "LunarWing Kawarimi Tenant Export\n================================\n"
                    "Exports a tenant for cross-host migration using the bundled\n"
                    "export-tenant.sh script.  Defaults to dry-run;\n"
                    "pass --apply to stop the tenant and write the bundle.\n"
                ),
                style="bold",
            ),
            title="lunarwing-mt-export",
            border_style="magenta",
        )
    )

    tenant = _q_text("Tenant name (lowercase, e.g. 'sphinx')", default=config.tenant)
    err = TenantConfig.validate_name(tenant)
    while err:
        console.print(f"[red]{err}[/]")
        tenant = _q_text("Tenant name", default=config.tenant)
        err = TenantConfig.validate_name(tenant)
    config.tenant = tenant

    config.out_dir = _q_text(
        "Output directory for the migration bundle",
        default=config.out_dir,
    )

    config.apply = _q_confirm(
        "Apply export? (no = dry-run, tenant stays running)",
        default=config.apply,
    )
    if config.apply:
        config.no_quiesce = _q_confirm(
            "Skip auto-stop (--no-quiesce)? Only if you already stopped services.",
            default=config.no_quiesce,
        )

    return config


def _show_export_summary(config: ExportConfig) -> bool:
    table = Table(
        title=f"Export summary: {config.tenant}",
        show_lines=True,
    )
    table.add_column("Field", style="bold cyan")
    table.add_column("Value", style="white")
    table.add_row("Tenant", config.tenant)
    table.add_row("Output directory", config.out_dir)
    table.add_row("No-quiesce", "yes" if config.no_quiesce else "no")
    table.add_row(
        "Mode",
        "APPLY (will stop tenant)" if config.apply else "DRY-RUN",
    )
    console.print(table)
    return _q_confirm("Proceed with export?", default=True)


def _display_export_results(result: ProvisionResult) -> None:
    table = Table(title="Export result")
    table.add_column("Phase", style="bold cyan")
    table.add_column("Status", justify="center")
    table.add_column("Code", justify="right")
    for name, ok, code in result.summary():
        status_text = Text("OK", style="green") if ok else Text("FAIL", style="red")
        table.add_row(name, status_text, str(code))
    console.print(table)
    console.print(
        "Export completed successfully." if result.ok else "Export FAILED.",
        style="bold green" if result.ok else "bold red",
    )


def run_export_flow(args: ExportCliArgs) -> int:
    config = ExportConfig()
    if args.resume:
        try:
            config = ExportConfig.from_json(args.resume)
        except Exception as exc:
            console.print(f"[red]Failed to load --resume file:[/] {exc}")
            return 1
    elif not (args.non_interactive or args.accept_defaults):
        try:
            config = gather_export_config(config)
        except KeyboardInterrupt:
            console.print("\nAborted.")
            return 130

    if args.tenant:
        config.tenant = args.tenant
    if args.out_dir and args.out_dir != DEFAULT_OUT_DIR:
        config.out_dir = args.out_dir
    if args.apply:
        config.apply = args.apply
    if args.no_quiesce:
        config.no_quiesce = args.no_quiesce

    err = config.validate()
    if err:
        console.print(f"[red]Invalid config:[/] {err}")
        return 1

    try:
        _ = ensure_export_script()
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
                    "DRY-RUN — no changes will be applied.\n"
                    "Re-run with --apply to stop the tenant and write the bundle.",
                    style="bold yellow",
                ),
                title="dry-run",
                border_style="yellow",
            )
        )

    should_run = args.non_interactive or args.accept_defaults or _show_export_summary(config)
    if should_run:
        result: ProvisionResult = run_export(
            config,
            on_output=lambda line: console.print(line, highlight=False),
        )
        _display_export_results(result)
        if result.ok and config.apply:
            console.print(
                Panel.fit(
                    Text(
                        "The tenant is now STOPPED.\n"
                        "The bundle contains SECRETS_MASTER_KEY and XMPP credentials.\n"
                        "Transfer over SSH, verify on the target host, then delete the bundle.\n"
                        "To roll back: restart the tenant on this host.",
                        style="bold yellow",
                    ),
                    title="post-export",
                    border_style="magenta",
                )
            )
        return 0 if result.ok else 2
    else:
        console.print("Aborted.")
        return 130
