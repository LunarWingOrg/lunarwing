from __future__ import annotations

import os
import tempfile
import unittest

from lunarwing_mt_onboard import export
from lunarwing_mt_onboard.export import ExportConfig


class TestExportConfigDefaults(unittest.TestCase):
    def test_default_is_dry_run(self):
        cfg = ExportConfig()
        self.assertFalse(cfg.apply)

    def test_default_out_dir(self):
        cfg = ExportConfig()
        self.assertEqual(cfg.out_dir, export.DEFAULT_OUT_DIR)


class TestExportConfigSerialization(unittest.TestCase):
    def test_roundtrip_json(self):
        cfg = ExportConfig(
            tenant="alpha",
            out_dir="/tmp/migrate",
            apply=True,
            no_quiesce=True,
        )
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "cfg.json")
            cfg.to_json(path)
            loaded = ExportConfig.from_json(path)
        self.assertEqual(loaded.tenant, "alpha")
        self.assertEqual(loaded.out_dir, "/tmp/migrate")
        self.assertTrue(loaded.apply)
        self.assertTrue(loaded.no_quiesce)

    def test_json_file_permissions(self):
        cfg = ExportConfig(tenant="perms")
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "cfg.json")
            cfg.to_json(path)
            mode = os.stat(path).st_mode & 0o777
            self.assertEqual(mode, 0o600)

    def test_to_dict_roundtrip(self):
        cfg = ExportConfig(tenant="beta", out_dir="/custom")
        data = cfg.to_dict()
        self.assertEqual(
            data,
            {
                "tenant": "beta",
                "out_dir": "/custom",
                "apply": False,
                "no_quiesce": False,
            },
        )
        loaded = ExportConfig.from_dict(data)
        self.assertEqual(loaded.tenant, "beta")
        self.assertEqual(loaded.out_dir, "/custom")

    def test_from_dict_defaults_missing_fields(self):
        loaded = ExportConfig.from_dict({})
        self.assertEqual(loaded.tenant, "")
        self.assertFalse(loaded.apply)
        self.assertEqual(loaded.out_dir, export.DEFAULT_OUT_DIR)


class TestExportConfigValidation(unittest.TestCase):
    def test_valid_config(self):
        cfg = ExportConfig(tenant="alpha")
        self.assertIsNone(cfg.validate())

    def test_invalid_tenant(self):
        cfg = ExportConfig(tenant="MY-TENANT")
        err = cfg.validate()
        self.assertIsNotNone(err)

    def test_empty_tenant_rejected(self):
        cfg = ExportConfig(tenant="")
        err = cfg.validate()
        self.assertEqual(err, "tenant name is required")

    def test_empty_out_dir_rejected(self):
        cfg = ExportConfig(tenant="alpha", out_dir="")
        err = cfg.validate()
        self.assertIsNotNone(err)


class TestEnsureExportScript(unittest.TestCase):
    def test_missing_script_raises(self):
        previous = export.EXPORT_SCRIPT
        export.EXPORT_SCRIPT = "/nonexistent/export.sh"
        try:
            with self.assertRaises(FileNotFoundError):
                export.ensure_export_script()
        finally:
            export.EXPORT_SCRIPT = previous

    def test_env_override_used(self):
        with tempfile.TemporaryDirectory() as tmp:
            script = os.path.join(tmp, "export-tenant.sh")
            with open(script, "w") as f:
                f.write("#!/bin/sh\n")
            os.chmod(script, 0o700)

            previous = export.EXPORT_SCRIPT
            export.EXPORT_SCRIPT = script
            try:
                found = export.ensure_export_script()
            finally:
                export.EXPORT_SCRIPT = previous
            self.assertEqual(found, script)


class TestExportArgs(unittest.TestCase):
    def test_dry_run_adds_flag(self):
        with tempfile.TemporaryDirectory() as tmp:
            script = _write_script(tmp, "export-tenant.sh", "echo ok")
            previous = export.EXPORT_SCRIPT
            export.EXPORT_SCRIPT = script
            try:
                cfg = ExportConfig(tenant="alpha", out_dir="/tmp/out")
                args = export.build_export_args(cfg)
            finally:
                export.EXPORT_SCRIPT = previous

        self.assertEqual(args[0], script)
        self.assertEqual(args[1], "alpha")
        self.assertIn("--out-dir", args)
        self.assertIn("/tmp/out", args)
        self.assertIn("--dry-run", args)

    def test_apply_omits_dry_run(self):
        with tempfile.TemporaryDirectory() as tmp:
            script = _write_script(tmp, "export-tenant.sh", "echo ok")
            previous = export.EXPORT_SCRIPT
            export.EXPORT_SCRIPT = script
            try:
                cfg = ExportConfig(tenant="alpha", apply=True)
                args = export.build_export_args(cfg)
            finally:
                export.EXPORT_SCRIPT = previous

        self.assertNotIn("--dry-run", args)

    def test_no_quiesce_forwarded(self):
        with tempfile.TemporaryDirectory() as tmp:
            script = _write_script(tmp, "export-tenant.sh", "echo ok")
            previous = export.EXPORT_SCRIPT
            export.EXPORT_SCRIPT = script
            try:
                cfg = ExportConfig(tenant="alpha", apply=True, no_quiesce=True)
                args = export.build_export_args(cfg)
            finally:
                export.EXPORT_SCRIPT = previous

        self.assertIn("--no-quiesce", args)


class TestExportPhaseNames(unittest.TestCase):
    def test_run_export_uses_export_phase_name(self):
        with tempfile.TemporaryDirectory() as tmp:
            script = _write_script(tmp, "export-tenant.sh", "echo ok\nexit 0")
            previous = export.EXPORT_SCRIPT
            export.EXPORT_SCRIPT = script
            try:
                result = export.run_export(ExportConfig(tenant="alpha", apply=True))
            finally:
                export.EXPORT_SCRIPT = previous

        self.assertTrue(result.ok)
        self.assertEqual(result.phases[0].name, "export")


def _write_script(directory: str, name: str, body: str) -> str:
    path = os.path.join(directory, name)
    with open(path, "w") as f:
        f.write(f"#!/bin/sh\n{body}\n")
    os.chmod(path, 0o700)
    return path


if __name__ == "__main__":
    unittest.main()
