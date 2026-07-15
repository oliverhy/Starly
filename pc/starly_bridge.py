from __future__ import annotations

import asyncio
import ctypes
import hmac
import ipaddress
import json
import os
import queue
import secrets
import socket
import subprocess
import sys
import threading
import time
import tkinter as tk
import urllib.parse
import winreg
from ctypes import wintypes
from pathlib import Path
from tkinter import messagebox, ttk

import pystray
import qrcode
import websockets
from PIL import Image, ImageDraw, ImageTk

try:
    from pc.codex_client import CodexAppServerClient
except ImportError:
    from codex_client import CodexAppServerClient


APP_NAME = "StarlyBridge"
APP_TITLE = "Starly 电脑端"
DEFAULT_PORT = 8765
MAX_TEXT_LENGTH = 8000
MAX_PHONE_DETAIL_MESSAGES = 15
MAX_WIRE_MESSAGE_SIZE = 16 * 1024 * 1024
CONFIG_DIR = Path(os.environ.get("APPDATA", Path.home())) / APP_NAME
CONFIG_PATH = CONFIG_DIR / "config.json"
LOG_PATH = CONFIG_DIR / "bridge.log"
SINGLE_INSTANCE_MUTEX = "Local\\StarlyBridge.SingleInstance"
_single_instance_handle: int | None = None


def open_codex_thread(thread_id: str) -> bool:
    if os.name != "nt" or not thread_id:
        return False
    try:
        os.startfile(f"codex://threads/{urllib.parse.quote(thread_id, safe='')}")
        return True
    except OSError:
        return False


CODEX_COMPOSER_FOCUS_SCRIPT = r"""
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$OutputEncoding = [Console]::OutputEncoding
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class StarlyCodexUi {
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int command);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(
    uint flags, uint dx, uint dy, uint data, UIntPtr extra);
}
'@
$root = [System.Windows.Automation.AutomationElement]::RootElement
$expectedTitle = $env:STARLY_CODEX_THREAD_TITLE
$deadline = [DateTime]::UtcNow.AddSeconds(27)
$mainWindow = $null
while ($null -eq $mainWindow -and [DateTime]::UtcNow -lt $deadline) {
  $mainArea = 0.0
  $processes = @(Get-Process ChatGPT -ErrorAction SilentlyContinue | Where-Object {
    try { $_.Path -like '*OpenAI.Codex_*' } catch { $false }
  })
  foreach ($process in $processes) {
    $condition = New-Object System.Windows.Automation.PropertyCondition(
      [System.Windows.Automation.AutomationElement]::ProcessIdProperty, $process.Id)
    $windows = $root.FindAll([System.Windows.Automation.TreeScope]::Children, $condition)
    foreach ($window in $windows) {
      $rect = $window.Current.BoundingRectangle
      $area = $rect.Width * $rect.Height
      if ($window.Current.ClassName -eq 'Chrome_WidgetWin_1' -and $area -gt $mainArea) {
        $mainWindow = $window
        $mainArea = $area
      }
    }
  }
  if ($null -eq $mainWindow) { Start-Sleep -Milliseconds 400 }
}
if ($null -eq $mainWindow -or $mainArea -lt 300000) {
  Write-Output 'WINDOW_NOT_FOUND'
  exit 2
}
$windowRect = $mainWindow.Current.BoundingRectangle
$handle = [IntPtr]$mainWindow.Current.NativeWindowHandle
[StarlyCodexUi]::ShowWindow($handle, 9) | Out-Null
[StarlyCodexUi]::SetForegroundWindow($handle) | Out-Null
Start-Sleep -Milliseconds 250
$windowRect = $mainWindow.Current.BoundingRectangle

# Clicking the composer once enables Chromium's full accessibility tree.
$clickX = [int]($windowRect.X + $windowRect.Width * 0.57)
$clickY = [int]($windowRect.Bottom - 72)
[StarlyCodexUi]::SetCursorPos($clickX, $clickY) | Out-Null
[StarlyCodexUi]::mouse_event(2, 0, 0, 0, [UIntPtr]::Zero)
[StarlyCodexUi]::mouse_event(4, 0, 0, 0, [UIntPtr]::Zero)

while ([DateTime]::UtcNow -lt $deadline) {
  $controls = $mainWindow.FindAll(
    [System.Windows.Automation.TreeScope]::Descendants,
    [System.Windows.Automation.Condition]::TrueCondition)
  $titleLoaded = $false
  $composer = $null
  foreach ($control in $controls) {
    $current = $control.Current
    $rect = $current.BoundingRectangle
    if ($current.ControlType -eq [System.Windows.Automation.ControlType]::Text -and
        $current.Name -eq $expectedTitle -and
        $rect.Top -ge $windowRect.Top -and
        $rect.Top -lt ($windowRect.Top + 105) -and
        $rect.Left -gt ($windowRect.Left + 150)) {
      $titleLoaded = $true
    }
    if ($current.IsEnabled -and $current.ClassName -match '(^| )ProseMirror( |$)') {
      $composer = $control
    }
  }
  if ($titleLoaded -and $null -ne $composer) {
    $composer.SetFocus()
    Start-Sleep -Milliseconds 180
    $focused = [System.Windows.Automation.AutomationElement]::FocusedElement.Current
    if ($focused.ProcessId -eq $mainWindow.Current.ProcessId -and
        $focused.ClassName -match '(^| )ProseMirror( |$)') {
      Write-Output ('FOCUSED|' + $expectedTitle + '|' + $focused.ClassName)
      exit 0
    }
  }
  Start-Sleep -Milliseconds 400
}
Write-Output ('TASK_NOT_READY|' + $expectedTitle)
exit 3
"""


