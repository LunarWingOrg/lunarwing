"""Interactive CLI for multi-tenant provisioning.

Drives an interactive or non-interactive session that gathers tenant
configuration, runs :mod:`provisioner`, and prints a result summary.
"""

from __future__ import annotations

import argparse
import sys
from typing import NoReturn

from rich.console import Console
from rich.panel import Panel
from rich.table import Table
from rich.text import Text

from lunarwing_mt_onboard.config import (
    TenantConfig,
    WorkerType,
)
from lunarwing_mt_onboard.provisioner import ensure_mt_admin, provision
from lunarwing_mt_onboard.secrets import (
    generate_master_key,
    is_valid_master_key,
    mask_secret,
)
from lunarwing_mt_onboard.verify import verify_tenant

console = Console()


WORKER_LABELS = {
    WorkerType.NANOCODE: "nanocode (NanoGPT)",
    WorkerType.PEBBLE: "pebble (Rust harness)",
    WorkerType.OPENCODE: "opencode (sst/opencode)",
}


# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------


def _build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="lunarwing_mt_onboard",
        description=(
            "Interactive multi-tenant provisioning CLI for LunarWing.\n"
            "Guides through the full add-tenant -> build-tenant -> start-tenant "
            "lifecycle using lunarwing-mt-admin.sh."
        ),
    )
    p.add_argument(
        "--non-interactive",
        action="store_true",
        help="Skip prompts, use --resume or CLI flags only.",
    )
    p.add_argument(
        "--accept-defaults",
        action="store_true",
        help="Accept all default values without prompting.",
    )
    p.add_argument(
        "--resume",
        metavar="FILE",
        help="Load a previously saved TenantConfig JSON and re-run.",
    )
    p.add_argument(
        "--save",
        metavar="FILE",
        help="Save the collected config to a JSON file before provisioning.",
    )
    p.add_argument(
        "--skip-build",
        action="store_true",
        help="Only run add-tenant (skip build-tenant and start-tenant).",
    )
    p.add_argument(
        "--skip-start",
        action="store_true",
        help="Run add-tenant and build-tenant but skip start-tenant.",
    )
    return p


# ---------------------------------------------------------------------------
# Interactive field helpers (depend on questionary)
# ---------------------------------------------------------------------------


def _q_text(label: str, *, default: str = "") -> str:
    try:
        import questionary

        result = questionary.text(label, default=default).ask()
        if result is None:
            raise KeyboardInterrupt
        return result
    except KeyboardInterrupt:
        raise
    except Exception:
        prompt = f"{label}: " if not default else f"{label} [{default}]: "
        raw = input(prompt).strip()
        return raw or default


def _q_select(label: str, choices: list[str], *, default: int = 0) -> int:
    try:
        import questionary

        answer = questionary.select(label, choices=choices).ask()
        if answer is None:
            raise KeyboardInterrupt
        return choices.index(answer) if answer in choices else default
    except KeyboardInterrupt:
        raise
    except Exception:
        for i, c in enumerate(choices, 1):
            marker = "*" if i - 1 == default else " "
            print(f"  {marker} {i}) {c}")
        raw = input(f"{label} [{default + 1}]: ").strip()
        if not raw.isdigit():
            return default
        idx = int(raw) - 1
        return idx if 0 <= idx < len(choices) else default


def _q_confirm(label: str, *, default: bool = False) -> bool:
    try:
        import questionary

        answer = questionary.confirm(label, default=default).ask()
        if answer is None:
            raise KeyboardInterrupt
        return answer
    except KeyboardInterrupt:
        raise
    except Exception:
        suffix = " [Y/n]" if default else " [y/N]"
        raw = input(f"{label}{suffix}: ").strip().lower()
        if not raw:
            return default
        return raw in ("y", "yes")


def _q_checkbox(label: str, choices: list[str]) -> list[str]:
    try:
        import questionary

        result = questionary.checkbox(label, choices=choices).ask()
        if result is None:
            raise KeyboardInterrupt
        return result or []
    except KeyboardInterrupt:
        raise
    except Exception:
        print(f"{label} (comma-separated indices):")
        for i, c in enumerate(choices, 1):
            print(f"   {i}) {c}")
        raw = input("> ").strip()
        if not raw:
            return []
        indices = [int(x.strip()) - 1 for x in raw.split(",") if x.strip().isdigit()]
        return [choices[i] for i in indices if 0 <= i < len(choices)]


