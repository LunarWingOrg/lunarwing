"""Unit tests for config validation, serialization, and secrets helpers."""

from __future__ import annotations

import json
import os
import tempfile
import unittest

from lunarwing_mt_onboard import provisioner
from lunarwing_mt_onboard.config import TenantConfig, WorkerType
from lunarwing_mt_onboard.secrets import (
    generate_master_key,
    is_valid_master_key,
    mask_secret,
)


class TestTenantNameValidation(unittest.TestCase):
    def test_valid_simple_name(self):
        self.assertIsNone(TenantConfig.validate_name("ruffles"))

    def test_valid_hyphenated_name(self):
        self.assertIsNone(TenantConfig.validate_name("my-tenant"))

    def test_empty_name_rejected(self):
        self.assertEqual(TenantConfig.validate_name(""), "tenant name is required")

    def test_uppercase_rejected(self):
        err = TenantConfig.validate_name("Ruffles")
        self.assertIsNotNone(err)

    def test_underscore_rejected(self):
        err = TenantConfig.validate_name("my_tenant")
        self.assertIsNotNone(err)

    def test_reserved_prefix_rejected(self):
        for prefix in ("pg-", "proxy-", "nanocode-", "pebble-", "opencode-", "weechat-"):
            with self.subTest(prefix=prefix):
                err = TenantConfig.validate_name(f"{prefix}1")
                self.assertIsNotNone(err)


class TestConfigSerialization(unittest.TestCase):
    def test_roundtrip_json(self):
        config = TenantConfig(
            name="alpha",
            gateway_host="0.0.0.0",
            xmpp_enabled=True,
            xmpp_jid="alpha@xmpp.localhost",
            workers=[WorkerType.NANOCODE, WorkerType.OPENCODE],
            tensorzero_url="http://example:3000/v1",
            secrets_master_key="ab" * 32,
        )
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "cfg.json")
            config.to_json(path)
            loaded = TenantConfig.from_json(path)
        self.assertEqual(loaded.name, "alpha")
        self.assertEqual(loaded.gateway_host, "0.0.0.0")
        self.assertTrue(loaded.xmpp_enabled)
        self.assertEqual(loaded.workers, [WorkerType.NANOCODE, WorkerType.OPENCODE])
        self.assertEqual(loaded.tensorzero_url, "http://example:3000/v1")
        self.assertEqual(loaded.secrets_master_key, "ab" * 32)

    def test_to_dict_serializes_workers_as_strings(self):
        config = TenantConfig(
            name="beta",
            workers=[WorkerType.PEBBLE],
        )
        data = config.to_dict()
        self.assertEqual(data["workers"], ["pebble"])

    def test_from_dict_accepts_string_workers(self):
        data = {
            "name": "gamma",
            "workers": ["nanocode", "opencode"],
        }
        config = TenantConfig.from_dict(data)
        self.assertEqual(config.workers, [WorkerType.NANOCODE, WorkerType.OPENCODE])

    def test_json_file_permissions(self):
        config = TenantConfig(name="perms")
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "cfg.json")
            config.to_json(path)
            mode = os.stat(path).st_mode & 0o777
            self.assertEqual(mode, 0o600)

    def test_json_is_valid_format(self):
        config = TenantConfig(name="json-check")
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "cfg.json")
            config.to_json(path)
            with open(path) as f:
                data = json.loads(f.read())
            self.assertIn("name", data)
            self.assertEqual(data["name"], "json-check")


