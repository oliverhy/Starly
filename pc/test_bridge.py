import asyncio
import base64
import ctypes
import io
import json
import os
import queue
import sqlite3
import tempfile
import unittest
import urllib.parse
from pathlib import Path
from ctypes import wintypes
from unittest import mock

from PIL import Image

from pc.starly_bridge import (BridgeApp, BridgeConfig, BridgeServer, CODEX_COMPOSER_FOCUS_SCRIPT,
                              CODEX_COMPOSER_SETTINGS_SCRIPT,
                              DEFAULT_DISCOVERY_PORT, DISCOVERY_PROTOCOL_VERSION,
                              DiscoveryProtocol, MAX_IMAGE_BYTES, MAX_TEXT_LENGTH,
                              WindowsInput, desktop_effort_labels,
                              desktop_model_labels, desktop_permission_labels,
                              desktop_speed_labels, find_available_port,
                              format_paired_devices, normalize_approval,
                              normalize_gateway_url)
from pc.codex_client import (CodexAppServerClient, _item_content, normalize_snapshot,
                             normalize_thread, read_rollout_thread_detail,
                             read_thread_goal)
from pc.codex_queue import CodexQueueItem, CodexQueueStore


class FakeConnection:
    def __init__(self) -> None:
        self.messages: list[str] = []

    async def send(self, message: str) -> None:
        self.messages.append(message)


