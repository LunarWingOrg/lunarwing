from __future__ import annotations

import os
import tempfile
import unittest

from lunarwing_mt_onboard import upgrade
from lunarwing_mt_onboard.upgrade_cli import UpgradeCliArgs, run_upgrade_flow
from lunarwing_mt_onboard.upgrade import UpgradeConfig


class TestRunPreflight(unittest.TestCase):
    def test_run_preflight_returns_phase_result(self):
        with tempfile.TemporaryDirectory() as tmp:
            script = os.path.join(tmp, "upgrade-preflight.sh")
            with open(script, "w") as f:
                f.write("#!/bin/sh\necho hi\nexit 0\n")
            os.chmod(script, 0o700)

            previous = upgrade.PREFLIGHT_SCRIPT
            upgrade.PREFLIGHT_SCRIPT = script
            try:
                result = upgrade.run_preflight(UpgradeConfig(tenant="alpha"))
            finally:
                upgrade.PREFLIGHT_SCRIPT = previous

        self.assertTrue(result.ok)
        self.assertEqual(result.returncode, 0)
        self.assertIn("hi", result.stdout)


class TestRunUpgrade(unittest.TestCase):
    def test_upgrade_runs_preflight_then_upgrade(self):
        result = _run_upgrade_with_scripts(
            preflight_body="echo ok\nexit 0",
            upgrade_body="echo ok\nexit 0",
            cfg=UpgradeConfig(tenant="alpha"),
        )

        self.assertTrue(result.ok)
        self.assertEqual(len(result.phases), 2)

    def test_preflight_failure_stops_unless_forced(self):
        result = _run_upgrade_with_scripts(
            preflight_body="echo boom\nexit 1",
            upgrade_body="echo should-not-run\nexit 0",
            cfg=UpgradeConfig(tenant="alpha", force=False),
        )

        self.assertFalse(result.ok)
        self.assertEqual(len(result.phases), 1)

    def test_force_continues_past_failed_preflight(self):
        result = _run_upgrade_with_scripts(
            preflight_body="echo boom\nexit 1",
            upgrade_body="echo ran\nexit 0",
            cfg=UpgradeConfig(tenant="alpha", force=True),
        )

        self.assertEqual(len(result.phases), 2)
        self.assertFalse(result.phases[0].ok)
        self.assertTrue(result.phases[1].ok)


class TestUpgradeFlow(unittest.TestCase):
    def test_non_interactive_dry_run_executes_without_prompt(self):
        with tempfile.TemporaryDirectory() as tmp:
            upgrade_script = _write_script(
                tmp,
                "upgrade-tenant-version.sh",
                "echo dry-run\nexit 0",
            )

            previous = upgrade.UPGRADE_SCRIPT
            upgrade.UPGRADE_SCRIPT = upgrade_script
            try:
                code = run_upgrade_flow(
                    UpgradeCliArgs(
                        tenant="alpha",
                        target="v1.1.9",
                        source_version_override="",
                        apply=False,
                        yes=False,
                        force=False,
                        no_preflight=True,
                        non_interactive=True,
                        accept_defaults=False,
                        resume=None,
                        save=None,
                    )
                )
            finally:
                upgrade.UPGRADE_SCRIPT = previous

        self.assertEqual(code, 0)


def _run_upgrade_with_scripts(
    *,
    preflight_body: str,
    upgrade_body: str,
    cfg: UpgradeConfig,
):
    with tempfile.TemporaryDirectory() as tmp:
        preflight = _write_script(tmp, "upgrade-preflight.sh", preflight_body)
        upgrade_script = _write_script(tmp, "upgrade-tenant-version.sh", upgrade_body)

        prev_pre = upgrade.PREFLIGHT_SCRIPT
        prev_up = upgrade.UPGRADE_SCRIPT
        upgrade.PREFLIGHT_SCRIPT = preflight
        upgrade.UPGRADE_SCRIPT = upgrade_script
        try:
            return upgrade.run_upgrade(cfg)
        finally:
            upgrade.PREFLIGHT_SCRIPT = prev_pre
            upgrade.UPGRADE_SCRIPT = prev_up


def _write_script(directory: str, name: str, body: str) -> str:
    path = os.path.join(directory, name)
    with open(path, "w") as f:
        f.write(f"#!/bin/sh\n{body}\n")
    os.chmod(path, 0o700)
    return path


if __name__ == "__main__":
    unittest.main()
