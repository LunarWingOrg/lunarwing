"""Secrets helpers for the interactive CLI."""

from __future__ import annotations

import os


def generate_master_key() -> str:
    """Return a new random 256-bit master key as 64 hex characters."""
    return os.urandom(32).hex()


def is_valid_master_key(value: str) -> bool:
    """Return True iff *value* is a 64-character lowercase hex string."""
    if len(value) != 64:
        return False
    try:
        int(value, 16)
    except ValueError:
        return False
    return True


def mask_secret(value: str) -> str:
    """Mask a user-facing secret, revealing only the last 4 characters."""
    if len(value) <= 4:
        return "*" * len(value)
    return "*" * (len(value) - 4) + value[-4:]
