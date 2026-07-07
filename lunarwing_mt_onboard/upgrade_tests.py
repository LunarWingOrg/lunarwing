from __future__ import annotations

import os
import tempfile
import unittest

from lunarwing_mt_onboard import upgrade
from lunarwing_mt_onboard.upgrade import UpgradeConfig


class TestTargetTagValidation(unittest.TestCase):
    def test_empty_tag_accepted(self):
        self.assertIsNone(upgrade.validate_target_tag(""))

    def test_exact_release_accepted(self):
        self.assertIsNone(upgrade.validate_target_tag("v1.1.9"))
        self.assertIsNone(upgrade.validate_target_tag("v2.0.0"))

    def test_branch_rejected(self):
        err = upgrade.validate_target_tag("main")
        self.assertIsNotNone(err)

    def test_prerelease_rejected(self):
        err = upgrade.validate_target_tag("v1.1.9-rc1")
        self.assertIsNotNone(err)

    def test_bare_number_rejected(self):
        err = upgrade.validate_target_tag("1.1.9")
        self.assertIsNotNone(err)

    def test_method_on_config(self):
        self.assertIsNone(UpgradeConfig.validate_target_tag("v1.1.9"))
        self.assertIsNotNone(UpgradeConfig.validate_target_tag("main"))


class TestUpgradeConfigDefaults(unittest.TestCase):
    def test_default_is_dry_run(self):
        cfg = UpgradeConfig()
        self.assertFalse(cfg.apply)

    def test_default_runs_preflight(self):
        cfg = UpgradeConfig()
        self.assertTrue(cfg.run_preflight)


class TestUpgradeConfigSerialization(unittest.TestCase):
    def test_roundtrip_json(self):
        cfg = UpgradeConfig(
            tenant="alpha",
            target="v1.1.9",
            apply=True,
            auto_yes=True,
            force=True,
            source_version_override="v1.1.7",
            run_preflight=False,
        )
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "cfg.json")
            cfg.to_json(path)
            loaded = UpgradeConfig.from_json(path)
        self.assertEqual(loaded.tenant, "alpha")
        self.assertEqual(loaded.target, "v1.1.9")
        self.assertTrue(loaded.apply)
        self.assertTrue(loaded.auto_yes)
        self.assertTrue(loaded.force)
        self.assertEqual(loaded.source_version_override, "v1.1.7")
        self.assertFalse(loaded.run_preflight)

    def test_json_file_permissions(self):
        cfg = UpgradeConfig(tenant="perms")
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "cfg.json")
            cfg.to_json(path)
            mode = os.stat(path).st_mode & 0o777
            self.assertEqual(mode, 0o600)

    def test_to_dict_roundtrip(self):
        cfg = UpgradeConfig(tenant="beta", target="v1.1.8")
        data = cfg.to_dict()
        self.assertEqual(
            data,
            {
                "tenant": "beta",
                "target": "v1.1.8",
                "apply": False,
                "auto_yes": False,
                "force": False,
                "source_version_override": "",
                "run_preflight": True,
            },
        )
        loaded = UpgradeConfig.from_dict(data)
        self.assertEqual(loaded.tenant, "beta")
        self.assertEqual(loaded.target, "v1.1.8")

    def test_from_dict_defaults_missing_fields(self):
        loaded = UpgradeConfig.from_dict({})
        self.assertEqual(loaded.tenant, "")
        self.assertFalse(loaded.apply)
        self.assertTrue(loaded.run_preflight)


class TestUpgradeConfigValidation(unittest.TestCase):
    def test_valid_config(self):
        cfg = UpgradeConfig(tenant="alpha", target="v1.1.9")
        self.assertIsNone(cfg.validate())

    def test_invalid_tenant(self):
        cfg = UpgradeConfig(tenant="MY-TENANT", target="v1.1.9")
        err = cfg.validate()
        self.assertIsNotNone(err)

    def test_invalid_target(self):
        cfg = UpgradeConfig(tenant="alpha", target="v1.1.9-rc1")
        err = cfg.validate()
        self.assertIsNotNone(err)

    def test_invalid_source_override(self):
        cfg = UpgradeConfig(tenant="alpha", source_version_override="main")
        err = cfg.validate()
        self.assertIsNotNone(err)

    def test_empty_tenant_rejected(self):
        cfg = UpgradeConfig(tenant="", target="v1.1.9")
        err = cfg.validate()
        self.assertEqual(err, "tenant name is required")