def focus_codex_composer(thread_title: str) -> tuple[bool, str]:
    flags = 0x08000000 if os.name == "nt" else 0
    environment = os.environ.copy()
    environment["STARLY_CODEX_THREAD_TITLE"] = thread_title
    try:
        result = subprocess.run(
            ["powershell.exe", "-NoProfile", "-NonInteractive", "-Command", CODEX_COMPOSER_FOCUS_SCRIPT],
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=32,
            creationflags=flags,
            env=environment,
            check=False,
        )
    except (OSError, subprocess.SubprocessError) as error:
        return False, f"无法调用 Windows UI Automation：{error}"
    output = result.stdout.strip()
    if result.returncode == 0 and output.startswith("FOCUSED|"):
        return True, output
    detail = output or result.stderr.strip() or f"退出码 {result.returncode}"
    return False, f"未找到 Codex 桌面端输入框（{detail}）"


def acquire_single_instance() -> bool:
    global _single_instance_handle
    kernel32 = ctypes.windll.kernel32
    kernel32.CreateMutexW.restype = wintypes.HANDLE
    handle = kernel32.CreateMutexW(None, False, SINGLE_INSTANCE_MUTEX)
    if not handle:
        return False
    if kernel32.GetLastError() == 183:  # ERROR_ALREADY_EXISTS
        kernel32.CloseHandle(handle)
        return False
    _single_instance_handle = int(handle)
    return True


def is_port_available(port: int) -> bool:
    probe = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        if hasattr(socket, "SO_EXCLUSIVEADDRUSE"):
            probe.setsockopt(socket.SOL_SOCKET, socket.SO_EXCLUSIVEADDRUSE, 1)
        probe.bind(("0.0.0.0", port))
        return True
    except OSError:
        return False
    finally:
        probe.close()


def find_available_port(preferred: int = DEFAULT_PORT) -> int:
    candidates = ([preferred] if 1 <= preferred <= 65535 else []) + [
        port for port in range(DEFAULT_PORT, DEFAULT_PORT + 100) if port != preferred
    ]
    for port in candidates:
        if is_port_available(port):
            return port
    raise RuntimeError("未找到可用的局域网监听端口")


class BridgeConfig:
    def __init__(self, port: int = DEFAULT_PORT, token: str = "") -> None:
        self.port = port
        self.token = token or secrets.token_urlsafe(32)

    @classmethod
    def load(cls) -> "BridgeConfig":
        try:
            data = json.loads(CONFIG_PATH.read_text(encoding="utf-8"))
            port = int(data.get("port", DEFAULT_PORT))
            token = str(data.get("token", ""))
            if not 1 <= port <= 65535 or len(token) < 32:
                raise ValueError("invalid config")
            return cls(port, token)
        except (OSError, ValueError, TypeError, json.JSONDecodeError):
            config = cls()
            config.save()
            return config

    def save(self) -> None:
        CONFIG_DIR.mkdir(parents=True, exist_ok=True)
        CONFIG_PATH.write_text(
            json.dumps({"port": self.port, "token": self.token}, ensure_ascii=False, indent=2),
            encoding="utf-8",
        )


ULONG_PTR = wintypes.WPARAM


class MOUSEINPUT(ctypes.Structure):
    _fields_ = [
        ("dx", wintypes.LONG),
        ("dy", wintypes.LONG),
        ("mouseData", wintypes.DWORD),
        ("dwFlags", wintypes.DWORD),
        ("time", wintypes.DWORD),
        ("dwExtraInfo", ULONG_PTR),
    ]


class KEYBDINPUT(ctypes.Structure):
    _fields_ = [
        ("wVk", wintypes.WORD),
        ("wScan", wintypes.WORD),
        ("dwFlags", wintypes.DWORD),
        ("time", wintypes.DWORD),
        ("dwExtraInfo", ULONG_PTR),
    ]


class HARDWAREINPUT(ctypes.Structure):
    _fields_ = [
        ("uMsg", wintypes.DWORD),
        ("wParamL", wintypes.WORD),
        ("wParamH", wintypes.WORD),
    ]


class INPUT_UNION(ctypes.Union):
    _fields_ = [
        ("mi", MOUSEINPUT),
        ("ki", KEYBDINPUT),
        ("hi", HARDWAREINPUT),
    ]


class INPUT(ctypes.Structure):
    _anonymous_ = ("union",)
    _fields_ = [("type", wintypes.DWORD), ("union", INPUT_UNION)]


