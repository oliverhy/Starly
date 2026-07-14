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
CONFIG_DIR = Path(os.environ.get("APPDATA", Path.home())) / APP_NAME
CONFIG_PATH = CONFIG_DIR / "config.json"
SINGLE_INSTANCE_MUTEX = "Local\\StarlyBridge.SingleInstance"
_single_instance_handle: int | None = None


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
            max_size=MAX_TEXT_LENGTH * 4,
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
        if not self._is_allowed_address(remote_ip):
            await connection.close(code=4003, reason="local network only")
            return
        query = urllib.parse.parse_qs(urllib.parse.urlparse(connection.request.path).query)
        supplied_token = query.get("token", [""])[0]
        if not hmac.compare_digest(supplied_token, self.config.token):
            await connection.close(code=4001, reason="invalid token")
            self.event_queue.put(("error", f"拒绝了来自 {remote_ip} 的无效配对请求"))
            return
        self.event_queue.put(("client", f"手机已连接：{remote_ip}"))
        self.connections.add(connection)
        await connection.send(json.dumps({
            "type": "hello",
            "computer": socket.gethostname(),
            "version": "2.0.0",
        }, ensure_ascii=False))
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
            self.event_queue.put(("client", "手机连接已断开"))

    async def _handle_message(self, connection: websockets.ServerConnection, raw: str | bytes) -> None:
        if not isinstance(raw, str):
            await self._send_error(connection, "不支持二进制消息")
            return
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
            if not thread_id or not text or len(text) > MAX_TEXT_LENGTH:
                await self._send_error(connection, "Codex 任务或消息内容无效", message_id)
                return
            await self._codex_send(connection, thread_id, text, message_id)
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
        await connection.send(json.dumps({
            "type": response_type,
            "id": message_id,
            "message": result,
        }, ensure_ascii=False))

    async def _send_codex_snapshot(self, connection: websockets.ServerConnection) -> None:
        assert self.codex is not None
        snapshot = await self.codex.snapshot()
        await connection.send(json.dumps({"type": "codex_snapshot", **snapshot}, ensure_ascii=False))

    async def _send_codex_thread(self, connection: websockets.ServerConnection,
                                 thread_id: str, message_id: str = "") -> None:
        assert self.codex is not None
        try:
            # Selecting a persisted task also restores it into this app-server
            # session, so later commands can start reliably.
            detail = await self.codex.resume_thread_detail(thread_id)
            await connection.send(json.dumps({
                "type": "codex_thread", "id": message_id, "thread": detail,
            }, ensure_ascii=False))
        except Exception as error:
            await self._send_error(connection, f"读取 Codex 任务失败：{error}", message_id)

    async def _codex_send(self, connection: websockets.ServerConnection, thread_id: str,
                          text: str, message_id: str) -> None:
        assert self.codex is not None
        try:
            await self.codex.send_message(thread_id, text)
            await connection.send(json.dumps({
                "type": "ack", "id": message_id, "message": "消息已发送给 Codex",
            }, ensure_ascii=False))
            await self._send_codex_thread(connection, thread_id)
            await self._schedule_codex_refresh()
        except Exception as error:
            error_text = str(error)
            if "thread not found" in error_text.lower():
                error_text = "任务暂时无法恢复，请刷新任务列表后重新选择"
            await self._send_error(connection, f"发送给 Codex 失败：{error_text}", message_id)

    async def _codex_interrupt(self, connection: websockets.ServerConnection, thread_id: str,
                               turn_id: str, message_id: str) -> None:
        assert self.codex is not None
        try:
            await self.codex.interrupt(thread_id, turn_id)
            await connection.send(json.dumps({
                "type": "ack", "id": message_id, "message": "已请求停止 Codex 任务",
            }, ensure_ascii=False))
            await self._schedule_codex_refresh()
        except Exception as error:
            await self._send_error(connection, f"停止 Codex 任务失败：{error}", message_id)

    async def _handle_codex_event(self, method: str, params: dict[str, object]) -> None:
        if method in ("thread/status/changed", "turn/started", "turn/completed",
                      "account/rateLimits/updated"):
            await self._broadcast({"type": "codex_event", "event": method, "params": params})
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

    async def _broadcast(self, message: dict[str, object]) -> None:
        if not self.connections:
            return
        raw = json.dumps(message, ensure_ascii=False)
        async def send_one(connection: websockets.ServerConnection) -> None:
            try:
                await asyncio.wait_for(connection.send(raw), timeout=2)
            except (websockets.ConnectionClosed, asyncio.TimeoutError):
                self.connections.discard(connection)
        await asyncio.gather(*(send_one(connection) for connection in list(self.connections)))

    async def _send_error(
        self,
        connection: websockets.ServerConnection,
        message: str,
        message_id: str = "",
    ) -> None:
        await connection.send(json.dumps({"type": "error", "id": message_id, "message": message}, ensure_ascii=False))

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
        self.qr_label = ttk.Label(qr_frame)
        self.qr_label.pack(pady=(0, 8))
        ttk.Label(qr_frame, textvariable=self.address_var, foreground="#475467").pack()
        button_row = ttk.Frame(qr_frame)
        button_row.pack(fill=tk.X, pady=(12, 0))
        ttk.Button(button_row, text="复制配对信息", command=self.copy_pairing).pack(side=tk.LEFT, expand=True, fill=tk.X, padx=(0, 6))
        ttk.Button(button_row, text="更换配对密钥", command=self.regenerate_token).pack(side=tk.LEFT, expand=True, fill=tk.X, padx=(6, 0))
        options = ttk.Frame(outer)
        options.pack(fill=tk.X, pady=14)
        ttk.Button(options, text="最小化到托盘", command=self.hide_to_tray).pack(side=tk.LEFT)
        ttk.Button(options, text="设置开机启动", command=self.enable_autostart).pack(side=tk.LEFT, padx=8)
        ttk.Button(options, text="取消开机启动", command=self.disable_autostart).pack(side=tk.LEFT)
        ttk.Label(outer, text="运行记录", font=("Microsoft YaHei UI", 11, "bold")).pack(anchor=tk.W)
        self.log_text = tk.Text(outer, height=10, state=tk.DISABLED, wrap=tk.WORD, relief=tk.FLAT, background="#F2F4F7")
        self.log_text.pack(fill=tk.BOTH, expand=True, pady=(8, 8))
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
            self.status_var.set(message)
            self._append_log(message)
            if event_type == "action":
                try:
                    import winsound
                    winsound.MessageBeep(winsound.MB_OK)
                except OSError:
                    pass
        self.root.after(120, self._poll_events)

    def _append_log(self, message: str) -> None:
        self.log_text.configure(state=tk.NORMAL)
        self.log_text.insert(tk.END, time.strftime("%H:%M:%S  ") + message + "\n")
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
