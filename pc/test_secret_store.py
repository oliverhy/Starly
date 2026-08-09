from __future__ import annotations

import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from pc.secret_store import protect_secret, unprotect_secret


@unittest.skipUnless(os.name == "nt", "Windows DPAPI test")
class SecretStoreTests(unittest.TestCase):
    def test_dpapi_round_trip_does_not_contain_plaintext(self) -> None:
        secret = "private-starly-token-with-32-characters"
        protected = protect_secret(secret)
        self.assertNotIn(secret, protected)
        self.assertEqual(unprotect_secret(protected), secret)

    def test_bridge_config_migrates_plaintext_token(self) -> None:
        from pc import starly_bridge

        secret = "migration-starly-token-with-32-characters"
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "config.json"
            path.write_text(json.dumps({
                "port": 8765, "token": secret, "pairing_code": "123456",
            }), encoding="utf-8")
            with mock.patch.object(starly_bridge, "CONFIG_DIR", Path(directory)), \
                    mock.patch.object(starly_bridge, "CONFIG_PATH", path):
                config = starly_bridge.BridgeConfig.load()
            saved = json.loads(path.read_text(encoding="utf-8"))
        self.assertEqual(config.token, secret)
        self.assertNotIn("token", saved)
        self.assertEqual(unprotect_secret(saved["token_protected"]), secret)
        self.assertEqual(unprotect_secret(saved["gateway_token_protected"]), secret)

    def test_bridge_config_keeps_lan_and_gateway_tokens_separate(self) -> None:
        from pc import starly_bridge

        lan_secret = "lan-secret-token-with-at-least-32-characters"
        gateway_secret = "gateway-secret-token-with-at-least-32-characters"
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "config.json"
            path.write_text(json.dumps({
                "port": 8765,
                "token_protected": protect_secret(lan_secret),
                "gateway_token_protected": protect_secret(gateway_secret),
                "pairing_code": "123456",
            }), encoding="utf-8")
            with mock.patch.object(starly_bridge, "CONFIG_DIR", Path(directory)), \
                    mock.patch.object(starly_bridge, "CONFIG_PATH", path):
                config = starly_bridge.BridgeConfig.load()
        self.assertEqual(config.token, lan_secret)
        self.assertEqual(config.gateway_token, gateway_secret)

    def test_gateway_device_credential_is_dpapi_protected(self) -> None:
        from pc import starly_bridge

        credential = "device-credential-with-at-least-32-characters"
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "config.json"
            config = starly_bridge.BridgeConfig(
                gateway_device_credential=credential)
            with mock.patch.object(starly_bridge, "CONFIG_DIR", Path(directory)), \
                    mock.patch.object(starly_bridge, "CONFIG_PATH", path):
                config.save()
                loaded = starly_bridge.BridgeConfig.load()
            saved = json.loads(path.read_text(encoding="utf-8"))
        self.assertEqual(loaded.gateway_device_credential, credential)
        self.assertNotIn(credential, json.dumps(saved))
        self.assertEqual(unprotect_secret(
            saved["gateway_device_credential_protected"]), credential)


if __name__ == "__main__":
    unittest.main()
