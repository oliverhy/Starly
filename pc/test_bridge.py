import asyncio
import json
import queue
import unittest
import urllib.parse

from pc.starly_bridge import BridgeConfig, BridgeServer, MAX_TEXT_LENGTH, WindowsInput, find_available_port
from pc.codex_client import CodexAppServerClient, normalize_snapshot, normalize_thread


class FakeConnection:
    def __init__(self) -> None:
        self.messages: list[str] = []

    async def send(self, message: str) -> None:
        self.messages.append(message)


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

    def test_ctrl_enter_uses_balanced_key_sequence(self) -> None:
        windows_input = WindowsInput.__new__(WindowsInput)
        windows_input.foreground_window = lambda: (1, "测试窗口", 99999)
        windows_input._keyboard_input = lambda virtual_key, scan_code, flags: (virtual_key, scan_code, flags)
        sent: list[tuple[int, int, int]] = []
        windows_input._send = lambda inputs: not sent.extend(inputs)

        ok, _message = windows_input.press_submit("ctrl_enter")

        self.assertTrue(ok)
        self.assertEqual(sent, [
            (WindowsInput.VK_CONTROL, WindowsInput.SCAN_CONTROL, 0),
            (WindowsInput.VK_RETURN, WindowsInput.SCAN_RETURN, 0),
            (WindowsInput.VK_RETURN, WindowsInput.SCAN_RETURN, WindowsInput.KEYEVENTF_KEYUP),
            (WindowsInput.VK_CONTROL, WindowsInput.SCAN_CONTROL, WindowsInput.KEYEVENTF_KEYUP),
        ])

    def test_protocol_rejects_non_object_json(self) -> None:
        server = BridgeServer.__new__(BridgeServer)
        server.event_queue = queue.Queue()
        connection = FakeConnection()

        asyncio.run(server._handle_message(connection, "[]"))

        response = json.loads(connection.messages[0])
        self.assertEqual(response["type"], "error")
        self.assertEqual(response["message"], "消息必须是 JSON 对象")

    def test_codex_quota_is_reported_as_remaining_percent(self) -> None:
        snapshot = normalize_snapshot(
            {"rateLimits": {"primary": {"usedPercent": 34, "resetsAt": 123}, "planType": "prolite"}},
            {"summary": {"lifetimeTokens": 9000}},
            {"data": []},
        )
        self.assertEqual(snapshot["quota"]["remainingPercent"], 66)
        self.assertEqual(snapshot["quota"]["plan"], "prolite")
        self.assertEqual(snapshot["quota"]["lifetimeTokens"], 9000)

    def test_codex_thread_title_falls_back_to_workspace(self) -> None:
        thread = normalize_thread({"id": "t1", "name": "\ufffd\ufffd", "cwd": r"C:\work\Starly"})
        self.assertEqual(thread["title"], "Starly")

    def test_codex_message_resumes_persisted_thread_before_turn(self) -> None:
        client = CodexAppServerClient()
        calls: list[str] = []

        async def fake_request(method: str, _params: dict[str, object] | None = None,
                               timeout: float = 15) -> dict[str, object]:
            _ = timeout
            calls.append(method)
            if method == "thread/resume":
                return {"thread": {"id": "thread-1", "turns": []}}
            return {}

        client.request = fake_request
        asyncio.run(client.send_message("thread-1", "继续处理"))

        self.assertEqual(calls, ["thread/resume", "turn/start"])

    def test_desktop_thread_opens_only_after_turn_completed(self) -> None:
        server = BridgeServer.__new__(BridgeServer)
        server.pending_desktop_open = {"thread-1"}
        broadcasts: list[str] = []
        opened: list[str] = []

        async def fake_broadcast(message: dict[str, object]) -> None:
            broadcasts.append(str(message.get("event", "")))

        async def fake_refresh() -> None:
            return None

        async def fake_open(thread_id: str) -> None:
            opened.append(thread_id)

        server._broadcast = fake_broadcast
        server._schedule_codex_refresh = fake_refresh
        server._open_completed_codex_thread = fake_open

        async def exercise() -> None:
            await server._handle_codex_event("turn/started", {"threadId": "thread-1"})
            await asyncio.sleep(0)
            self.assertEqual(opened, [])
            self.assertIn("thread-1", server.pending_desktop_open)

            await server._handle_codex_event("turn/completed", {"threadId": "thread-1"})
            await asyncio.sleep(0)

        asyncio.run(exercise())

        self.assertEqual(opened, ["thread-1"])
        self.assertNotIn("thread-1", server.pending_desktop_open)
        self.assertEqual(broadcasts, ["turn/started", "turn/completed"])


if __name__ == "__main__":
    unittest.main()
