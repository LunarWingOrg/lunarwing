"""Interactive multi-tenant onboarding CLI for LunarWing.

Thin wrapper around ``lunarwing-mt-admin.sh`` that guides operators through
the full provisioning lifecycle: tenant identity, secrets, LLM config,
channels, workers, build, start, and verification.

Run with::

    sudo python3 -m lunarwing_mt_onboard
"""

__version__ = "0.1.0"