class WindowsInput:
    INPUT_KEYBOARD = 1
    KEYEVENTF_KEYUP = 0x0002
    KEYEVENTF_UNICODE = 0x0004
    VK_CONTROL = 0x11
    VK_RETURN = 0x0D
    SCAN_CONTROL = 0x1D
    SCAN_RETURN = 0x1C

    def __init__(self) -> None:
        self.user32 = ctypes.windll.user32

    def foreground_window(self) -> tuple[int, str, int]:
        hwnd = int(self.user32.GetForegroundWindow())
        title_length = int(self.user32.GetWindowTextLengthW(hwnd))
        title = ctypes.create_unicode_buffer(title_length + 1)
        self.user32.GetWindowTextW(hwnd, title, len(title))
        process_id = wintypes.DWORD()
        self.user32.GetWindowThreadProcessId(hwnd, ctypes.byref(process_id))
        return hwnd, title.value or "未命名窗口", int(process_id.value)

    def type_text(self, text: str, submit_mode: str) -> tuple[bool, str]:
        hwnd, title, process_id = self.foreground_window()
        if hwnd == 0:
            return False, "电脑上没有活动窗口"
        if process_id == os.getpid():
            return False, "请先最小化 Starly，并在电脑上点中目标输入框"
        encoded = text.encode("utf-16-le")
        units = [int.from_bytes(encoded[index:index + 2], "little") for index in range(0, len(encoded), 2)]
        inputs: list[INPUT] = []
        for unit in units:
            inputs.append(self._keyboard_input(0, unit, self.KEYEVENTF_UNICODE))
            inputs.append(self._keyboard_input(0, unit, self.KEYEVENTF_UNICODE | self.KEYEVENTF_KEYUP))
        if not self._send(inputs):
            return False, "Windows 拒绝了文字输入；目标窗口可能以管理员权限运行"
        if submit_mode in ("enter", "ctrl_enter"):
            # UI frameworks process injected Unicode asynchronously. Give the
            # target enough time to commit the text before the physical-style
            # Enter event arrives, especially for longer messages.
            time.sleep(min(1.2, 0.3 + len(units) * 0.006))
            if not self.press_submit(submit_mode)[0]:
                return False, "文字已输入，但 Windows 拒绝了发送快捷键"
        if submit_mode == "ctrl_enter":
            action = "输入并按 Ctrl+回车"
        elif submit_mode == "enter":
            action = "输入并按回车"
        else:
            action = "输入文字"
        return True, f"已向“{title}”{action}"

    def press_submit(self, submit_mode: str) -> tuple[bool, str]:
        if submit_mode == "ctrl_enter":
            _, title, process_id = self.foreground_window()
            if process_id == os.getpid():
                return False, "请先在电脑上点中目标输入框"
            inputs = [
                self._keyboard_input(self.VK_CONTROL, self.SCAN_CONTROL, 0),
                self._keyboard_input(self.VK_RETURN, self.SCAN_RETURN, 0),
                self._keyboard_input(self.VK_RETURN, self.SCAN_RETURN, self.KEYEVENTF_KEYUP),
                self._keyboard_input(self.VK_CONTROL, self.SCAN_CONTROL, self.KEYEVENTF_KEYUP),
            ]
            if not self._send(inputs):
                return False, "Windows 拒绝了 Ctrl+回车操作"
            return True, f"已向“{title}”按 Ctrl+回车"
        return self.press_enter()

    def press_enter(self) -> tuple[bool, str]:
        _, title, process_id = self.foreground_window()
        if process_id == os.getpid():
            return False, "请先在电脑上点中目标输入框"
        inputs = [
            self._keyboard_input(self.VK_RETURN, self.SCAN_RETURN, 0),
            self._keyboard_input(self.VK_RETURN, self.SCAN_RETURN, self.KEYEVENTF_KEYUP),
        ]
        if not self._send(inputs):
            return False, "Windows 拒绝了回车操作"
        return True, f"已向“{title}”按回车"

    def _keyboard_input(self, virtual_key: int, scan_code: int, flags: int) -> INPUT:
        return INPUT(
            type=self.INPUT_KEYBOARD,
            ki=KEYBDINPUT(virtual_key, scan_code, flags, 0, 0),
        )

    def _send(self, inputs: list[INPUT]) -> bool:
        if not inputs:
            return True
        array_type = INPUT * len(inputs)
        sent = int(self.user32.SendInput(len(inputs), array_type(*inputs), ctypes.sizeof(INPUT)))
        return sent == len(inputs)


