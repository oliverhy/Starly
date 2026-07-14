import unittest
import urllib.parse

from pc.starly_bridge import BridgeConfig, BridgeServer, MAX_TEXT_LENGTH, find_available_port


class BridgeProtocolTests(unittest.TestCase):
    def test_token_is_delivery_strength(self) -> None:
        config = BridgeConfig()
        self.assertGreaterEqual(len(config.token), 32)

    def test_private_network_filter(self) -> None:
        self.assertTrue(BridgeServer._is_allowed_address("192.168.1.8"))
        self.assertTrue(BridgeServer._is_allowed_address("127.0.0.1"))
        self.assertFalse(BridgeServer._is_allowed_address("8.8.8.8"))

    def test_pairing_uri_round_trip(self) -> None:
        token = BridgeConfig().token
        uri = "starly://pair?" + urllib.parse.urlencode({"host": "192.168.1.2", "port": 8765, "token": token})
        query = urllib.parse.parse_qs(urllib.parse.urlparse(uri).query)
        self.assertEqual(query["token"][0], token)
        self.assertEqual(int(query["port"][0]), 8765)

    def test_text_limit_is_bounded(self) -> None:
        self.assertEqual(MAX_TEXT_LENGTH, 8000)

    def test_port_selection_returns_valid_port(self) -> None:
        selected = find_available_port()
        self.assertGreater(selected, 0)
        self.assertLessEqual(selected, 65535)


if __name__ == "__main__":
    unittest.main()