class TestEnsureUpgradeScript(unittest.TestCase):
    def test_missing_script_raises(self):
        previous = upgrade.UPGRADE_SCRIPT
        upgrade.UPGRADE_SCRIPT = "/nonexistent/script.sh"
        try:
            with self.assertRaises(FileNotFoundError):
                upgrade.ensure_upgrade_script()
        finally:
            upgrade.UPGRADE_SCRIPT = previous

    def test_env_override_used(self):
        with tempfile.TemporaryDirectory() as tmp:
            script = os.path.join(tmp, "upgrade-tenant-version.sh")
            with open(script, "w") as f:
                f.write("#!/bin/sh\n")
            os.chmod(script, 0o700)

            previous = upgrade.UPGRADE_SCRIPT
            upgrade.UPGRADE_SCRIPT = script
            try:
                found = upgrade.ensure_upgrade_script()
            finally:
                upgrade.UPGRADE_SCRIPT = previous
            self.assertEqual(found, script)


class TestEnsurePreflightScript(unittest.TestCase):
    def test_missing_script_raises(self):
        previous = upgrade.PREFLIGHT_SCRIPT
        upgrade.PREFLIGHT_SCRIPT = "/nonexistent/preflight.sh"
        try:
            with self.assertRaises(FileNotFoundError):
                upgrade.ensure_preflight_script()
        finally:
            upgrade.PREFLIGHT_SCRIPT = previous


class TestPreflightArgs(unittest.TestCase):
    def test_preflight_argv_shape(self):
        with tempfile.TemporaryDirectory() as tmp:
            script = os.path.join(tmp, "upgrade-preflight.sh")
            with open(script, "w") as f:
                f.write("#!/bin/sh\n")
            os.chmod(script, 0o700)

            previous = upgrade.PREFLIGHT_SCRIPT
            upgrade.PREFLIGHT_SCRIPT = script
            try:
                cfg = UpgradeConfig(tenant="alpha")
                args = upgrade.build_preflight_args(cfg)
            finally:
                upgrade.PREFLIGHT_SCRIPT = previous

        self.assertEqual(args, [script, "alpha"])


class TestUpgradeArgs(unittest.TestCase):
    def test_dry_run_omits_apply(self):
        with tempfile.TemporaryDirectory() as tmp:
            script = os.path.join(tmp, "upgrade-tenant-version.sh")
            with open(script, "w") as f:
                f.write("#!/bin/sh\n")
            os.chmod(script, 0o700)

            previous = upgrade.UPGRADE_SCRIPT
            upgrade.UPGRADE_SCRIPT = script
            try:
                cfg = UpgradeConfig(tenant="alpha", target="v1.1.9")
                args = upgrade.build_upgrade_args(cfg)
            finally:
                upgrade.UPGRADE_SCRIPT = previous

        self.assertNotIn("--apply", args)
        self.assertIn("--target", args)
        self.assertIn("v1.1.9", args)

    def test_apply_adds_flag(self):
        with tempfile.TemporaryDirectory() as tmp:
            script = os.path.join(tmp, "upgrade-tenant-version.sh")
            with open(script, "w") as f:
                f.write("#!/bin/sh\n")
            os.chmod(script, 0o700)

            previous = upgrade.UPGRADE_SCRIPT
            upgrade.UPGRADE_SCRIPT = script
            try:
                cfg = UpgradeConfig(tenant="alpha", apply=True)
                args = upgrade.build_upgrade_args(cfg)
            finally:
                upgrade.UPGRADE_SCRIPT = previous

        self.assertIn("--apply", args)

    def test_target_source_force_yes_forwarded(self):
        with tempfile.TemporaryDirectory() as tmp:
            script = os.path.join(tmp, "upgrade-tenant-version.sh")
            with open(script, "w") as f:
                f.write("#!/bin/sh\n")
            os.chmod(script, 0o700)

            previous = upgrade.UPGRADE_SCRIPT
            upgrade.UPGRADE_SCRIPT = script
            try:
                cfg = UpgradeConfig(
                    tenant="alpha",
                    target="v1.1.9",
                    source_version_override="v1.1.7",
                    force=True,
                    auto_yes=True,
                )
                args = upgrade.build_upgrade_args(cfg)
            finally:
                upgrade.UPGRADE_SCRIPT = previous

        self.assertEqual(args[0], script)
        self.assertEqual(args[1], "alpha")
        self.assertIn("--target", args)
        self.assertIn("v1.1.9", args)
        self.assertIn("--source-version-override", args)
        self.assertIn("v1.1.7", args)
        self.assertIn("--force", args)
        self.assertIn("--yes", args)


if __name__ == "__main__":
    unittest.main()
