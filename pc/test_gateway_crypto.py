from __future__ import annotations

import unittest

from pc.gateway_crypto import GatewayCrypto, derive_pairing_key, generate_device_identity


TOKEN = "crypto-test-token-with-at-least-32-characters"


def crypto_pair() -> tuple[GatewayCrypto, GatewayCrypto]:
    phone_private, phone_public = generate_device_identity()
    pc_private, pc_public = generate_device_identity()
    phone = GatewayCrypto(TOKEN, "pair-1", "phone-1", private_key=phone_private,
                          peer_public_keys={"pc-1": pc_public})
    bridge = GatewayCrypto(TOKEN, "pair-1", "pc-1", private_key=pc_private,
                           peer_public_keys={"phone-1": phone_public})
    return phone, bridge


class GatewayCryptoTests(unittest.TestCase):
    def test_round_trip_and_replay_rejection(self) -> None:
        phone, bridge = crypto_pair()
        encrypted = phone.encrypt({"type": "ping", "text": "private task"}, "pc-1")
        self.assertEqual(encrypted["version"], 2)
        self.assertNotIn("private task", str(encrypted))
        self.assertEqual(bridge.decrypt(encrypted)["text"], "private task")
        with self.assertRaisesRegex(ValueError, "replayed"):
            bridge.decrypt(encrypted)

    def test_tampering_is_rejected(self) -> None:
        phone, bridge = crypto_pair()
        encrypted = phone.encrypt({"type": "ping"}, "pc-1")
        encrypted["counter"] = 2
        with self.assertRaises(Exception):
            bridge.decrypt(encrypted)

    def test_pairing_and_token_are_domain_separated(self) -> None:
        self.assertNotEqual(
            derive_pairing_key(TOKEN, "pair-1"),
            derive_pairing_key(TOKEN, "pair-2"),
        )


if __name__ == "__main__":
    unittest.main()
