import asyncio
import base64
import ctypes
import json
import os
import queue
import tempfile
import unittest
import urllib.parse
from pathlib import Path
from ctypes import wintypes
from unittest import mock

from pc.starly_bridge import (BridgeConfig, BridgeServer, CODEX_COMPOSER_FOCUS_SCRIPT,
                              MAX_IMAGE_BYTES, MAX_TEXT_LENGTH, WindowsInput,
                              find_available_port)
from pc.codex_client import (CodexAppServerClient, _item_content, normalize_snapshot,
                             normalize_thread, read_rollout_thread_detail)


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

    def test_codex_image_payload_decodes_with_size_limit(self) -> None:
        encoded = base64.b64encode(b"test-image").decode("ascii")
        decoded = BridgeServer._decode_image_data(f"data:image/jpeg;base64,{encoded}")
        self.assertEqual(decoded, b"test-image")
        self.assertEqual(MAX_IMAGE_BYTES, 6 * 1024 * 1024)

    def test_codex_image_payload_rejects_non_image_data(self) -> None:
        with self.assertRaises(ValueError):
            BridgeServer._decode_image_data("not-an-image")

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

    @unittest.skipUnless(os.name == "nt", "Windows API prototype test")
    def test_windows_clipboard_uses_pointer_sized_memory_handles(self) -> None:
        windows_input = WindowsInput()
        self.assertIs(windows_input.kernel32.GlobalAlloc.restype, wintypes.HGLOBAL)
        self.assertIs(windows_input.kernel32.GlobalLock.restype, ctypes.c_void_p)
        self.assertIs(windows_input.user32.SetClipboardData.restype, wintypes.HANDLE)

    def test_codex_desktop_send_opens_focuses_types_and_submits(self) -> None:
        server = BridgeServer.__new__(BridgeServer)

        class FakeInput:
            def type_text(self, text: str, submit_mode: str) -> tuple[bool, str]:
                self.received = (text, submit_mode)
                return True, "submitted"

        fake_input = FakeInput()
        server.input = fake_input
        with mock.patch("pc.starly_bridge.open_codex_thread", return_value=True) as opened, \
                mock.patch("pc.starly_bridge.focus_codex_composer",
                           return_value=(True, "focused")) as focused:
            ok, message = server._send_to_codex_desktop(
                "thread-1", "指定任务", "继续处理这个要求", "ctrl_enter")

        self.assertTrue(ok)
        self.assertIn("submitted", message)
        opened.assert_called_once_with("thread-1")
        focused.assert_called_once_with("指定任务")
        self.assertEqual(fake_input.received, ("继续处理这个要求", "ctrl_enter"))

    def test_codex_composer_focus_does_not_require_workspace_title_in_header(self) -> None:
        self.assertNotIn("$titleLoaded", CODEX_COMPOSER_FOCUS_SCRIPT)
        self.assertIn("if ($null -ne $composer)", CODEX_COMPOSER_FOCUS_SCRIPT)

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

    def test_codex_snapshot_restarts_stalled_idle_client_once(self) -> None:
        client = CodexAppServerClient()
        failures = 0
        stops = 0

        async def fake_request(method: str, _params: dict[str, object] | None = None,
                               timeout: float = 15) -> dict[str, object]:
            nonlocal failures
            _ = timeout
            if method == "account/rateLimits/read" and failures == 0:
                failures += 1
                raise TimeoutError()
            if method == "thread/list":
                return {"data": []}
            return {}

        async def fake_stop() -> None:
            nonlocal stops
            stops += 1

        client.request = fake_request
        client.stop = fake_stop
        snapshot = asyncio.run(client.snapshot())

        self.assertTrue(snapshot["available"])
        self.assertEqual(stops, 1)

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

    def test_codex_history_preserves_remote_images(self) -> None:
        role, text, images = _item_content({
            "type": "userMessage",
            "content": [
                {"type": "text", "text": "看看这张图"},
                {"type": "image", "url": "https://example.com/test.png"},
            ],
        })
        self.assertEqual(role, "user")
        self.assertEqual(text, "看看这张图")
        self.assertEqual(images, ["https://example.com/test.png"])

    def test_codex_history_extracts_markdown_images(self) -> None:
        role, text, images = _item_content({
            "type": "agentMessage",
            "text": "结果如下：![预览](https://example.com/result.png)",
        })
        self.assertEqual(role, "assistant")
        self.assertEqual(text, "结果如下：预览")
        self.assertEqual(images, ["https://example.com/result.png"])

    def test_large_codex_history_uses_recent_local_messages(self) -> None:
        thread_id = "019f5e50-657d-7da2-8661-3700565b2d2e"
        with tempfile.TemporaryDirectory() as temp_dir:
            codex_home = Path(temp_dir)
            session_dir = codex_home / "sessions" / "2026" / "07" / "15"
            session_dir.mkdir(parents=True)
            rollout = session_dir / f"rollout-test-{thread_id}.jsonl"
            records = [
                {"timestamp": "2026-07-15T01:00:00Z", "type": "session_meta",
                 "payload": {"session_id": thread_id, "cwd": r"C:\work\Starly"}},
                {"timestamp": "2026-07-15T01:00:01Z", "type": "event_msg",
                 "payload": {"type": "task_started", "turn_id": "turn-1"}},
                {"timestamp": "2026-07-15T01:00:02Z", "type": "response_item",
                 "payload": {"type": "message", "role": "user",
                             "content": [{"type": "input_text", "text": "测试任务"}],
                             "internal_chat_message_metadata_passthrough": {
                                 "turn_id": "turn-1"}}},
                {"timestamp": "2026-07-15T01:00:03Z", "type": "event_msg",
                 "payload": {"type": "agent_message", "message": "正在处理",
                             "phase": "commentary"}},
            ]
            rollout.write_text("\n".join(json.dumps(item, ensure_ascii=False)
                                           for item in records) + "\n", encoding="utf-8")
            (codex_home / "session_index.jsonl").write_text(json.dumps({
                "id": thread_id, "thread_name": "本地大任务",
            }, ensure_ascii=False) + "\n", encoding="utf-8")

            with mock.patch.dict(os.environ, {"CODEX_HOME": temp_dir}):
                detail = read_rollout_thread_detail(thread_id)

        self.assertIsNotNone(detail)
        assert detail is not None
        self.assertEqual(detail["title"], "本地大任务")
        self.assertEqual(detail["status"], "active")
        self.assertEqual(detail["activeTurnId"], "turn-1")
        self.assertEqual([item["text"] for item in detail["messages"]],
                         ["测试任务", "正在处理"])

    def test_persisted_completion_replaces_stale_active_cache(self) -> None:
        thread_id = "019f5e50-657d-7da2-8661-3700565b2d2e"
        with tempfile.TemporaryDirectory() as temp_dir:
            codex_home = Path(temp_dir)
            session_dir = codex_home / "sessions" / "2026" / "07" / "15"
            session_dir.mkdir(parents=True)
            rollout = session_dir / f"rollout-test-{thread_id}.jsonl"
            records = [
                {"timestamp": "2026-07-15T01:00:00Z", "type": "session_meta",
                 "payload": {"session_id": thread_id, "cwd": r"C:\work\Starly"}},
                {"timestamp": "2026-07-15T01:00:01Z", "type": "event_msg",
                 "payload": {"type": "task_started", "turn_id": "turn-1"}},
                {"timestamp": "2026-07-15T01:00:02Z", "type": "event_msg",
                 "payload": {"type": "agent_message", "message": "completed"}},
                {"timestamp": "2026-07-15T01:00:03Z", "type": "event_msg",
                 "payload": {"type": "task_complete", "turn_id": "turn-1"}},
            ]
            rollout.write_text("\n".join(json.dumps(item, ensure_ascii=False)
                                           for item in records) + "\n", encoding="utf-8")
            client = CodexAppServerClient()
            client.thread_status[thread_id] = "active"

            with mock.patch.dict(os.environ, {"CODEX_HOME": temp_dir}):
                detail = asyncio.run(client.thread_detail(thread_id))

        self.assertEqual(detail["status"], "idle")
        self.assertEqual(detail["activeTurnId"], "")
        self.assertEqual(client.thread_status[thread_id], "idle")

    def test_persisted_aborted_turn_is_idle(self) -> None:
        thread_id = "019f5e50-657d-7da2-8661-3700565b2d2e"
        with tempfile.TemporaryDirectory() as temp_dir:
            codex_home = Path(temp_dir)
            session_dir = codex_home / "sessions" / "2026" / "07" / "15"
            session_dir.mkdir(parents=True)
            rollout = session_dir / f"rollout-test-{thread_id}.jsonl"
            records = [
                {"timestamp": "2026-07-15T01:00:00Z", "type": "session_meta",
                 "payload": {"session_id": thread_id, "cwd": r"C:\work\Starly"}},
                {"timestamp": "2026-07-15T01:00:01Z", "type": "event_msg",
                 "payload": {"type": "task_started", "turn_id": "turn-1"}},
                {"timestamp": "2026-07-15T01:00:02Z", "type": "event_msg",
                 "payload": {"type": "turn_aborted", "turn_id": "turn-1"}},
            ]
            rollout.write_text("\n".join(json.dumps(item, ensure_ascii=False)
                                            for item in records) + "\n", encoding="utf-8")

            with mock.patch.dict(os.environ, {"CODEX_HOME": temp_dir}):
                detail = read_rollout_thread_detail(thread_id)

        self.assertIsNotNone(detail)
        assert detail is not None
        self.assertEqual(detail["status"], "idle")
        self.assertEqual(detail["activeTurnId"], "")

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

    def test_poll_detects_completion_when_history_stays_capped(self) -> None:
        server = BridgeServer.__new__(BridgeServer)
        thread_id = "thread-long-history"
        old_messages = [
            {"role": "assistant", "text": f"old-{index}", "timestamp": index,
             "turnId": f"turn-{index}", "images": []}
            for index in range(15)
        ]
        active_messages = old_messages[1:] + [
            {"role": "user", "text": "new request", "timestamp": 16,
             "turnId": "turn-new", "images": []},
        ]
        completed_messages = active_messages[1:] + [
            {"role": "assistant", "text": "new reply", "timestamp": 17,
             "turnId": "turn-new", "images": []},
        ]

        class FakeCodex:
            def __init__(self) -> None:
                self.details = [
                    {"id": thread_id, "status": "active", "activeTurnId": "turn-new",
                     "messages": active_messages},
                    {"id": thread_id, "status": "idle", "activeTurnId": "",
                     "messages": completed_messages},
                ]

            async def thread_detail(self, requested_id: str) -> dict[str, object]:
                self_test.assertEqual(requested_id, thread_id)
                return self.details.pop(0)

        self_test = self
        broadcasts: list[dict[str, object]] = []

        async def fake_broadcast(message: dict[str, object]) -> None:
            broadcasts.append(message)

        async def fake_refresh() -> None:
            return None

        async def fake_sleep(_seconds: float) -> None:
            return None

        server.codex = FakeCodex()
        server.codex_poll_tasks = {}
        server._broadcast = fake_broadcast
        server._schedule_codex_refresh = fake_refresh
        baseline = BridgeServer._latest_message_signature({"messages": old_messages})

        async def exercise() -> None:
            server.codex_poll_tasks[thread_id] = asyncio.current_task()
            await server._poll_desktop_codex_thread(thread_id, baseline)

        with mock.patch("pc.starly_bridge.asyncio.sleep", new=fake_sleep):
            asyncio.run(exercise())

        self.assertTrue(all(len(item["thread"]["messages"]) == 15
                            for item in broadcasts if item.get("type") == "codex_thread"))
        self.assertTrue(any(item.get("event") == "turn/completed" for item in broadcasts))
        self.assertNotIn(thread_id, server.codex_poll_tasks)

    def test_poll_terminal_event_preserves_failures_and_unknown_states(self) -> None:
        self.assertEqual(BridgeServer._terminal_poll_event("idle", True), "turn/completed")
        self.assertEqual(BridgeServer._terminal_poll_event("systemError", True), "turn/failed")
        self.assertEqual(BridgeServer._terminal_poll_event("idle", False), "")
        self.assertEqual(BridgeServer._terminal_poll_event("notLoaded", True), "")
        self.assertEqual(BridgeServer._terminal_poll_event("queued", True), "")

    def test_latest_message_detects_fast_turn_without_assistant_reply(self) -> None:
        before = {"messages": [
            {"role": "assistant", "text": "old reply", "timestamp": 1,
             "turnId": "turn-old", "images": []},
        ]}
        after = {"messages": [
            {"role": "assistant", "text": "old reply", "timestamp": 1,
             "turnId": "turn-old", "images": []},
            {"role": "user", "text": "new request", "timestamp": 2,
             "turnId": "turn-new", "images": []},
        ]}
        self.assertNotEqual(BridgeServer._latest_message_signature(before),
                            BridgeServer._latest_message_signature(after))

    def test_failed_codex_event_is_not_reported_as_success(self) -> None:
        server = BridgeServer.__new__(BridgeServer)
        server.pending_desktop_open = set()
        broadcasts: list[str] = []

        async def fake_broadcast(message: dict[str, object]) -> None:
            broadcasts.append(str(message.get("event", "")))

        async def fake_refresh() -> None:
            return None

        server._broadcast = fake_broadcast
        server._schedule_codex_refresh = fake_refresh

        asyncio.run(server._handle_codex_event("turn/completed", {
            "threadId": "thread-failed", "turn": {"status": "failed"},
        }))

        self.assertEqual(broadcasts, ["turn/failed"])

    def test_completed_turn_releases_bridge_runtime_before_desktop_open(self) -> None:
        server = BridgeServer.__new__(BridgeServer)
        server.codex_refresh_task = None
        order: list[str] = []

        class FakeCodex:
            async def release_thread(self, thread_id: str) -> None:
                order.append(f"release:{thread_id}")

            async def stop(self) -> None:
                order.append("stop")

        async def fake_broadcast(message: dict[str, object]) -> None:
            order.append(str(message.get("event", "")))

        async def fake_refresh() -> None:
            order.append("refresh")

        server.codex = FakeCodex()
        server._broadcast = fake_broadcast
        server._schedule_codex_refresh = fake_refresh

        import pc.starly_bridge as bridge_module
        original_open = bridge_module.open_codex_thread
        bridge_module.open_codex_thread = lambda thread_id: not order.append(f"open:{thread_id}")
        try:
            asyncio.run(server._open_completed_codex_thread("thread-1"))
        finally:
            bridge_module.open_codex_thread = original_open

        self.assertEqual(order, [
            "release:thread-1", "stop", "open:thread-1", "desktop/opened", "refresh",
        ])

    def test_codex_refresh_announces_when_reads_are_safe_again(self) -> None:
        server = BridgeServer.__new__(BridgeServer)
        server.connections = {object()}
        events: list[str] = []

        class FakeCodex:
            async def snapshot(self) -> dict[str, object]:
                return {"available": True, "quota": {}, "threads": []}

        async def fake_broadcast(message: dict[str, object]) -> None:
            events.append(str(message.get("event", message.get("type", ""))))

        server.codex = FakeCodex()
        server._broadcast = fake_broadcast

        asyncio.run(server._delayed_codex_refresh())

        self.assertEqual(events, ["codex_snapshot", "codex/refreshReady"])


if __name__ == "__main__":
    unittest.main()