def _q_password(label: str, *, validate=None) -> str:
    try:
        import questionary

        result = questionary.password(
            label, validate=validate or (lambda _: True)
        ).ask()
        if result is None:
            raise KeyboardInterrupt
        return result
    except KeyboardInterrupt:
        raise
    except Exception:
        import getpass

        return getpass.getpass(f"{label}: ")


# ---------------------------------------------------------------------------
# Gathering flow
# ---------------------------------------------------------------------------


def gather_config(config: TenantConfig) -> TenantConfig:
    """Populate *config* interactively using questionary prompts."""
    console.print(
        Panel.fit(
            Text(
                "LunarWing Multi-Tenant Onboarding\n"
                "================================\n"
                "This tool guides you through provisioning a new tenant\n"
                "using lunarwing-mt-admin.sh as the provisioning backend.\n",
                style="bold",
            ),
            title="lunarwing-mt-onboard",
            border_style="green",
        )
    )
    name = _q_text("Tenant name (lowercase, e.g. 'sphinx')")
    err = TenantConfig.validate_name(name)
    while err:
        console.print(f"[red]{err}[/]")
        name = _q_text("Tenant name")
        err = TenantConfig.validate_name(name)
    config.name = name

    _configure_network(config)
    _configure_channels(config)
    _configure_workers(config)
    _configure_llm(config)
    _configure_secrets(config)

    return config


def _configure_network(config: TenantConfig) -> None:
    config.gateway_host = _q_text(
        "Gateway bind host/IP",
        default=config.gateway_host,
    )
    config.docker_group = _q_confirm(
        "Add tenant user to docker/podman group?", default=config.docker_group
    )


def _configure_channels(config: TenantConfig) -> None:
    config.enable_darkirc = _q_confirm(
        "Enable DarkIRC services?", default=config.enable_darkirc
    )

    config.xmpp_enabled = _q_confirm("Enable XMPP bridge?")
    if config.xmpp_enabled:
        default_xmpp_domain = "xmpp.localhost"
        if "@" in config.xmpp_jid:
            default_xmpp_domain = config.xmpp_jid.split("@", 1)[1]
        xmpp_domain = _q_text("XMPP domain/host", default=default_xmpp_domain)
        config.xmpp_jid = _q_text(
            "XMPP JID",
            default=config.xmpp_jid or f"{config.name}@{xmpp_domain}",
        )
        config.xmpp_password = _q_password("XMPP password (leave blank to auto-generate)")
        allow = _q_text("Extra allowed DM senders (comma-separated, optional)")
        config.xmpp_allow_from = [
            j.strip() for j in allow.split(",") if j.strip()
        ]

    config.gotify_enabled = _q_confirm("Enable Gotify notifications?")
    if config.gotify_enabled:
        config.gotify_url = _q_text("Gotify URL (e.g. https://gotify.example.com/)")
        config.gotify_title = _q_text(
            "Gotify title override", default=config.name
        )


def _configure_workers(config: TenantConfig) -> None:
    labels = [
        WORKER_LABELS[WorkerType.NANOCODE],
        WORKER_LABELS[WorkerType.PEBBLE],
        WORKER_LABELS[WorkerType.OPENCODE],
    ]
    selected = _q_checkbox("External workers (space to toggle, enter to confirm)", labels)
    config.workers = []
    for label in selected:
        for wt, wl in WORKER_LABELS.items():
            if label == wl:
                config.workers.append(wt)
                break
    if config.workers:
        config.toolchains = _q_confirm(
            "Include Rust/Go/C++ toolchains in workers? (increases image size ~5GB)",
            default=config.toolchains,
        )


def _configure_llm(config: TenantConfig) -> None:
    config.tensorzero_url = _q_text(
        "TensorZero upstream URL",
        default=config.tensorzero_url,
    )
    idx = _q_select(
        "LLM model",
        [
            "tensorzero::function_name::FrontierCODE",
            "tensorzero::function_name::lunarwing",
            "Custom...",
        ],
        default=1,
    )
    if idx == 0:
        config.llm_model = "tensorzero::function_name::FrontierCODE"
    elif idx == 1:
        config.llm_model = "tensorzero::function_name::lunarwing"
    else:
        config.llm_model = _q_text("Custom LLM model ID")
    config.llm_api_key = _q_password(
        "LLM API key (leave blank for unneeded/default)"
    )