class TestProvisionerArgs(unittest.TestCase):
    def test_custom_gateway_host_is_forwarded_to_mt_admin(self):
        with tempfile.TemporaryDirectory() as tmp:
            script = os.path.join(tmp, "lunarwing-mt-admin.sh")
            with open(script, "w") as f:
                f.write("#!/bin/sh\n")
            os.chmod(script, 0o700)

            previous = provisioner.MT_ADMIN_SCRIPT
            provisioner.MT_ADMIN_SCRIPT = script
            try:
                config = TenantConfig(name="alpha", gateway_host="10.0.0.25")
                args = provisioner.build_add_tenant_args(config)
            finally:
                provisioner.MT_ADMIN_SCRIPT = previous

        self.assertIn("--gateway-host", args)
        self.assertIn("10.0.0.25", args)

    def test_custom_xmpp_jid_is_forwarded_to_mt_admin(self):
        with tempfile.TemporaryDirectory() as tmp:
            script = os.path.join(tmp, "lunarwing-mt-admin.sh")
            with open(script, "w") as f:
                f.write("#!/bin/sh\n")
            os.chmod(script, 0o700)

            previous = provisioner.MT_ADMIN_SCRIPT
            provisioner.MT_ADMIN_SCRIPT = script
            try:
                config = TenantConfig(
                    name="alpha",
                    xmpp_enabled=True,
                    xmpp_jid="alpha@chat.example.net",
                )
                args = provisioner.build_add_tenant_args(config)
            finally:
                provisioner.MT_ADMIN_SCRIPT = previous

        self.assertIn("--xmpp-jid", args)
        self.assertIn("alpha@chat.example.net", args)

    def test_darkirc_flag_is_forwarded_to_mt_admin(self):
        with tempfile.TemporaryDirectory() as tmp:
            script = os.path.join(tmp, "lunarwing-mt-admin.sh")
            with open(script, "w") as f:
                f.write("#!/bin/sh\n")
            os.chmod(script, 0o700)

            previous = provisioner.MT_ADMIN_SCRIPT
            provisioner.MT_ADMIN_SCRIPT = script
            try:
                config = TenantConfig(name="alpha", enable_darkirc=True)
                args = provisioner.build_add_tenant_args(config)
            finally:
                provisioner.MT_ADMIN_SCRIPT = previous

        self.assertIn("--enable-darkirc", args)

    def test_build_darkirc_uses_tenant_context(self):
        with tempfile.TemporaryDirectory() as tmp:
            script = os.path.join(tmp, "lunarwing-mt-admin.sh")
            with open(script, "w") as f:
                f.write("#!/bin/sh\n")
            os.chmod(script, 0o700)

            previous = provisioner.MT_ADMIN_SCRIPT
            provisioner.MT_ADMIN_SCRIPT = script
            try:
                config = TenantConfig(name="alpha", enable_darkirc=True)
                args = provisioner.build_darkirc_args(config)
            finally:
                provisioner.MT_ADMIN_SCRIPT = previous

        self.assertEqual(args, [script, "build-darkirc", "--tenant", "alpha"])

    def test_lunarwing_model_is_forwarded_to_mt_admin(self):
        with tempfile.TemporaryDirectory() as tmp:
            script = os.path.join(tmp, "lunarwing-mt-admin.sh")
            with open(script, "w") as f:
                f.write("#!/bin/sh\n")
            os.chmod(script, 0o700)

            previous = provisioner.MT_ADMIN_SCRIPT
            provisioner.MT_ADMIN_SCRIPT = script
            try:
                config = TenantConfig(
                    name="alpha",
                    llm_model="tensorzero::function_name::lunarwing",
                )
                args = provisioner.build_add_tenant_args(config)
            finally:
                provisioner.MT_ADMIN_SCRIPT = previous

        self.assertIn("--llm-model", args)
        self.assertIn("tensorzero::function_name::lunarwing", args)


class TestSecretsHelpers(unittest.TestCase):
    def test_generate_master_key_length(self):
        key = generate_master_key()
        self.assertEqual(len(key), 64)

    def test_generate_master_key_is_hex(self):
        key = generate_master_key()
        self.assertTrue(is_valid_master_key(key))

    def test_generate_master_key_randomness(self):
        key1 = generate_master_key()
        key2 = generate_master_key()
        self.assertNotEqual(key1, key2)

    def test_is_valid_master_key_rejects_short(self):
        self.assertFalse(is_valid_master_key("abc"))

    def test_is_valid_master_key_rejects_non_hex(self):
        self.assertFalse(is_valid_master_key("z" * 64))

    def test_mask_secret_long(self):
        self.assertEqual(mask_secret("abcdefghij"), "******ghij")

    def test_mask_secret_short(self):
        self.assertEqual(mask_secret("ab"), "**")

    def test_mask_secret_empty(self):
        self.assertEqual(mask_secret(""), "")


if __name__ == "__main__":
    unittest.main()