class BridgeProtocolTests(unittest.TestCase):
    @staticmethod
    async def _append_async(target: list[dict[str, object]],
                            message: dict[str, object]) -> None:
        target.append(message)

    @staticmethod
    async def _noop_async() -> None:
        return None

    def test_read_thread_goal_returns_structured_read_only_goal(self) -> None:
        thread_id = "019fda4e-1111-7222-8333-123456789abc"
        with tempfile.TemporaryDirectory() as temp_dir:
            database_path = Path(temp_dir) / "goals_1.sqlite"
            connection = sqlite3.connect(database_path)
            connection.execute(
                """CREATE TABLE thread_goals (
                    thread_id TEXT PRIMARY KEY, goal_id TEXT, objective TEXT,
                    status TEXT, token_budget INTEGER, tokens_used INTEGER,
                    time_used_seconds INTEGER, created_at_ms INTEGER,
                    updated_at_ms INTEGER)""")
            connection.execute(
                "INSERT INTO thread_goals VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
                (thread_id, "goal-1", "完成手机目标同步", "usage_limited",
                 900000, 12345, 33960, 1000, 2000))
            connection.commit()
            connection.close()

            goal = read_thread_goal(thread_id, database_path)

        self.assertEqual(goal["goalId"], "goal-1")
        self.assertEqual(goal["objective"], "完成手机目标同步")
        self.assertEqual(goal["status"], "usage_limited")
        self.assertEqual(goal["timeUsedSeconds"], 33960)

    def test_phone_thread_detail_includes_goal_without_logging_objective(self) -> None:
        goal = {"goalId": "goal-1", "objective": "敏感目标正文", "status": "active"}
        with mock.patch("pc.starly_bridge.read_thread_goal", return_value=goal):
            payload = BridgeServer._phone_thread_detail({
                "id": "019fda4e-1111-7222-8333-123456789abc", "messages": []})

        self.assertEqual(payload["goal"], goal)
        safe = BridgeServer._safe_log_value(payload)
        self.assertEqual(safe["goal"]["objective"], "[已隐藏]")

    def test_open_log_location_opens_bridge_config_directory(self) -> None:
        app = BridgeApp.__new__(BridgeApp)
        app.root = object()
        with tempfile.TemporaryDirectory() as temp_dir:
            log_dir = Path(temp_dir) / "StarlyBridge"
            with mock.patch("pc.starly_bridge.CONFIG_DIR", log_dir), \
                    mock.patch("pc.starly_bridge.os.startfile") as startfile:
                app.open_log_location()

            self.assertTrue(log_dir.is_dir())
            startfile.assert_called_once_with(str(log_dir))

    def test_paired_device_summary_includes_gateway_online_and_offline_phones(self) -> None:
        summary = format_paired_devices({"192.168.2.71:37287"}, {
            "phone-1": {"displayName": "新手机", "online": True},
            "phone-2": {"displayName": "备用手机", "online": False},
        })
        self.assertIn("已配对 3 部手机 · 在线 2 部", summary)
        self.assertIn("192.168.2.71:37287 · 局域网在线", summary)
        self.assertIn("新手机 · 公网在线", summary)
        self.assertIn("备用手机 · 公网已配对（离线）", summary)

    def test_paired_device_summary_deduplicates_same_phone_across_channels(self) -> None:
        summary = format_paired_devices({"phone-1"}, {
            "phone-1": {"displayName": "主手机", "online": True},
            "phone-2": {"displayName": "备用手机", "online": False},
        })
        self.assertIn("已配对 2 部手机 · 在线 1 部", summary)
        self.assertIn("主手机 · 局域网在线 · 公网在线", summary)

    def test_approval_normalization_extracts_nested_context(self) -> None:
        approval = normalize_approval("item/commandExecution/requestApproval", {
            "approvalId": "approval-1",
            "item": {
                "command": ["python", "-m", "unittest"],
                "workingDirectory": r"C:\work\Starly",
            },
            "justification": "运行项目测试",
        })
        self.assertEqual(approval["command"], "python -m unittest")
        self.assertEqual(approval["cwd"], r"C:\work\Starly")
        self.assertEqual(approval["reason"], "运行项目测试")
        self.assertEqual(approval["riskLevel"], "medium")
        self.assertFalse(approval["highRisk"])

    def test_approval_normalization_flags_destructive_and_permission_requests(self) -> None:
        destructive = normalize_approval("item/commandExecution/requestApproval", {
            "command": "Remove-Item -Recurse C:\\work\\cache",
        })
        write_command = normalize_approval("item/commandExecution/requestApproval", {
            "command": "Set-Content C:\\Windows\\Temp\\probe.txt test",
        })
        permission = normalize_approval("item/permissions/requestApproval", {
            "permissions": {"network": True, "fileSystem": "unrestricted"},
        })
        self.assertEqual(destructive["riskLevel"], "high")
        self.assertTrue(destructive["highRisk"])
        self.assertTrue(write_command["highRisk"])
        self.assertEqual(permission["riskLevel"], "high")
        self.assertIn("network=true", permission["permissionsSummary"])

    def test_token_is_delivery_strength(self) -> None:
        config = BridgeConfig()
        self.assertGreaterEqual(len(config.token), 32)
        self.assertGreaterEqual(len(config.gateway_token), 32)

    def test_gateway_token_can_be_separate_from_lan_token(self) -> None:
        lan_token = "lan-token-with-at-least-32-characters"
        gateway_token = "gateway-token-with-at-least-32-characters"
        config = BridgeConfig(token=lan_token, gateway_token=gateway_token)
        self.assertEqual(config.token, lan_token)
        self.assertEqual(config.gateway_token, gateway_token)

    def test_gateway_uses_persistent_random_device_identity(self) -> None:
        config = BridgeConfig()
        self.assertRegex(config.gateway_device_id, r"^bridge-[0-9a-f]{24}$")

    def test_gateway_url_normalization_requires_secure_public_transport(self) -> None:
        self.assertEqual(normalize_gateway_url("starly.example.com"),
                         "wss://starly.example.com/ws")
        self.assertEqual(normalize_gateway_url("wss://203.0.113.10:9443/"),
                         "wss://203.0.113.10:9443/ws")
        self.assertEqual(normalize_gateway_url("ws://127.0.0.1:8780/ws"),
                         "ws://127.0.0.1:8780/ws")
        with self.assertRaisesRegex(ValueError, "wss"):
            normalize_gateway_url("ws://starly.example.com/ws")
        with self.assertRaises(ValueError):
            normalize_gateway_url("wss://user:secret@starly.example.com/ws")

    def test_pairing_code_has_exactly_six_digits(self) -> None:
        config = BridgeConfig()
        self.assertRegex(config.pairing_code, r"^\d{6}$")
        previous = config.pairing_code
        config.rotate_pairing_code()
        self.assertRegex(config.pairing_code, r"^\d{6}$")
        self.assertNotEqual(config.pairing_code, previous)

    def test_discovery_offer_never_exposes_long_token_or_pairing_code(self) -> None:
        class FakeTransport:
            def __init__(self) -> None:
                self.packets: list[tuple[bytes, tuple[str, int]]] = []

            def sendto(self, data: bytes, addr: tuple[str, int]) -> None:
                self.packets.append((data, addr))

        server = BridgeServer.__new__(BridgeServer)
        server.config = BridgeConfig()
        server.event_queue = queue.Queue()
        protocol = DiscoveryProtocol(server)
        transport = FakeTransport()
        protocol.transport = transport
        request = json.dumps({
            "type": "starly_discover",
            "version": DISCOVERY_PROTOCOL_VERSION,
            "nonce": "discovery-test",
        }).encode("utf-8")

        protocol.datagram_received(request, ("192.168.1.20", 40123))

        self.assertEqual(len(transport.packets), 1)
        offer = json.loads(transport.packets[0][0].decode("utf-8"))
        self.assertEqual(offer["type"], "starly_offer")
        self.assertEqual(offer["pairingPort"], DEFAULT_DISCOVERY_PORT)
        self.assertNotIn("token", offer)
        self.assertNotIn("code", offer)

    @mock.patch.object(BridgeConfig, "save")
    def test_six_digit_pairing_returns_long_token_then_rotates_code(self, _save: mock.Mock) -> None:
        class FakeTransport:
            def __init__(self) -> None:
                self.packets: list[tuple[bytes, tuple[str, int]]] = []

            def sendto(self, data: bytes, addr: tuple[str, int]) -> None:
                self.packets.append((data, addr))

        server = BridgeServer.__new__(BridgeServer)
        server.config = BridgeConfig(pairing_code="123456")
        server.event_queue = queue.Queue()
        protocol = DiscoveryProtocol(server)
        transport = FakeTransport()
        protocol.transport = transport
        request = json.dumps({
            "type": "starly_pair",
            "version": DISCOVERY_PROTOCOL_VERSION,
            "nonce": "pairing-test",
            "code": "123456",
        }).encode("utf-8")

        protocol.datagram_received(request, ("192.168.1.20", 40123))

        response = json.loads(transport.packets[0][0].decode("utf-8"))
        self.assertEqual(response["type"], "starly_paired")
        self.assertEqual(response["token"], server.config.token)
        self.assertNotEqual(server.config.pairing_code, "123456")

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
                mock.patch("pc.starly_bridge.configure_codex_composer",
                           return_value=(True, "configured")) as configured, \
                mock.patch("pc.starly_bridge.focus_codex_composer",
                           return_value=(True, "focused")) as focused:
            ok, message = server._send_to_codex_desktop(
                "thread-1", "指定任务", "继续处理这个要求", "ctrl_enter",
                "gpt-5.6-sol", "high", "fullAccess", "fast")

        self.assertTrue(ok)
        self.assertIn("submitted", message)
        opened.assert_called_once_with("thread-1")
        configured.assert_called_once_with("gpt-5.6-sol", "high", "fullAccess", "fast")
        focused.assert_called_once_with("指定任务")
        self.assertEqual(fake_input.received, ("继续处理这个要求", "ctrl_enter"))

    def test_codex_composer_focus_uses_real_control_bounds_before_coordinates(self) -> None:
        self.assertNotIn("$titleLoaded", CODEX_COMPOSER_FOCUS_SCRIPT)
        self.assertIn("TreeScope]::Descendants", CODEX_COMPOSER_FOCUS_SCRIPT)
        self.assertIn("ClassName -match '(^| )ProseMirror( |$)'",
                      CODEX_COMPOSER_FOCUS_SCRIPT)
        self.assertIn("BoundingRectangle", CODEX_COMPOSER_FOCUS_SCRIPT)
        self.assertIn("IsOffscreen", CODEX_COMPOSER_FOCUS_SCRIPT)
        self.assertIn("@(0.35, 0.50, 0.62, 0.74)", CODEX_COMPOSER_FOCUS_SCRIPT)
        self.assertNotIn("@(0.57, 0.70)", CODEX_COMPOSER_FOCUS_SCRIPT)
        self.assertNotIn("AutomationElement]::RootElement", CODEX_COMPOSER_FOCUS_SCRIPT)

    def test_desktop_setting_labels_match_codex_choices(self) -> None:
        self.assertIn("5.6 sol", [item.lower() for item in desktop_model_labels("gpt-5.6-sol")])
        self.assertIn("High", desktop_effort_labels("high"))
        self.assertIn("Full access", desktop_permission_labels("fullAccess"))
        self.assertIn("Standard", desktop_speed_labels("standard"))
        self.assertIn("Open model picker", CODEX_COMPOSER_SETTINGS_SCRIPT)

    def test_codex_send_uses_background_mode_without_desktop_automation(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            server = BridgeServer.__new__(BridgeServer)
            server.codex_queue = CodexQueueStore(
                Path(directory) / "queue.json", lambda value: value, lambda value: value)
            server.connections = set()
            sent: list[tuple[str, str, bool]] = []
            responses: list[dict[str, object]] = []

            class FakeCodex:
                async def thread_detail(self, _thread_id: str) -> dict[str, object]:
                    return {"title": "指定任务", "status": "idle", "messages": []}

                async def send_message(self, thread_id: str, text: str, *_args: object,
                                       allow_steer: bool = True) -> dict[str, object]:
                    sent.append((thread_id, text, allow_steer))
                    asyncio.get_running_loop().call_soon(
                        server._signal_codex_queue_terminal, thread_id, "completed")
                    return {}

            async def scenario() -> None:
                server.codex = FakeCodex()
                server._send_json = lambda _connection, message: self._append_async(
                    responses, message)
                server._schedule_codex_refresh = lambda: self._noop_async()
                await server._codex_send(
                    object(), "thread-1", "继续处理", "enter", "message-1")
                await asyncio.gather(*list(server.codex_queue_tasks.values()))

            asyncio.run(scenario())

            self.assertEqual(sent, [("thread-1", "继续处理", False)])
            self.assertEqual(responses[0]["type"], "ack")
            self.assertEqual(responses[0]["queueId"], "message-1")
            self.assertEqual(server.codex_queue.get("message-1").state, "completed")

    def test_codex_desktop_mode_failure_never_falls_back(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            server = BridgeServer.__new__(BridgeServer)
            server.codex_queue = CodexQueueStore(
                Path(directory) / "queue.json", lambda value: value, lambda value: value)
            server.connections = set()
            responses: list[dict[str, object]] = []
            server._send_json = lambda _connection, message: self._append_async(
                responses, message)

            asyncio.run(server._codex_send(
                object(), "thread-1", "继续处理", "enter", "message-1",
                delivery_mode="desktop"))

            self.assertEqual(responses[0]["type"], "ack")
            self.assertEqual(server.codex_queue.get("message-1").state, "queued")

    def test_codex_image_desktop_mode_pastes_image_with_selected_settings(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            server = BridgeServer.__new__(BridgeServer)
            server.codex_queue = CodexQueueStore(
                Path(directory) / "queue.json", lambda value: value, lambda value: value)
            server.connections = set()
            responses: list[dict[str, object]] = []
            image_data = "data:image/jpeg;base64," + base64.b64encode(b"image").decode("ascii")
            server._send_json = lambda _connection, message: self._append_async(
                responses, message)

            asyncio.run(server._codex_image_send(
                object(), "thread-2", "观察图片", "enter", image_data, "message-2",
                "gpt-5.6-sol", "high", "fullAccess", "fast", "desktop"))

            item = server.codex_queue.get("message-2")
            self.assertTrue(item.has_image)
            self.assertEqual(item.model, "gpt-5.6-sol")
            self.assertEqual(responses[0]["operation"], "codex_image_send")

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

    def test_codex_snapshot_includes_visible_model_catalog(self) -> None:
        snapshot = normalize_snapshot({}, {}, {"data": []}, {"data": [
            {"model": "gpt-5.6-sol", "hidden": False},
            {"model": "hidden-model", "hidden": True},
        ]})
        self.assertEqual(snapshot["models"], [
            {"model": "gpt-5.6-sol", "hidden": False},
        ])

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

    def test_codex_snapshot_can_merge_archived_tasks(self) -> None:
        client = CodexAppServerClient()
        requested_archived: list[bool] = []

        async def fake_request(method: str, params: dict[str, object] | None = None,
                               timeout: float = 15) -> dict[str, object]:
            _ = timeout
            if method == "thread/list":
                archived = bool((params or {}).get("archived", False))
                requested_archived.append(archived)
                suffix = "archived" if archived else "active"
                return {"data": [{"id": suffix, "title": suffix}]}
            return {}

        client.request = fake_request
        snapshot = asyncio.run(client.snapshot(include_archived=True))

        self.assertEqual(requested_archived, [False, True])
        by_id = {item["id"]: item for item in snapshot["threads"]}
        self.assertFalse(by_id["active"]["archived"])
        self.assertTrue(by_id["archived"]["archived"])

    def test_codex_archive_uses_official_app_server_methods(self) -> None:
        client = CodexAppServerClient()
        calls: list[tuple[str, dict[str, object]]] = []

        async def fake_request(method: str, params: dict[str, object] | None = None,
                               timeout: float = 15) -> dict[str, object]:
            _ = timeout
            calls.append((method, params or {}))
            return {}

        client.request = fake_request
        asyncio.run(client.set_archived("thread-1", True))
        asyncio.run(client.set_archived("thread-1", False))

        self.assertEqual(calls, [
            ("thread/archive", {"threadId": "thread-1"}),
            ("thread/unarchive", {"threadId": "thread-1"}),
        ])

    def test_codex_rename_uses_official_app_server_method(self) -> None:
        client = CodexAppServerClient()
        calls: list[tuple[str, dict[str, object]]] = []

        async def fake_request(method: str, params: dict[str, object] | None = None,
                               timeout: float = 15) -> dict[str, object]:
            _ = timeout
            calls.append((method, params or {}))
            return {}

        client.request = fake_request
        asyncio.run(client.rename_thread("thread-1", "新的任务名称"))

        self.assertEqual(calls, [
            ("thread/name/set", {"threadId": "thread-1", "name": "新的任务名称"}),
        ])

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

    def test_queue_send_refuses_to_steer_an_active_turn(self) -> None:
        client = CodexAppServerClient()
        calls: list[str] = []

        async def fake_request(method: str, _params: dict[str, object] | None = None,
                               timeout: float = 15) -> dict[str, object]:
            _ = timeout
            calls.append(method)
            if method == "thread/resume":
                return {"thread": {"id": "thread-1", "turns": [
                    {"id": "turn-active", "status": "inProgress", "items": []},
                ]}}
            return {}

        client.request = fake_request
        with self.assertRaisesRegex(RuntimeError, "queue must wait"):
            asyncio.run(client.send_message(
                "thread-1", "第二条", allow_steer=False))

        self.assertEqual(calls, ["thread/resume"])

    def test_codex_message_applies_remote_model_effort_and_read_only_mode(self) -> None:
        client = CodexAppServerClient()
        calls: list[tuple[str, dict[str, object]]] = []

        async def fake_request(method: str, params: dict[str, object] | None = None,
                               timeout: float = 15) -> dict[str, object]:
            _ = timeout
            calls.append((method, params or {}))
            if method == "thread/resume":
                return {"thread": {"id": "thread-1", "turns": []}}
            return {}

        client.request = fake_request
        asyncio.run(client.send_message(
            "thread-1", "继续处理", "gpt-5.6-sol", "high", "readOnly", "", "priority"))

        settings = calls[1][1]
        self.assertEqual(calls[1][0], "thread/settings/update")
        self.assertEqual(settings["model"], "gpt-5.6-sol")
        self.assertEqual(settings["effort"], "high")
        self.assertEqual(settings["serviceTier"], "priority")
        self.assertEqual(settings["approvalPolicy"], "on-request")
        self.assertEqual(settings["sandboxPolicy"], {
            "type": "readOnly", "networkAccess": False,
        })
        self.assertEqual(calls[2][0], "turn/start")

    def test_full_access_mode_disables_approval_and_sandbox(self) -> None:
        settings = CodexAppServerClient._turn_settings(
            "gpt-5.6-sol", "medium", "fullAccess")
        self.assertEqual(settings["approvalPolicy"], "never")
        self.assertEqual(settings["sandboxPolicy"], {"type": "dangerFullAccess"})

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

    def test_rollout_exposes_generated_image_as_paginated_message(self) -> None:
        thread_id = "019f5e50-657d-7da2-8661-3700565b2d2e"
        with tempfile.TemporaryDirectory() as temp_dir:
            session_dir = Path(temp_dir) / "sessions" / "2026" / "07" / "15"
            session_dir.mkdir(parents=True)
            generated = Path(temp_dir) / "generated.png"
            Image.new("RGB", (32, 24), "#336699").save(generated)
            rollout = session_dir / f"rollout-test-{thread_id}.jsonl"
            records = [
                {"timestamp": "2026-07-15T01:00:00Z", "type": "session_meta",
                 "payload": {"session_id": thread_id, "cwd": r"C:\work\Starly"}},
                {"timestamp": "2026-07-15T01:00:01Z", "type": "event_msg",
                 "payload": {"type": "task_started", "turn_id": "turn-1"}},
                {"timestamp": "2026-07-15T01:00:02Z", "type": "event_msg",
                 "payload": {"type": "image_generation_end", "turn_id": "turn-1",
                             "status": "completed", "saved_path": str(generated)}},
                {"timestamp": "2026-07-15T01:00:03Z", "type": "event_msg",
                 "payload": {"type": "task_complete", "turn_id": "turn-1"}},
            ]
            rollout.write_text("\n".join(json.dumps(item, ensure_ascii=False)
                                           for item in records) + "\n", encoding="utf-8")

            with mock.patch.dict(os.environ, {"CODEX_HOME": temp_dir}):
                detail = read_rollout_thread_detail(thread_id)

        assert detail is not None
        self.assertEqual(len(detail["messages"]), 1)
        self.assertEqual(detail["messages"][0]["text"], "生成的图片")
        self.assertTrue(detail["messages"][0]["images"][0].startswith(
            "data:image/jpeg;base64,"))
        self.assertIn("图片生成完成", [item["title"] for item in detail["activities"]])

    def test_rollout_exposes_view_image_tool_output_as_message(self) -> None:
        thread_id = "019f5e50-657d-7da2-8661-3700565b2d2e"
        with tempfile.TemporaryDirectory() as temp_dir:
            session_dir = Path(temp_dir) / "sessions" / "2026" / "07" / "15"
            session_dir.mkdir(parents=True)
            output = io.BytesIO()
            Image.new("RGB", (20, 20), "#CC8844").save(output, format="PNG")
            data_url = "data:image/png;base64," + base64.b64encode(
                output.getvalue()).decode("ascii")
            rollout = session_dir / f"rollout-test-{thread_id}.jsonl"
            records = [
                {"timestamp": "2026-07-15T01:00:00Z", "type": "session_meta",
                 "payload": {"session_id": thread_id, "cwd": r"C:\work\Starly"}},
                {"timestamp": "2026-07-15T01:00:01Z", "type": "event_msg",
                 "payload": {"type": "task_started", "turn_id": "turn-1"}},
                {"timestamp": "2026-07-15T01:00:02Z", "type": "response_item",
                 "payload": {"type": "function_call", "call_id": "call-image",
                             "name": "view_image", "arguments": "{}"}},
                {"timestamp": "2026-07-15T01:00:03Z", "type": "response_item",
                 "payload": {"type": "function_call_output", "call_id": "call-image",
                             "output": [{"type": "input_image", "image_url": data_url}],
                             "internal_chat_message_metadata_passthrough": {
                                 "turn_id": "turn-1"}}},
                {"timestamp": "2026-07-15T01:00:04Z", "type": "event_msg",
                 "payload": {"type": "task_complete", "turn_id": "turn-1"}},
            ]
            rollout.write_text("\n".join(json.dumps(item, ensure_ascii=False)
                                           for item in records) + "\n", encoding="utf-8")

            with mock.patch.dict(os.environ, {"CODEX_HOME": temp_dir}):
                detail = read_rollout_thread_detail(thread_id)

        assert detail is not None
        self.assertEqual(len(detail["messages"]), 1)
        self.assertEqual(detail["messages"][0]["text"], "查看的图片")
        self.assertTrue(detail["messages"][0]["images"][0].startswith(
            "data:image/jpeg;base64,"))
        self.assertIn("查看图片", [item["title"] for item in detail["activities"]])

    def test_rollout_exposes_public_activity_without_tool_io_or_encrypted_reasoning(self) -> None:
        thread_id = "019f5e50-657d-7da2-8661-3700565b2d2e"
        with tempfile.TemporaryDirectory() as temp_dir:
            session_dir = Path(temp_dir) / "sessions" / "2026" / "07" / "15"
            session_dir.mkdir(parents=True)
            rollout = session_dir / f"rollout-test-{thread_id}.jsonl"
            records = [
                {"timestamp": "2026-07-15T01:00:00Z", "type": "session_meta",
                 "payload": {"session_id": thread_id, "cwd": r"C:\work\Starly"}},
                {"timestamp": "2026-07-15T01:00:01Z", "type": "event_msg",
                 "payload": {"type": "task_started", "turn_id": "turn-1"}},
                {"timestamp": "2026-07-15T01:00:02Z", "type": "event_msg",
                 "payload": {"type": "agent_reasoning", "text": "正在检查消息同步逻辑"}},
                {"timestamp": "2026-07-15T01:00:03Z", "type": "response_item",
                 "payload": {"type": "reasoning", "summary": ["公开摘要"],
                             "encrypted_content": "hidden-chain"}},
                {"timestamp": "2026-07-15T01:00:04Z", "type": "response_item",
                 "payload": {"type": "custom_tool_call", "call_id": "call-1",
                             "name": "exec", "input": "token=super-secret"}},
                {"timestamp": "2026-07-15T01:00:05Z", "type": "response_item",
                 "payload": {"type": "custom_tool_call_output", "call_id": "call-1",
                             "output": "password=also-secret"}},
                {"timestamp": "2026-07-15T01:00:06Z", "type": "event_msg",
                 "payload": {"type": "task_complete", "turn_id": "turn-1"}},
            ]
            rollout.write_text("\n".join(json.dumps(item, ensure_ascii=False)
                                           for item in records) + "\n", encoding="utf-8")
            with mock.patch.dict(os.environ, {"CODEX_HOME": temp_dir}):
                detail = read_rollout_thread_detail(thread_id)

        self.assertIsNotNone(detail)
        activities = detail["activities"]
        self.assertEqual([item["title"] for item in activities],
                         ["思考摘要", "执行本地操作"])
        encoded = json.dumps(activities, ensure_ascii=False)
        self.assertIn("正在检查消息同步逻辑", encoded)
        self.assertNotIn("hidden-chain", encoded)
        self.assertNotIn("super-secret", encoded)
        self.assertNotIn("also-secret", encoded)

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

    def test_thread_detail_uses_latest_desktop_model_effort_and_permissions(self) -> None:
        thread_id = "019f5e50-657d-7da2-8661-3700565b2d2e"
        with tempfile.TemporaryDirectory() as temp_dir:
            session_dir = Path(temp_dir) / "sessions" / "2026" / "07" / "15"
            session_dir.mkdir(parents=True)
            rollout = session_dir / f"rollout-test-{thread_id}.jsonl"
            records = [
                {"timestamp": "2026-07-15T01:00:00Z", "type": "session_meta",
                 "payload": {"session_id": thread_id, "cwd": r"C:\work\Starly"}},
                {"timestamp": "2026-07-15T01:00:01Z", "type": "turn_context",
                 "payload": {
                     "model": "gpt-5.5", "effort": "low",
                     "approval_policy": "on-request",
                     "sandbox_policy": {"type": "workspace-write"},
                 }},
                {"timestamp": "2026-07-15T01:00:02Z", "type": "turn_context",
                 "payload": {
                     "model": "gpt-5.6-sol", "effort": "medium",
                     "approval_policy": "never",
                     "sandbox_policy": {"type": "danger-full-access"},
                 }},
                {"timestamp": "2026-07-15T01:00:03Z", "type": "event_msg",
                 "payload": {"type": "task_complete", "turn_id": "turn-2"}},
            ]
            rollout.write_text("\n".join(json.dumps(item, ensure_ascii=False)
                                            for item in records) + "\n", encoding="utf-8")

            with mock.patch.dict(os.environ, {"CODEX_HOME": temp_dir}):
                detail = read_rollout_thread_detail(thread_id)

        assert detail is not None
        self.assertEqual(detail["model"], "gpt-5.6-sol")
        self.assertEqual(detail["effort"], "medium")
        self.assertEqual(detail["permissionMode"], "fullAccess")

    def test_codex_history_pages_backward_in_stable_groups_of_fifteen(self) -> None:
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
            ]
            for index in range(35):
                records.append({
                    "timestamp": f"2026-07-15T01:{index + 1:02d}:02Z",
                    "type": "event_msg",
                    "payload": {"type": "agent_message", "message": f"消息-{index}",
                                "turn_id": "turn-1"},
                })
            records.append({
                "timestamp": "2026-07-15T02:00:00Z", "type": "event_msg",
                "payload": {"type": "task_complete", "turn_id": "turn-1"},
            })
            rollout.write_text("\n".join(json.dumps(item, ensure_ascii=False)
                                            for item in records) + "\n", encoding="utf-8")

            with mock.patch.dict(os.environ, {"CODEX_HOME": temp_dir}):
                latest = read_rollout_thread_detail(thread_id)
                assert latest is not None
                older = read_rollout_thread_detail(
                    thread_id, before_message_id=latest["messages"][0]["id"])
                assert older is not None
                oldest = read_rollout_thread_detail(
                    thread_id, before_message_id=older["messages"][0]["id"])

        assert oldest is not None
        self.assertEqual([item["text"] for item in latest["messages"]],
                         [f"消息-{index}" for index in range(20, 35)])
        self.assertEqual([item["text"] for item in older["messages"]],
                         [f"消息-{index}" for index in range(5, 20)])
        self.assertEqual([item["text"] for item in oldest["messages"]],
                         [f"消息-{index}" for index in range(5)])
        self.assertTrue(latest["hasMoreBefore"])
        self.assertTrue(older["hasMoreBefore"])
        self.assertFalse(oldest["hasMoreBefore"])

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

    def test_snapshot_reconciles_stale_active_cache_from_rollout(self) -> None:
        thread_id = "019f5e50-657d-7da2-8661-3700565b2d2e"
        with tempfile.TemporaryDirectory() as temp_dir:
            session_dir = Path(temp_dir) / "sessions" / "2026" / "07" / "15"
            session_dir.mkdir(parents=True)
            rollout = session_dir / f"rollout-test-{thread_id}.jsonl"
            records = [
                {"timestamp": "2026-07-15T01:00:00Z", "type": "session_meta",
                 "payload": {"session_id": thread_id, "cwd": r"C:\work\Starly"}},
                {"timestamp": "2026-07-15T01:00:01Z", "type": "event_msg",
                 "payload": {"type": "task_started", "turn_id": "turn-1"}},
                {"timestamp": "2026-07-15T01:00:02Z", "type": "event_msg",
                 "payload": {"type": "task_complete", "turn_id": "turn-1"}},
            ]
            rollout.write_text("\n".join(json.dumps(item, ensure_ascii=False)
                                           for item in records) + "\n", encoding="utf-8")
            client = CodexAppServerClient()
            client.thread_status[thread_id] = "active"
            # The app-server list can itself remain active after a task owned by
            # Codex Desktop has completed, so active list entries must also be
            # reconciled against the append-only rollout.
            thread = {"id": thread_id, "status": "active", "updatedAt": 0}
            client.thread_metadata[thread_id] = dict(thread)

            with mock.patch.dict(os.environ, {"CODEX_HOME": temp_dir}):
                asyncio.run(client._reconcile_snapshot_thread_statuses([thread]))

        self.assertEqual(client.thread_status[thread_id], "idle")

    def test_snapshot_resolves_not_loaded_after_bridge_restart(self) -> None:
        thread_id = "019f5e50-657d-7da2-8661-3700565b2d2e"
        with tempfile.TemporaryDirectory() as temp_dir:
            session_dir = Path(temp_dir) / "sessions" / "2026" / "07" / "15"
            session_dir.mkdir(parents=True)
            rollout = session_dir / f"rollout-test-{thread_id}.jsonl"
            records = [
                {"timestamp": "2026-07-15T01:00:00Z", "type": "session_meta",
                 "payload": {"session_id": thread_id, "cwd": r"C:\work\Starly"}},
                {"timestamp": "2026-07-15T01:00:01Z", "type": "event_msg",
                 "payload": {"type": "task_started", "turn_id": "turn-1"}},
                {"timestamp": "2026-07-15T01:00:02Z", "type": "event_msg",
                 "payload": {"type": "task_complete", "turn_id": "turn-1"}},
            ]
            rollout.write_text("\n".join(json.dumps(item, ensure_ascii=False)
                                           for item in records) + "\n", encoding="utf-8")
            client = CodexAppServerClient()
            thread = {
                "id": thread_id,
                "status": "notLoaded",
                "updatedAt": int(rollout.stat().st_mtime),
            }
            client.thread_metadata[thread_id] = dict(thread)

            with mock.patch.dict(os.environ, {"CODEX_HOME": temp_dir}):
                asyncio.run(client._reconcile_snapshot_thread_statuses([thread]))

        self.assertEqual(client.thread_status[thread_id], "idle")

    def test_snapshot_does_not_apply_older_completed_rollout_to_new_turn(self) -> None:
        thread_id = "019f5e50-657d-7da2-8661-3700565b2d2e"
        with tempfile.TemporaryDirectory() as temp_dir:
            session_dir = Path(temp_dir) / "sessions" / "2026" / "07" / "15"
            session_dir.mkdir(parents=True)
            rollout = session_dir / f"rollout-test-{thread_id}.jsonl"
            records = [
                {"timestamp": "2026-07-15T01:00:00Z", "type": "session_meta",
                 "payload": {"session_id": thread_id, "cwd": r"C:\work\Starly"}},
                {"timestamp": "2026-07-15T01:00:01Z", "type": "event_msg",
                 "payload": {"type": "task_complete", "turn_id": "turn-1"}},
            ]
            rollout.write_text("\n".join(json.dumps(item, ensure_ascii=False)
                                           for item in records) + "\n", encoding="utf-8")
            client = CodexAppServerClient()
            client.thread_status[thread_id] = "active"
            thread = {
                "id": thread_id,
                "status": "notLoaded",
                "updatedAt": int(rollout.stat().st_mtime) + 10,
            }
            client.thread_metadata[thread_id] = dict(thread)

            with mock.patch.dict(os.environ, {"CODEX_HOME": temp_dir}):
                asyncio.run(client._reconcile_snapshot_thread_statuses([thread]))

        self.assertEqual(client.thread_status[thread_id], "active")

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

    def test_rollout_change_pushes_incremental_start_and_completion(self) -> None:
        thread_id = "019f5e50-657d-7da2-8661-3700565b2d2e"
        with tempfile.TemporaryDirectory() as temp_dir:
            session_dir = Path(temp_dir) / "sessions" / "2026" / "08" / "07"
            session_dir.mkdir(parents=True)
            rollout = session_dir / f"rollout-test-{thread_id}.jsonl"
            records = [
                {"timestamp": "2026-08-07T01:00:00Z", "type": "session_meta",
                 "payload": {"session_id": thread_id, "cwd": r"C:\work\Starly"}},
                {"timestamp": "2026-08-07T01:00:01Z", "type": "event_msg",
                 "payload": {"type": "task_started", "turn_id": "turn-1"}},
                {"timestamp": "2026-08-07T01:00:02Z", "type": "response_item",
                 "payload": {"type": "message", "role": "user",
                             "content": [{"type": "input_text", "text": "run now"}]}},
            ]
            rollout.write_text("\n".join(json.dumps(item) for item in records) + "\n",
                               encoding="utf-8")

            server = BridgeServer.__new__(BridgeServer)
            broadcasts: list[dict[str, object]] = []

            class FakeCodex:
                def __init__(self) -> None:
                    self.thread_metadata: dict[str, dict[str, object]] = {}
                    self.thread_status: dict[str, str] = {}

            async def fake_broadcast(message: dict[str, object]) -> None:
                broadcasts.append(message)

            async def fake_refresh() -> None:
                return None

            server.codex = FakeCodex()
            server.rollout_states = {}
            server.rollout_debounce = {}
            server.pending_desktop_open = set()
            server._broadcast = fake_broadcast
            server._schedule_codex_refresh = fake_refresh

            with mock.patch.dict(os.environ, {"CODEX_HOME": temp_dir}):
                asyncio.run(server._publish_rollout_change(thread_id))
                records.extend([
                    {"timestamp": "2026-08-07T01:00:03Z", "type": "event_msg",
                     "payload": {"type": "agent_message", "message": "finished",
                                 "turn_id": "turn-1"}},
                    {"timestamp": "2026-08-07T01:00:04Z", "type": "event_msg",
                     "payload": {"type": "task_complete", "turn_id": "turn-1"}},
                ])
                rollout.write_text("\n".join(json.dumps(item) for item in records) + "\n",
                                   encoding="utf-8")
                asyncio.run(server._publish_rollout_change(thread_id))

        deltas = [message["thread"] for message in broadcasts
                  if message.get("type") == "codex_thread"]
        events = [message["event"] for message in broadcasts
                  if message.get("type") == "codex_event"]
        self.assertEqual(len(deltas), 2)
        self.assertEqual(deltas[0]["updateMode"], "delta")
        self.assertEqual(deltas[0]["status"], "active")
        self.assertEqual([item["text"] for item in deltas[1]["messages"]], ["finished"])
        self.assertEqual(deltas[1]["status"], "idle")
        self.assertEqual(events, ["turn/started", "turn/completed"])

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
        baseline = {
            "id": thread_id, "status": "idle", "activeTurnId": "",
            "messages": old_messages,
        }

        async def exercise() -> None:
            server.codex_poll_tasks[thread_id] = asyncio.current_task()
            await server._poll_desktop_codex_thread(thread_id, baseline)

        with mock.patch("pc.starly_bridge.asyncio.sleep", new=fake_sleep):
            asyncio.run(exercise())

        deltas = [item["thread"] for item in broadcasts
                  if item.get("type") == "codex_thread"]
        self.assertTrue(deltas)
        self.assertTrue(all(item.get("updateMode") == "delta" for item in deltas))
        self.assertTrue(all(len(item["messages"]) == 1 for item in deltas))
        self.assertTrue(any(item.get("event") == "turn/completed" for item in broadcasts))
        self.assertNotIn(thread_id, server.codex_poll_tasks)

    def test_poll_terminal_event_preserves_failures_and_unknown_states(self) -> None:
        self.assertEqual(BridgeServer._terminal_poll_event("idle", True), "turn/completed")
        self.assertEqual(BridgeServer._terminal_poll_event("systemError", True), "turn/failed")
        self.assertEqual(BridgeServer._terminal_poll_event("idle", False), "")
        self.assertEqual(BridgeServer._terminal_poll_event("notLoaded", True), "")
        self.assertEqual(BridgeServer._terminal_poll_event("queued", True), "")

    def test_poll_recovers_after_transient_detail_read_failure(self) -> None:
        server = BridgeServer.__new__(BridgeServer)
        thread_id = "thread-transient-read"

        class FakeCodex:
            def __init__(self) -> None:
                self.calls = 0

            async def thread_detail(self, requested_id: str) -> dict[str, object]:
                self_test.assertEqual(requested_id, thread_id)
                self.calls += 1
                if self.calls == 1:
                    raise OSError("rollout temporarily locked")
                if self.calls == 2:
                    return {
                        "id": thread_id, "status": "active", "activeTurnId": "turn-1",
                        "messages": [], "activities": [],
                    }
                return {
                    "id": thread_id, "status": "idle", "activeTurnId": "",
                    "messages": [{"id": "reply", "role": "assistant", "text": "done"}],
                    "activities": [],
                }

        self_test = self
        broadcasts: list[dict[str, object]] = []
        refreshes: list[bool] = []

        async def fake_broadcast(message: dict[str, object]) -> None:
            broadcasts.append(message)

        async def fake_refresh() -> None:
            refreshes.append(True)

        async def fake_sleep(_seconds: float) -> None:
            return None

        server.codex = FakeCodex()
        server.codex_poll_tasks = {}
        server._broadcast = fake_broadcast
        server._schedule_codex_refresh = fake_refresh
        baseline = {
            "id": thread_id, "status": "idle", "activeTurnId": "",
            "messages": [], "activities": [],
        }

        async def exercise() -> None:
            server.codex_poll_tasks[thread_id] = asyncio.current_task()
            await server._poll_desktop_codex_thread(thread_id, baseline)

        with mock.patch("pc.starly_bridge.asyncio.sleep", new=fake_sleep):
            asyncio.run(exercise())

        self.assertEqual(server.codex.calls, 3)
        self.assertTrue(refreshes)
        self.assertTrue(any(item.get("event") == "turn/completed" for item in broadcasts))
        self.assertFalse(any(item.get("type") == "error" for item in broadcasts))
        self.assertNotIn(thread_id, server.codex_poll_tasks)

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

    def test_duplicate_snapshot_requests_share_recent_bridge_result(self) -> None:
        server = BridgeServer.__new__(BridgeServer)
        snapshots: list[dict[str, object]] = []

        class FakeCodex:
            def __init__(self) -> None:
                self.calls = 0

            async def snapshot(self, include_archived: bool = False) -> dict[str, object]:
                self.calls += 1
                await asyncio.sleep(0.01)
                return {"available": True, "threads": [], "models": [],
                        "includeArchived": include_archived}

        async def fake_send_json(_connection: object,
                                 message: dict[str, object]) -> None:
            snapshots.append(message)

        server.codex = FakeCodex()
        server.codex_snapshot_lock = None
        server.codex_snapshot_cache = {}
        server._send_json = fake_send_json

        async def exercise() -> None:
            await asyncio.gather(
                server._send_codex_snapshot(object(), False),
                server._send_codex_snapshot(object(), False),
            )

        asyncio.run(exercise())

        self.assertEqual(server.codex.calls, 1)
        self.assertEqual(len(snapshots), 2)

    def test_failed_turn_is_announced_as_failed_phone_event(self) -> None:
        server = BridgeServer.__new__(BridgeServer)
        server.connections = {object()}
        broadcasts: list[dict[str, object]] = []

        async def fake_broadcast(message: dict[str, object]) -> None:
            broadcasts.append(message)

        async def fake_refresh() -> None:
            return None

        server._broadcast = fake_broadcast
        server._schedule_codex_refresh = fake_refresh
        server.pending_desktop_open = set()

        asyncio.run(server._handle_codex_event("turn/completed", {
            "threadId": "thread-failed",
            "turn": {"id": "turn-1", "status": "failed"},
        }))

        self.assertEqual(broadcasts[0]["event"], "turn/failed")

    def test_new_codex_task_uses_workspace_sandbox_and_remote_approvals(self) -> None:
        client = CodexAppServerClient()
        calls: list[tuple[str, dict[str, object]]] = []

        async def fake_request(method: str, params: dict[str, object] | None = None,
                               timeout: float = 15) -> dict[str, object]:
            calls.append((method, params or {}))
            if method == "thread/start":
                return {"thread": {"id": "thread-new", "cwd": r"C:\work\Starly"}}
            return {"turn": {"id": "turn-new"}}

        client.request = fake_request
        result = asyncio.run(client.create_thread(r"C:\work\Starly", "run tests"))

        self.assertEqual(result["threadId"], "thread-new")
        self.assertEqual(calls[0], ("thread/start", {
            "cwd": r"C:\work\Starly",
            "approvalPolicy": "on-request",
            "sandbox": "workspace-write",
        }))
        self.assertEqual(calls[1][0], "turn/start")

    def test_remote_approval_is_answered_once(self) -> None:
        client = CodexAppServerClient()
        writes: list[dict[str, object]] = []
        client.approval_requests["approval-7"] = (7, "item/commandExecution/requestApproval", {})

        async def fake_write(value: dict[str, object]) -> None:
            writes.append(value)

        client._write = fake_write
        asyncio.run(client.resolve_approval("approval-7", "accept"))

        self.assertEqual(writes, [{"id": 7, "result": {"decision": "accept"}}])
        with self.assertRaisesRegex(RuntimeError, "已失效"):
            asyncio.run(client.resolve_approval("approval-7", "accept"))

    def test_background_send_falls_back_when_desktop_owns_thread_writer(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            server = BridgeServer.__new__(BridgeServer)
            server.codex_queue = CodexQueueStore(
                Path(directory) / "queue.json", lambda value: value, lambda value: value)
            server.connections = set()
            sent: list[dict[str, object]] = []
            server._send_json = lambda _connection, message: self._append_async(sent, message)

            async def scenario() -> None:
                await server._codex_send(
                    object(), "thread-1", "你好", "enter", "message-1")
                await server._codex_send(
                    object(), "thread-1", "你好", "enter", "message-1")

            asyncio.run(scenario())

            self.assertEqual(len(server.codex_queue.items), 1)
            self.assertFalse(bool(sent[0]["duplicate"]))
            self.assertTrue(bool(sent[1]["duplicate"]))

    def test_background_image_send_falls_back_on_active_writer(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            protect = lambda value: base64.b64encode(value.encode("utf-8")).decode("ascii")
            unprotect = lambda value: base64.b64decode(value).decode("utf-8")
            store = CodexQueueStore(
                Path(directory) / "queue.json", protect, unprotect)
            image = "data:image/png;base64," + base64.b64encode(b"image").decode("ascii")
            store.enqueue(CodexQueueItem(
                queue_id="message-2", thread_id="thread-2", text="秘密图片任务",
                image_data=image))
            raw = store.path.read_text(encoding="utf-8")
            loaded = CodexQueueStore(
                store.path, protect, unprotect)

            self.assertNotIn("秘密图片任务", raw)
            self.assertNotIn(image, raw)
            self.assertEqual(loaded.get("message-2").text, "秘密图片任务")
            self.assertTrue(loaded.get("message-2").has_image)

    def test_queue_runs_same_thread_fifo(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            server = BridgeServer.__new__(BridgeServer)
            server.codex_queue = CodexQueueStore(
                Path(directory) / "queue.json", lambda value: value, lambda value: value)
            server.connections = set()
            sent: list[str] = []

            class FakeCodex:
                async def thread_detail(self, _thread_id: str) -> dict[str, object]:
                    return {"status": "idle", "messages": []}

                async def send_message(self, thread_id: str, text: str, *_args: object,
                                       allow_steer: bool = True) -> dict[str, object]:
                    self_outer.assertFalse(allow_steer)
                    sent.append(text)
                    asyncio.get_running_loop().call_soon(
                        server._signal_codex_queue_terminal, thread_id, "completed")
                    return {}

            self_outer = self

            async def scenario() -> None:
                server.codex = FakeCodex()
                server._send_json = lambda _connection, _message: self._noop_async()
                server._schedule_codex_refresh = self._noop_async
                await server._codex_send(
                    object(), "thread-1", "第一条", "enter", "queue-1")
                await server._codex_send(
                    object(), "thread-1", "第二条", "enter", "queue-2")
                await asyncio.gather(*list(server.codex_queue_tasks.values()))

            asyncio.run(scenario())

            self.assertEqual(sent, ["第一条", "第二条"])
            self.assertEqual([item.state for item in server.codex_queue.items],
                             ["completed", "completed"])

    def test_queue_runs_different_threads_concurrently(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            server = BridgeServer.__new__(BridgeServer)
            server.codex_queue = CodexQueueStore(
                Path(directory) / "queue.json", lambda value: value, lambda value: value)
            server.connections = set()
            started: list[str] = []
            both_started = asyncio.Event()

            class FakeCodex:
                async def thread_detail(self, _thread_id: str) -> dict[str, object]:
                    return {"status": "idle", "messages": []}

                async def send_message(self, thread_id: str, _text: str, *_args: object,
                                       **_kwargs: object) -> dict[str, object]:
                    started.append(thread_id)
                    if len(started) == 2:
                        both_started.set()
                    await asyncio.wait_for(both_started.wait(), timeout=1)
                    asyncio.get_running_loop().call_soon(
                        server._signal_codex_queue_terminal, thread_id, "completed")
                    return {}

            async def scenario() -> None:
                server.codex = FakeCodex()
                server._send_json = lambda _connection, _message: self._noop_async()
                server._schedule_codex_refresh = self._noop_async
                await server._codex_send(object(), "thread-a", "A", "enter", "queue-a")
                await server._codex_send(object(), "thread-b", "B", "enter", "queue-b")
                await asyncio.gather(*list(server.codex_queue_tasks.values()))

            asyncio.run(scenario())

            self.assertCountEqual(started, ["thread-a", "thread-b"])

    def test_active_thread_stays_queued_and_never_calls_steer(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            server = BridgeServer.__new__(BridgeServer)
            server.codex_queue = CodexQueueStore(
                Path(directory) / "queue.json", lambda value: value, lambda value: value)
            server.connections = set()
            sends = 0

            class FakeCodex:
                async def thread_detail(self, _thread_id: str) -> dict[str, object]:
                    return {"status": "active", "activeTurnId": "turn-1", "messages": []}

                async def send_message(self, *_args: object, **_kwargs: object) -> dict[str, object]:
                    nonlocal sends
                    sends += 1
                    return {}

            async def scenario() -> None:
                server.codex = FakeCodex()
                server._send_json = lambda _connection, _message: self._noop_async()
                await server._codex_send(
                    object(), "thread-1", "排队内容", "enter", "queue-active")
                await asyncio.sleep(0.05)
                for task in server.codex_queue_tasks.values():
                    task.cancel()
                await asyncio.gather(*server.codex_queue_tasks.values(), return_exceptions=True)

            asyncio.run(scenario())

            self.assertEqual(sends, 0)
            self.assertEqual(server.codex_queue.get("queue-active").state, "queued")

    def test_restart_preserves_running_item_without_resending(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "queue.json"
            store = CodexQueueStore(path, lambda value: value, lambda value: value)
            store.enqueue(CodexQueueItem(
                queue_id="queue-running", thread_id="thread-1", text="只执行一次"))
            store.transition("queue-running", "running")
            server = BridgeServer.__new__(BridgeServer)
            server.codex_queue = CodexQueueStore(path, lambda value: value, lambda value: value)
            server.connections = set()
            sends = 0

            class FakeCodex:
                async def thread_detail(self, _thread_id: str) -> dict[str, object]:
                    return {"status": "active", "activeTurnId": "turn-1", "messages": []}

                async def send_message(self, *_args: object, **_kwargs: object) -> dict[str, object]:
                    nonlocal sends
                    sends += 1
                    return {}

            async def scenario() -> None:
                server.codex = FakeCodex()
                server._start_codex_queue_workers()
                await asyncio.sleep(0)
                server._signal_codex_queue_terminal("thread-1", "completed")
                await asyncio.gather(*list(server.codex_queue_tasks.values()))

            asyncio.run(scenario())

            self.assertEqual(sends, 0)
            self.assertEqual(server.codex_queue.get("queue-running").state, "completed")

    def test_queued_item_ignores_stale_idle_terminal_event(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            server = BridgeServer.__new__(BridgeServer)
            server.codex_queue = CodexQueueStore(
                Path(directory) / "queue.json", lambda value: value, lambda value: value)
            item, _created = server.codex_queue.enqueue(CodexQueueItem(
                queue_id="queue-stale", thread_id="thread-1", text="第二条"))

            server._signal_codex_queue_terminal("thread-1", "completed")

            self.assertNotIn("thread-1", server.codex_queue_terminal_results)
            self.assertNotIn("thread-1", server.codex_queue_terminal_events)
            server.codex_queue.transition(item.queue_id, "running")
            server._signal_codex_queue_terminal("thread-1", "completed")
            self.assertEqual(server.codex_queue_terminal_results["thread-1"], "completed")
            self.assertTrue(server.codex_queue_terminal_events["thread-1"].is_set())

    def test_queue_snapshot_and_cancel_protocol(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            server = BridgeServer.__new__(BridgeServer)
            server.codex_queue = CodexQueueStore(
                Path(directory) / "queue.json", lambda value: value, lambda value: value)
            server.codex_queue.enqueue(CodexQueueItem(
                queue_id="queue-1", thread_id="thread-1", text="稍后执行"))
            server.connections = set()
            server.event_queue = queue.Queue()
            connection = FakeConnection()

            async def scenario() -> None:
                await server._handle_message(connection, json.dumps({
                    "type": "codex_queue_cancel", "id": "cancel-1", "queueId": "queue-1",
                }))
                await server._handle_message(connection, json.dumps({
                    "type": "codex_queue_snapshot_request", "id": "snapshot-1",
                }))

            asyncio.run(scenario())
            messages = [json.loads(value) for value in connection.messages]

            self.assertEqual(messages[0]["operation"], "codex_queue_cancel")
            self.assertEqual(messages[1]["type"], "codex_queue_snapshot")
            self.assertEqual(messages[1]["items"][0]["state"], "canceled")


if __name__ == "__main__":
    unittest.main()
