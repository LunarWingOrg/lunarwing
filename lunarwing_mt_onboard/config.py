"""Tenant configuration dataclass and JSON serialization.

``TenantConfig`` captures every choice the interactive CLI collects and can
serialize to/from JSON so that a provisioning session can be saved and
resumed later via ``--resume <file>``.
"""

from __future__ import annotations

import json
import os
import re
from dataclasses import dataclass, field, asdict
from enum import Enum
from pathlib import Path
from typing import Any

TENANT_NAME_RE = re.compile(r"^[a-z0-9][a-z0-9-]*$")

RESERVED_PREFIXES = ("pg-", "proxy-", "nanocode-", "pebble-", "opencode-", "weechat-")


class WorkerType(str, Enum):
    """Selectable external worker container types."""

    NANOCODE = "nanocode"
    PEBBLE = "pebble"
    OPENCODE = "opencode"


@dataclass
class TenantConfig:
    """All parameters collected during interactive provisioning."""

    name: str = ""
    gateway_host: str = "127.0.0.1"
    gateway_port: int = 0
    docker_group: bool = True
    enable_darkirc: bool = False
    xmpp_enabled: bool = False
    xmpp_jid: str = ""
    xmpp_password: str = ""
    xmpp_allow_from: list[str] = field(default_factory=list)
    gotify_enabled: bool = False
    gotify_url: str = ""
    gotify_title: str = ""
    workers: list[WorkerType] = field(default_factory=list)
    toolchains: bool = False
    tensorzero_url: str = "http://192.168.1.157:3000/openai/v1"
    llm_model: str = "tensorzero::function_name::lunarwing"
    llm_api_key: str = ""
    secrets_master_key: str = ""
    no_ssh: bool = False
    no_health: bool = False

    # ------------------------------------------------------------------
    # Validation
    # ------------------------------------------------------------------

    @staticmethod
    def validate_name(name: str) -> str | None:
        """Return an error message if *name* is invalid, ``None`` if OK."""
        if not name:
            return "tenant name is required"
        if not TENANT_NAME_RE.match(name):
            return "tenant name must be lowercase alphanumeric with hyphens"
        if any(name.startswith(p) for p in RESERVED_PREFIXES):
            return (
                "tenant name collides with a reserved service-unit prefix "
                f"({', '.join(RESERVED_PREFIXES)})"
            )
        return None

    # ------------------------------------------------------------------
    # Serialization
    # ------------------------------------------------------------------

    def to_dict(self) -> dict[str, Any]:
        """Return a plain ``dict`` suitable for JSON dumps."""
        d = asdict(self)
        d["workers"] = [w.value for w in self.workers]
        return d

    def to_json(self, path: str | Path) -> None:
        """Write this config to *path* as JSON with 0600 at creation time."""
        p = Path(path)
        fd = os.open(str(p), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as f:
            f.write(json.dumps(self.to_dict(), indent=2) + "\n")

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> "TenantConfig":
        """Reconstruct a config from a deserialized dict."""
        workers_raw = data.get("workers", [])
        workers = [WorkerType(w) for w in workers_raw]
        return cls(
            name=data.get("name", ""),
            gateway_host=data.get("gateway_host", "127.0.0.1"),
            gateway_port=data.get("gateway_port", 0),
            docker_group=data.get("docker_group", True),
            enable_darkirc=data.get("enable_darkirc", False),
            xmpp_enabled=data.get("xmpp_enabled", False),
            xmpp_jid=data.get("xmpp_jid", ""),
            xmpp_password=data.get("xmpp_password", ""),
            xmpp_allow_from=list(data.get("xmpp_allow_from", [])),
            gotify_enabled=data.get("gotify_enabled", False),
            gotify_url=data.get("gotify_url", ""),
            gotify_title=data.get("gotify_title", ""),
            workers=workers,
            toolchains=data.get("toolchains", False),
            tensorzero_url=data.get(
                "tensorzero_url", "http://192.168.1.157:3000/openai/v1"
            ),
            llm_model=data.get(
                "llm_model", "tensorzero::function_name::lunarwing"
            ),
            llm_api_key=data.get("llm_api_key", ""),
            secrets_master_key=data.get("secrets_master_key", ""),
            no_ssh=data.get("no_ssh", False),
            no_health=data.get("no_health", False),
        )

    @classmethod
    def from_json(cls, path: str | Path) -> "TenantConfig":
        """Load a config previously written by :meth:`to_json`."""
        data = json.loads(Path(path).read_text())
        return cls.from_dict(data)