class BridgeServer:
    def __init__(self, config: BridgeConfig, event_queue: queue.Queue[tuple[str, str]]) -> None:
        self.config = config
        self.event_queue = event_queue
        self.input = WindowsInput()
        self.thread: threading.Thread | None = None
        self.loop: asyncio.AbstractEventLoop | None = None
        self.stop_event: asyncio.Event | None = None
        self.connections: set[websockets.ServerConnection] = set()
        self.codex: CodexAppServerClient | None = None
        self.codex_refresh_task: asyncio.Task[None] | None = None
        self.pending_desktop_open: set[str] = set()
        self.codex_poll_tasks: dict[str, asyncio.Task[None]] = {}

    def start(self) -> None:
        if self.thread and self.thread.is_alive():
            return
        self.thread = threading.Thread(target=self._thread_main, name="StarlyWebSocket", daemon=True)
        self.thread.start()

    def stop(self) -> None:
        if self.loop and self.stop_event:
            self.loop.call_soon_threadsafe(self.stop_event.set)
        if self.thread and self.thread.is_alive():
            self.thread.join(timeout=3)

    def _thread_main(self) -> None:
        try:
            asyncio.run(self._run())
        except Exception as error:
            self.event_queue.put(("error", f"服务启动失败：{error}"))

    async def _run(self) -> None:
        self.loop = asyncio.get_running_loop()
        self.stop_event = asyncio.Event()
        self.codex = CodexAppServerClient(self._handle_codex_event)
        async with websockets.serve(
            self._handle_client,
            "0.0.0.0",
            self.config.port,
            max_size=MAX_WIRE_MESSAGE_SIZE,
            ping_interval=20,
            ping_timeout=20,
        ):
            self.event_queue.put(("server", f"正在监听端口 {self.config.port}"))
            await self.stop_event.wait()
        if self.codex:
            await self.codex.stop()

    async def _handle_client(self, connection: websockets.ServerConnection) -> None:
        remote = connection.remote_address
        remote_ip = str(remote[0]) if remote else ""
        remote_port = str(remote[1]) if isinstance(remote, tuple) and len(remote) > 1 else ""
        peer_label = f"{remote_ip}:{remote_port}" if remote_port else remote_ip
        if not self._is_allowed_address(remote_ip):
            await connection.close(code=4003, reason="local network only")
            return
        query = urllib.parse.parse_qs(urllib.parse.urlparse(connection.request.path).query)
        supplied_token = query.get("token", [""])[0]
        if not hmac.compare_digest(supplied_token, self.config.token):
            await connection.close(code=4001, reason="invalid token")
            self.event_queue.put(("error", f"拒绝了来自 {remote_ip} 的无效配对请求"))
            return
        self.event_queue.put(("client_connected", peer_label))
        self.connections.add(connection)
        await self._send_json(connection, {
            "type": "hello",
            "computer": socket.gethostname(),
            "version": "2.0.0",
        })
        await self._send_codex_snapshot(connection)
        last_action = 0.0
        try:
            async for raw in connection:
                now = time.monotonic()
                if now - last_action < 0.12:
                    await self._send_error(connection, "操作过于频繁")
                    continue
                last_action = now
                await self._handle_message(connection, raw)
        except websockets.ConnectionClosed:
            pass
        finally:
            self.connections.discard(connection)
            self.event_queue.put(("client_disconnected", peer_label))

    async def _handle_message(self, connection: websockets.ServerConnection, raw: str | bytes) -> None:
        if not isinstance(raw, str):
            await self._send_error(connection, "不支持二进制消息")
            return
        self._log_wire("手机→电脑", connection, raw)
        try:
            message = json.loads(raw)
        except json.JSONDecodeError:
            await self._send_error(connection, "消息格式错误")
            return
        if not isinstance(message, dict):
            await self._send_error(connection, "消息必须是 JSON 对象")
            return
        message_type = message.get("type")
        message_id = str(message.get("id", ""))
        if message_type == "input":
            text = message.get("text")
            submit_mode = message.get("submitMode")
            if submit_mode is None:
                submit_mode = "enter" if message.get("submit", False) else "none"
            if not isinstance(text, str) or submit_mode not in ("enter", "ctrl_enter", "none"):
                await self._send_error(connection, "输入参数错误", message_id)
                return
            if not text.strip() or len(text) > MAX_TEXT_LENGTH:
                await self._send_error(connection, f"文字长度必须为 1–{MAX_TEXT_LENGTH}", message_id)
                return
            ok, result = await asyncio.to_thread(self.input.type_text, text, submit_mode)
        elif message_type == "enter":
            ok, result = await asyncio.to_thread(self.input.press_enter)
        elif message_type == "ping":
            ok, result = True, "pong"
        elif message_type == "codex_snapshot_request":
            await self._send_codex_snapshot(connection)
            return
        elif message_type == "codex_thread_request":
            thread_id = str(message.get("threadId", ""))
            if not thread_id:
                await self._send_error(connection, "缺少 Codex 任务编号", message_id)
                return
            await self._send_codex_thread(connection, thread_id, message_id)
            return
        elif message_type == "codex_send":
            thread_id = str(message.get("threadId", ""))
            text = str(message.get("text", "")).strip()
            submit_mode = str(message.get("submitMode", "enter"))
            if (not thread_id or not text or len(text) > MAX_TEXT_LENGTH or
                    submit_mode not in ("enter", "ctrl_enter")):
                await self._send_error(connection, "Codex 任务或消息内容无效", message_id)
                return
            await self._codex_send(connection, thread_id, text, submit_mode, message_id)
            return
        elif message_type == "codex_interrupt":
            thread_id = str(message.get("threadId", ""))
            turn_id = str(message.get("turnId", ""))
            if not thread_id or not turn_id:
                await self._send_error(connection, "当前任务没有可停止的运行轮次", message_id)
                return
            await self._codex_interrupt(connection, thread_id, turn_id, message_id)
            return
        else:
            await self._send_error(connection, "未知操作", message_id)
            return
        self.event_queue.put(("action" if ok else "error", result))
        response_type = "ack" if ok else "error"
        await self._send_json(connection, {
            "type": response_type,
            "id": message_id,
            "message": result,
        })

    async def _send_codex_snapshot(self, connection: websockets.ServerConnection) -> None:
        assert self.codex is not None
        snapshot = await self.codex.snapshot()
        await self._send_json(connection, {"type": "codex_snapshot", **snapshot})

    async def _send_codex_thread(self, connection: websockets.ServerConnection,
                                 thread_id: str, message_id: str = "") -> None:
        assert self.codex is not None
        try:
            # Reading history must stay read-only. Resuming here leaves a second
            # app-server owning the same thread and makes the desktop view stale.
            detail = await self.codex.thread_detail(thread_id)
            await self._send_json(connection, {
                "type": "codex_thread", "id": message_id,
                "thread": self._phone_thread_detail(detail),
            })
        except Exception as error:
            await self._send_error(connection, f"读取 Codex 任务失败：{error}", message_id)

    async def _codex_send(self, connection: websockets.ServerConnection, thread_id: str,
                          text: str, submit_mode: str, message_id: str) -> None:
        assert self.codex is not None
        try:
            before = await self.codex.thread_detail(thread_id)
            baseline_messages = len(before.get("messages", []))
            thread_title = str(before.get("title", "")).strip()
            ok, result = await asyncio.to_thread(
                self._send_to_codex_desktop, thread_id, thread_title, text, submit_mode)
            if not ok:
                raise RuntimeError(result)
            await self._send_json(connection, {
                "type": "ack", "id": message_id,
                "message": "消息已发送给 Codex，电脑端已按" +
                           (" Ctrl+回车" if submit_mode == "ctrl_enter" else "回车"),
            })
            await self._broadcast({
                "type": "codex_event", "event": "turn/started",
                "params": {"threadId": thread_id},
            })
            previous_poll = self.codex_poll_tasks.get(thread_id)
            if previous_poll and not previous_poll.done():
                previous_poll.cancel()
            self.codex_poll_tasks[thread_id] = asyncio.create_task(
                self._poll_desktop_codex_thread(thread_id, baseline_messages))
            await self._schedule_codex_refresh()
        except Exception as error:
            error_text = str(error)
            if "thread not found" in error_text.lower():
                error_text = "任务暂时无法恢复，请刷新任务列表后重新选择"
            await self._send_error(connection, f"发送给 Codex 失败：{error_text}", message_id)

    def _send_to_codex_desktop(self, thread_id: str, thread_title: str,
                               text: str, submit_mode: str) -> tuple[bool, str]:
        if not thread_title:
            return False, "无法确认 Codex 任务标题"
        if not open_codex_thread(thread_id):
            return False, "无法打开电脑端 Codex 任务"
        focused, focus_result = focus_codex_composer(thread_title)
        if not focused:
            return False, focus_result
        ok, input_result = self.input.type_text(text, submit_mode)
        if not ok:
            return False, input_result
        return True, f"{focus_result}；{input_result}"

    async def _poll_desktop_codex_thread(self, thread_id: str, baseline_messages: int) -> None:
        assert self.codex is not None
        saw_activity = False
        try:
            for _ in range(150):
                await asyncio.sleep(2)
                detail = await self.codex.thread_detail(thread_id)
                active_turn_id = str(detail.get("activeTurnId", ""))
                messages = detail.get("messages")
                message_count = len(messages) if isinstance(messages, list) else 0
                if active_turn_id:
                    saw_activity = True
                if message_count > baseline_messages:
                    saw_activity = True
                await self._broadcast({
                    "type": "codex_thread", "thread": self._phone_thread_detail(detail),
                })
                if message_count >= baseline_messages + 2 and not active_turn_id and saw_activity:
                    await self._broadcast({
                        "type": "codex_event", "event": "turn/completed",
                        "params": {"threadId": thread_id},
                    })
                    await self._schedule_codex_refresh()
                    return
        except asyncio.CancelledError:
            raise
        except Exception as error:
            await self._broadcast({
                "type": "error",
                "message": f"同步电脑端 Codex 回复失败：{error}",
            })
        finally:
            current = self.codex_poll_tasks.get(thread_id)
            if current is asyncio.current_task():
                self.codex_poll_tasks.pop(thread_id, None)

    @staticmethod
    def _phone_thread_detail(detail: dict[str, object]) -> dict[str, object]:
        """Trim only the phone payload; keep the full detail for bridge logic."""
        messages = detail.get("messages")
        if not isinstance(messages, list) or len(messages) <= MAX_PHONE_DETAIL_MESSAGES:
            return detail
        payload = dict(detail)
        payload["messages"] = messages[-MAX_PHONE_DETAIL_MESSAGES:]
        return payload

    async def _codex_interrupt(self, connection: websockets.ServerConnection, thread_id: str,
                               turn_id: str, message_id: str) -> None:
        assert self.codex is not None
        try:
            await self.codex.interrupt(thread_id, turn_id)
            await self._send_json(connection, {
                "type": "ack", "id": message_id, "message": "已请求停止 Codex 任务",
            })
            await self._schedule_codex_refresh()
        except Exception as error:
            await self._send_error(connection, f"停止 Codex 任务失败：{error}", message_id)

    async def _handle_codex_event(self, method: str, params: dict[str, object]) -> None:
        if method in ("thread/status/changed", "turn/started", "turn/completed",
                      "account/rateLimits/updated"):
            await self._broadcast({"type": "codex_event", "event": method, "params": params})
            if method == "turn/completed":
                thread_id = str(params.get("threadId", ""))
                if thread_id in self.pending_desktop_open:
                    self.pending_desktop_open.discard(thread_id)
                    asyncio.create_task(self._open_completed_codex_thread(thread_id))
                    return
            await self._schedule_codex_refresh()

    async def _open_completed_codex_thread(self, thread_id: str) -> None:
        # The bridge and Codex Desktop are separate app-server clients. Release
        # the bridge-owned runtime completely so the desktop can reload the
        # persisted turn instead of keeping its stale in-memory copy.
        if self.codex_refresh_task and not self.codex_refresh_task.done():
            self.codex_refresh_task.cancel()
            await asyncio.gather(self.codex_refresh_task, return_exceptions=True)
        self.codex_refresh_task = None
        if self.codex:
            await self.codex.release_thread(thread_id)
            await self.codex.stop()
        await asyncio.sleep(0.8)
        opened = await asyncio.to_thread(open_codex_thread, thread_id)
        await self._broadcast({
            "type": "codex_event",
            "event": "desktop/opened" if opened else "desktop/openFailed",
            "params": {"threadId": thread_id},
        })
        await asyncio.sleep(0.8)
        await self._schedule_codex_refresh()

    async def _schedule_codex_refresh(self) -> None:
        if self.codex_refresh_task and not self.codex_refresh_task.done():
            return
        self.codex_refresh_task = asyncio.create_task(self._delayed_codex_refresh())

    async def _delayed_codex_refresh(self) -> None:
        await asyncio.sleep(0.45)
        if not self.codex or not self.connections:
            return
        snapshot = await self.codex.snapshot()
        await self._broadcast({"type": "codex_snapshot", **snapshot})
        if bool(snapshot.get("available", False)):
            await self._broadcast({
                "type": "codex_event",
                "event": "codex/refreshReady",
                "params": {},
            })

    async def _broadcast(self, message: dict[str, object]) -> None:
        if not self.connections:
            return
        raw = json.dumps(message, ensure_ascii=False)
        async def send_one(connection: websockets.ServerConnection) -> None:
            try:
                self._log_wire("电脑→手机", connection, message)
                await asyncio.wait_for(connection.send(raw), timeout=2)
            except (websockets.ConnectionClosed, asyncio.TimeoutError):
                self.connections.discard(connection)
        await asyncio.gather(*(send_one(connection) for connection in list(self.connections)))

    async def _send_json(self, connection: websockets.ServerConnection,
                         message: dict[str, object]) -> None:
        self._log_wire("电脑→手机", connection, message)
        await connection.send(json.dumps(message, ensure_ascii=False))

    def _log_wire(self, direction: str, connection: object, payload: object) -> None:
        """Send a readable, secret-safe wire record to the desktop log UI."""
        peer = "未知设备"
        try:
            remote = getattr(connection, "remote_address", None)
            if remote:
                peer = str(remote[0]) if isinstance(remote, tuple) else str(remote)
        except (AttributeError, IndexError, TypeError):
            pass
        if isinstance(payload, str):
            try:
                payload = json.loads(payload)
            except (TypeError, ValueError):
                pass
        safe_payload: object = payload
        try:
            safe_payload = self._safe_log_value(payload)
            detail = json.dumps(safe_payload, ensure_ascii=False, separators=(",", ":")) \
                if not isinstance(safe_payload, str) else safe_payload
        except (TypeError, ValueError):
            detail = str(safe_payload)
        self.event_queue.put(("wire", f"{direction} [{peer}] {detail}"))

    @classmethod
    def _safe_log_value(cls, value: object, key: str = "") -> object:
        key_lower = key.lower()
        if key_lower in ("token", "authorization", "pairingtoken"):
            return "[已隐藏]"
        if isinstance(value, dict):
            return {str(item_key): cls._safe_log_value(item_value, str(item_key))
                    for item_key, item_value in value.items()}
        if isinstance(value, list):
            return [cls._safe_log_value(item, key) for item in value]
        if isinstance(value, str) and value.startswith("data:image/"):
            return f"[图片数据已省略，长度={len(value)}]"
        return value

    async def _send_error(
        self,
        connection: websockets.ServerConnection,
        message: str,
        message_id: str = "",
    ) -> None:
        await self._send_json(connection, {
            "type": "error", "id": message_id, "message": message,
        })

    @staticmethod
    def _is_allowed_address(value: str) -> bool:
        try:
            address = ipaddress.ip_address(value)
            return address.is_private or address.is_loopback or address.is_link_local
        except ValueError:
            return False