def _configure_secrets(config: TenantConfig) -> None:
    existing = _q_password(
        "Secrets master key (64-hex, leave blank to auto-generate)"
    )
    if existing:
        while not is_valid_master_key(existing):
            console.print("[red]Invalid master key. Must be 64-char hex.[/]")
            existing = _q_password("Secrets master key")
        config.secrets_master_key = existing
    config.no_ssh = not _q_confirm("Provision SSH harness for tenant?", default=True)
    config.no_health = not _q_confirm(
        "Enable host health pipeline for tenant?", default=True
    )


# ---------------------------------------------------------------------------
# Confirmation + run
# ---------------------------------------------------------------------------


def _show_summary(config: TenantConfig) -> bool:
    table = Table(
        title=f"Provisioning summary: {config.name}",
        show_lines=True,
    )
    table.add_column("Field", style="bold cyan")
    table.add_column("Value", style="white")
    table.add_row("Gateway host", config.gateway_host)
    table.add_row("Docker group", str(config.docker_group))
    table.add_row(
        "XMPP bridge",
        config.xmpp_jid if config.xmpp_enabled else "disabled",
    )
    table.add_row(
        "Gotify",
        config.gotify_url if config.gotify_enabled else "disabled",
    )
    table.add_row(
        "Workers",
        ", ".join(WORKER_LABELS[w] for w in config.workers) or "none",
    )
    table.add_row("Toolchains", str(config.toolchains))
    table.add_row("TensorZero URL", config.tensorzero_url)
    table.add_row("LLM model", config.llm_model)
    table.add_row(
        "Secrets master key",
        mask_secret(config.secrets_master_key)
        if config.secrets_master_key
        else "auto-generate",
    )
    table.add_row("SSH harness", str(not config.no_ssh))
    table.add_row("Health pipeline", str(not config.no_health))
    console.print(table)
    return _q_confirm("Proceed with add-tenant?", default=True)


def _display_results(result) -> None:  # result: ProvisionResult
    table = Table(title="Provisioning result")
    table.add_column("Phase", style="bold cyan")
    table.add_column("Status", justify="center")
    table.add_column("Code", justify="right")
    for name, ok, code in result.summary():
        status_text = Text("OK", style="green") if ok else Text("FAIL", style="red")
        table.add_row(name, status_text, str(code))
    console.print(table)
    console.print(
        "Tenant provisioned successfully!" if result.ok else "Provisioning FAILED.",
        style="bold green" if result.ok else "bold red",
    )


def _show_verify(tenant: str, host: str = "127.0.0.1", port: int = 0) -> None:
    console.print("Post-start verification...", style="bold")
    results = verify_tenant(tenant, host, port)
    table = Table(title="Verification")
    table.add_column("Check", style="bold cyan")
    table.add_column("Status", justify="center")
    for r in results:
        status = Text("PASS", style="green") if r.ok else Text("FAIL", style="red")
        table.add_row(r.label, status)
    console.print(table)


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------


def main(argv: list[str] | None = None) -> int:
    parser = _build_parser()
    args = parser.parse_args(argv)

    config = TenantConfig()
    if args.resume:
        try:
            config = TenantConfig.from_json(args.resume)
        except Exception as exc:
            console.print(f"[red]Failed to load --resume file:[/] {exc}")
            return 1
    elif not (args.non_interactive or args.accept_defaults):
        try:
            config = gather_config(config)
        except KeyboardInterrupt:
            console.print("\nAborted.")
            return 130

    err = TenantConfig.validate_name(config.name)
    if err:
        console.print(f"[red]Invalid config:[/] {err}")
        return 1

    if not config.secrets_master_key:
        console.print(
            "Generated new secrets master key. THIS WILL BE SHOWN ONCE.",
            style="bold yellow",
        )
        config.secrets_master_key = generate_master_key()
        console.print(f"Key: {config.secrets_master_key}")

    if args.save:
        config.to_json(args.save)
        console.print(f"Saved config to [cyan]{args.save}[/]")

    try:
        ensure_mt_admin()
    except FileNotFoundError as exc:
        console.print(f"[red]{exc}[/]")
        return 1

    if _show_summary(config):
        result = provision(
            config,
            on_output=lambda line: console.print(line, highlight=False),
            skip_build=args.skip_build,
            skip_start=args.skip_start,
        )
        _display_results(result)
        if result.ok and not args.skip_start:
            _show_verify(config.name, host=config.gateway_host, port=config.gateway_port)
        return 0 if result.ok else 2
    else:
        console.print("Aborted.")
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