def get_lan_ip() -> str:
    probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        probe.connect(("8.8.8.8", 80))
        return str(probe.getsockname()[0])
    except OSError:
        try:
            return socket.gethostbyname(socket.gethostname())
        except OSError:
            return "127.0.0.1"
    finally:
        probe.close()


def create_tray_image() -> Image.Image:
    image = Image.new("RGBA", (64, 64), "#175CD3")
    draw = ImageDraw.Draw(image)
    draw.ellipse((14, 9, 50, 45), fill="white")
    draw.rounded_rectangle((28, 37, 36, 55), radius=3, fill="white")
    draw.arc((20, 28, 44, 54), 0, 180, fill="white", width=4)
    return image


class BridgeApp:
    def __init__(self) -> None:
        self.config = BridgeConfig.load()
        if not is_port_available(self.config.port):
            self.config.port = find_available_port(self.config.port)
            self.config.save()
        self.events: queue.Queue[tuple[str, str]] = queue.Queue()
        self.server = BridgeServer(self.config, self.events)
        self.root = tk.Tk()
        self.root.title(APP_TITLE)
        self.root.geometry("520x720")
        self.root.minsize(480, 640)
        self.root.protocol("WM_DELETE_WINDOW", self.hide_to_tray)
        self.status_var = tk.StringVar(value="正在启动…")
        self.address_var = tk.StringVar()
        self.paired_devices_var = tk.StringVar(value="暂无手机连接")
        self.connected_devices: set[str] = set()
        self.qr_collapsed = False
        self.log_collapsed = False
        self.log_text: tk.Text
        self.qr_photo: ImageTk.PhotoImage | None = None
        self.tray: pystray.Icon | None = None
        self._build_ui()
        self._refresh_pairing_view()
        self.server.start()
        self._start_tray()
        self.root.after(120, self._poll_events)

    def run(self) -> None:
        self.root.mainloop()

    def _build_ui(self) -> None:
        outer = ttk.Frame(self.root, padding=20)
        outer.pack(fill=tk.BOTH, expand=True)
        ttk.Label(outer, text="Starly 电脑端", font=("Microsoft YaHei UI", 22, "bold")).pack(anchor=tk.W)
        ttk.Label(outer, text="手机说话，文字出现在电脑当前输入框", foreground="#667085").pack(anchor=tk.W, pady=(4, 14))
        status = ttk.Frame(outer, padding=12)
        status.pack(fill=tk.X, pady=(0, 14))
        ttk.Label(status, textvariable=self.status_var, font=("Microsoft YaHei UI", 10, "bold")).pack(anchor=tk.W)
        qr_frame = ttk.LabelFrame(outer, text="手机扫码配对", padding=14)
        qr_frame.pack(fill=tk.X)
        qr_header = ttk.Frame(qr_frame)
        qr_header.pack(fill=tk.X, pady=(0, 8))
        ttk.Label(qr_header, text="扫码后手机即可连接电脑").pack(side=tk.LEFT)
        self.qr_toggle_button = ttk.Button(qr_header, text="收起二维码", command=self.toggle_qr)
        self.qr_toggle_button.pack(side=tk.RIGHT)
        self.qr_body = ttk.Frame(qr_frame)
        self.qr_body.pack(fill=tk.X)
        self.qr_label = ttk.Label(self.qr_body)
        self.qr_label.pack(pady=(0, 8))
        ttk.Label(self.qr_body, textvariable=self.address_var, foreground="#475467").pack()
        button_row = ttk.Frame(self.qr_body)
        button_row.pack(fill=tk.X, pady=(12, 0))
        ttk.Button(button_row, text="复制配对信息", command=self.copy_pairing).pack(side=tk.LEFT, expand=True, fill=tk.X, padx=(0, 6))
        ttk.Button(button_row, text="更换配对密钥", command=self.regenerate_token).pack(side=tk.LEFT, expand=True, fill=tk.X, padx=(6, 0))
        paired_frame = ttk.LabelFrame(outer, text="已配对手机", padding=12)
        paired_frame.pack(fill=tk.X, pady=(10, 0))
        ttk.Label(paired_frame, textvariable=self.paired_devices_var, foreground="#175CD3",
                  justify=tk.LEFT, anchor=tk.W, wraplength=460).pack(fill=tk.X)
        options = ttk.Frame(outer)
        options.pack(fill=tk.X, pady=14)
        ttk.Button(options, text="最小化到托盘", command=self.hide_to_tray).pack(side=tk.LEFT)
        ttk.Button(options, text="设置开机启动", command=self.enable_autostart).pack(side=tk.LEFT, padx=8)
        ttk.Button(options, text="取消开机启动", command=self.disable_autostart).pack(side=tk.LEFT)
        log_frame = ttk.LabelFrame(outer, text="运行记录", padding=10)
        log_frame.pack(fill=tk.BOTH, expand=True, pady=(0, 8))
        log_header = ttk.Frame(log_frame)
        log_header.pack(fill=tk.X, pady=(0, 6))
        ttk.Label(log_header, text="显示精简收发摘要，完整日志仍保存到本机").pack(side=tk.LEFT)
        self.log_toggle_button = ttk.Button(log_header, text="收起日志", command=self.toggle_log)
        self.log_toggle_button.pack(side=tk.RIGHT)
        self.log_body = ttk.Frame(log_frame)
        self.log_body.pack(fill=tk.BOTH, expand=True)
        self.log_text = tk.Text(self.log_body, height=8, state=tk.DISABLED, wrap=tk.WORD,
                                relief=tk.FLAT, background="#F2F4F7")
        log_scrollbar = ttk.Scrollbar(self.log_body, orient=tk.VERTICAL, command=self.log_text.yview)
        self.log_text.configure(yscrollcommand=log_scrollbar.set)
        self.log_text.pack(side=tk.LEFT, fill=tk.BOTH, expand=True)
        log_scrollbar.pack(side=tk.RIGHT, fill=tk.Y)
        self._load_existing_log()
        ttk.Label(
            outer,
            text="使用时先最小化本窗口，再点击电脑上的目标输入框。为安全起见，仅接受局域网设备和正确配对密钥。",
            foreground="#667085",
            wraplength=460,
        ).pack(anchor=tk.W)

    def _pairing_uri(self) -> str:
        return "starly://pair?" + urllib.parse.urlencode({
            "host": get_lan_ip(),
            "port": self.config.port,
            "token": self.config.token,
        })

    def _refresh_pairing_view(self) -> None:
        uri = self._pairing_uri()
        qr = qrcode.QRCode(version=None, box_size=6, border=3)
        qr.add_data(uri)
        qr.make(fit=True)
        image = qr.make_image(fill_color="#101828", back_color="white").convert("RGB")
        image.thumbnail((260, 260), Image.Resampling.LANCZOS)
        self.qr_photo = ImageTk.PhotoImage(image)
        self.qr_label.configure(image=self.qr_photo)
        self.address_var.set(f"{get_lan_ip()}:{self.config.port}")

    def _poll_events(self) -> None:
        while True:
            try:
                event_type, message = self.events.get_nowait()
            except queue.Empty:
                break
            if event_type == "client_connected":
                self.connected_devices.add(message)
                self._refresh_paired_devices()
                display_message = f"手机已配对：{message}"
            elif event_type == "client_disconnected":
                self.connected_devices.discard(message)
                self._refresh_paired_devices()
                display_message = f"手机已断开：{message}"
            elif event_type == "wire":
                display_message = self._compact_wire_message(message)
            else:
                display_message = message
            self.status_var.set(display_message)
            self._append_log(display_message, file_message=message if event_type == "wire" else None)
            if event_type == "action":
                try:
                    import winsound
                    winsound.MessageBeep(winsound.MB_OK)
                except OSError:
                    pass
        self.root.after(120, self._poll_events)

    def _refresh_paired_devices(self) -> None:
        if not self.connected_devices:
            self.paired_devices_var.set("暂无手机连接")
            return
        devices = sorted(self.connected_devices)
        lines = [f"当前已配对 {len(devices)} 部手机"]
        lines.extend(f"• {device}" for device in devices)
        self.paired_devices_var.set("\n".join(lines))

    def toggle_qr(self) -> None:
        self.qr_collapsed = not self.qr_collapsed
        if self.qr_collapsed:
            self.qr_body.pack_forget()
            self.qr_toggle_button.configure(text="展开二维码")
        else:
            self.qr_body.pack(fill=tk.X)
            self.qr_toggle_button.configure(text="收起二维码")

    def toggle_log(self) -> None:
        self.log_collapsed = not self.log_collapsed
        if self.log_collapsed:
            self.log_body.pack_forget()
            self.log_toggle_button.configure(text="展开日志")
        else:
            self.log_body.pack(fill=tk.BOTH, expand=True)
            self.log_toggle_button.configure(text="收起日志")

    @staticmethod
    def _compact_wire_message(message: str) -> str:
        """Keep the live window readable while retaining the full wire record on disk."""
        brace = message.find("{")
        if brace < 0:
            return message[:280] + ("…" if len(message) > 280 else "")
        prefix = message[:brace].strip()
        try:
            payload = json.loads(message[brace:])
        except (TypeError, ValueError):
            return message[:280] + ("…" if len(message) > 280 else "")
        message_type = str(payload.get("type", "消息"))
        if message_type == "codex_snapshot":
            tasks = payload.get("threads")
            task_count = len(tasks) if isinstance(tasks, list) else 0
            return f"{prefix} {message_type}（任务 {task_count} 个）"
        if message_type == "codex_thread":
            thread = payload.get("thread")
            if isinstance(thread, dict):
                title = str(thread.get("title", "任务"))[:36]
                messages = thread.get("messages")
                count = len(messages) if isinstance(messages, list) else 0
                return f"{prefix} {message_type}（{title}，对话 {count} 条）"
        if message_type == "codex_event":
            return f"{prefix} codex_event（{payload.get('event', '状态更新')}）"
        if message_type in ("ack", "error"):
            return f"{prefix} {message_type}：{str(payload.get('message', ''))[:100]}"
        if message_type in ("input", "codex_send"):
            text = str(payload.get("text", "")).replace("\r", " ").replace("\n", " ")
            return f"{prefix} {message_type}：{text[:100]}"
        return f"{prefix} {message_type}"

    def _append_log(self, message: str, file_message: str | None = None) -> None:
        """Show a compact live line and persist the complete record to disk."""
        timestamp = time.strftime("%Y-%m-%d %H:%M:%S  ")
        line = timestamp + message
        self.log_text.configure(state=tk.NORMAL)
        self.log_text.insert(tk.END, line + "\n")
        self.log_text.see(tk.END)
        self.log_text.configure(state=tk.DISABLED)
        file_line = timestamp + (file_message if file_message is not None else message)
        try:
            CONFIG_DIR.mkdir(parents=True, exist_ok=True)
            with LOG_PATH.open("a", encoding="utf-8") as handle:
                handle.write(file_line + "\n")
        except OSError:
            # The live UI line remains available even if the disk log cannot be written.
            pass

    def _load_existing_log(self) -> None:
        try:
            lines = LOG_PATH.read_text(encoding="utf-8").splitlines()[-300:]
        except (OSError, UnicodeError):
            return
        if not lines:
            return
        compact_lines = [self._compact_wire_message(line) if "手机→电脑" in line or
                         "电脑→手机" in line else line for line in lines]
        self.log_text.configure(state=tk.NORMAL)
        self.log_text.insert(tk.END, "—— 已加载最近运行记录 ——\n" +
                             "\n".join(compact_lines) + "\n")
        self.log_text.see(tk.END)
        self.log_text.configure(state=tk.DISABLED)

    def copy_pairing(self) -> None:
        self.root.clipboard_clear()
        self.root.clipboard_append(self._pairing_uri())
        self.status_var.set("配对信息已复制")

    def regenerate_token(self) -> None:
        if not messagebox.askyesno("更换密钥", "现有手机连接会失效，需要重新扫码。是否继续？"):
            return
        self.server.stop()
        self.config.token = secrets.token_urlsafe(32)
        self.config.save()
        self.server = BridgeServer(self.config, self.events)
        self.server.start()
        self._refresh_pairing_view()
        self._append_log("配对密钥已更换")

    def _autostart_command(self) -> str:
        executable = Path(sys.executable).resolve()
        if getattr(sys, "frozen", False):
            return f'"{executable}" --background'
        return f'"{executable}" "{Path(__file__).resolve()}" --background'

    def enable_autostart(self) -> None:
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, r"Software\Microsoft\Windows\CurrentVersion\Run", 0, winreg.KEY_SET_VALUE) as key:
            winreg.SetValueEx(key, APP_NAME, 0, winreg.REG_SZ, self._autostart_command())
        self.status_var.set("已设置开机启动")

    def disable_autostart(self) -> None:
        try:
            with winreg.OpenKey(winreg.HKEY_CURRENT_USER, r"Software\Microsoft\Windows\CurrentVersion\Run", 0, winreg.KEY_SET_VALUE) as key:
                winreg.DeleteValue(key, APP_NAME)
            self.status_var.set("已取消开机启动")
        except FileNotFoundError:
            self.status_var.set("当前未设置开机启动")

    def _start_tray(self) -> None:
        menu = pystray.Menu(
            pystray.MenuItem("显示 Starly", lambda _icon, _item: self.root.after(0, self.show_window), default=True),
            pystray.MenuItem("退出", lambda _icon, _item: self.root.after(0, self.exit_app)),
        )
        self.tray = pystray.Icon(APP_NAME, create_tray_image(), APP_TITLE, menu)
        threading.Thread(target=self.tray.run, name="StarlyTray", daemon=True).start()

    def hide_to_tray(self) -> None:
        self.root.withdraw()

    def show_window(self) -> None:
        self.root.deiconify()
        self.root.lift()
        self.root.focus_force()

    def exit_app(self) -> None:
        self.server.stop()
        if self.tray:
            self.tray.stop()
        self.root.destroy()


def main() -> None:
    if not acquire_single_instance():
        return
    app = BridgeApp()
    if "--background" in sys.argv:
        app.root.after(300, app.hide_to_tray)
    app.run()


if __name__ == "__main__":
    main()
