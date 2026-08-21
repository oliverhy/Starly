from __future__ import annotations

import asyncio
import base64
import binascii
import ctypes
import hmac
import io
import ipaddress
import json
import os
import queue
import re
import secrets
import socket
import struct
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
    from watchdog.events import FileSystemEvent, FileSystemEventHandler
    from watchdog.observers import Observer
except ImportError:  # Source checkouts can still use the slower polling fallback.
    FileSystemEvent = object  # type: ignore[assignment,misc]
    FileSystemEventHandler = object  # type: ignore[assignment,misc]
    Observer = None  # type: ignore[assignment,misc]

try:
    from pc.codex_client import (CodexAppServerClient, read_rollout_thread_detail,
                                 read_thread_goal)
    from pc.codex_queue import (ACTIVE_STATES, TERMINAL_STATES, CodexQueueItem,
                                CodexQueueStore)
    from pc.gateway_client import GatewayBridgeClient, GatewayRelayConnection
    from pc.gateway_crypto import GatewayCrypto, generate_device_identity
    from pc.secret_store import protect_secret, unprotect_secret
except ImportError:
    from codex_client import CodexAppServerClient, read_rollout_thread_detail, read_thread_goal
    from codex_queue import (ACTIVE_STATES, TERMINAL_STATES, CodexQueueItem,
                             CodexQueueStore)
    from gateway_client import GatewayBridgeClient, GatewayRelayConnection
    from gateway_crypto import GatewayCrypto, generate_device_identity
    from secret_store import protect_secret, unprotect_secret


APP_NAME = "StarlyBridge"
APP_TITLE = "Starly 电脑端"
DEFAULT_PORT = 8765
DEFAULT_DISCOVERY_PORT = 8766
DISCOVERY_PROTOCOL_VERSION = 1
PAIRING_FAILURE_LIMIT = 5
PAIRING_FAILURE_WINDOW_SECONDS = 60
MAX_TEXT_LENGTH = 8000
MAX_IMAGE_BYTES = 6 * 1024 * 1024
MAX_PHONE_DETAIL_MESSAGES = 15
MAX_PHONE_ACTIVITIES = 30
MAX_WIRE_MESSAGE_SIZE = 16 * 1024 * 1024
CONFIG_DIR = Path(os.environ.get("APPDATA", Path.home())) / APP_NAME
CONFIG_PATH = CONFIG_DIR / "config.json"
LOG_PATH = CONFIG_DIR / "bridge.log"
SINGLE_INSTANCE_MUTEX = "Local\\StarlyBridge.SingleInstance"
_single_instance_handle: int | None = None
ROLLOUT_THREAD_PATTERN = re.compile(r"([0-9a-fA-F-]{36})\.jsonl$")


class RolloutEventHandler(FileSystemEventHandler):  # type: ignore[misc,valid-type]
    def __init__(self, callback) -> None:
        super().__init__()
        self.callback = callback

    def on_created(self, event: FileSystemEvent) -> None:
        self._handle(event)

    def on_modified(self, event: FileSystemEvent) -> None:
        self._handle(event)

    def on_moved(self, event: FileSystemEvent) -> None:
        destination = str(getattr(event, "dest_path", ""))
        if destination:
            self.callback(destination)

    def _handle(self, event: FileSystemEvent) -> None:
        if not bool(getattr(event, "is_directory", False)):
            self.callback(str(getattr(event, "src_path", "")))


def normalize_gateway_url(value: str) -> str:
    """Return a canonical Gateway /ws URL and reject insecure public transports."""
    raw = value.strip()
    if not raw:
        return ""
    if "://" not in raw:
        raw = "wss://" + raw
    try:
        parsed = urllib.parse.urlsplit(raw)
        port = parsed.port
    except ValueError as error:
        raise ValueError("服务器地址或端口格式不正确") from error
    scheme = parsed.scheme.lower()
    hostname = (parsed.hostname or "").strip().lower()
    if not hostname or parsed.username or parsed.password or parsed.query or parsed.fragment:
        raise ValueError("服务器地址不能包含账号、查询参数或片段")
    local_hosts = {"127.0.0.1", "localhost", "::1"}
    if scheme != "wss" and not (scheme == "ws" and hostname in local_hosts):
        raise ValueError("公网服务器必须使用 wss:// 加密连接")
    path = parsed.path.rstrip("/")
    if path in ("", "/"):
        path = "/ws"
    if path != "/ws":
        raise ValueError("服务器地址路径必须为 /ws")
    rendered_host = f"[{hostname}]" if ":" in hostname else hostname
    rendered_port = f":{port}" if port is not None else ""
    return f"{scheme}://{rendered_host}{rendered_port}/ws"


def _approval_value(params: dict[str, object], *names: str) -> object:
    for name in names:
        value = params.get(name)
        if value not in (None, "", [], {}):
            return value
    for container_name in ("item", "request", "context", "commandExecution", "fileChange"):
        container = params.get(container_name)
        if isinstance(container, dict):
            for name in names:
                value = container.get(name)
                if value not in (None, "", [], {}):
                    return value
    return ""


def normalize_approval(method: str, params: dict[str, object]) -> dict[str, object]:
    """Add stable, display-safe approval context and conservative risk metadata."""
    normalized = dict(params)
    command_value = _approval_value(params, "command", "cmd", "commandLine")
    if isinstance(command_value, list):
        command = " ".join(str(part) for part in command_value)
    else:
        command = str(command_value or "")
    cwd = str(_approval_value(params, "cwd", "workingDirectory", "workdir") or "")
    reason = str(_approval_value(params, "reason", "message", "justification") or "")
    permissions_value = _approval_value(params, "permissions", "requestedPermissions")
    permissions = permissions_value if isinstance(permissions_value, dict) else {}
    permission_summary = ", ".join(
        f"{key}={json.dumps(value, ensure_ascii=False, separators=(',', ':'))}"
        for key, value in sorted(permissions.items()))

    risk_reasons: list[str] = []
    command_lower = command.lower()
    destructive_patterns = (
        r"\b(rm|rmdir|del|erase|format|diskpart|shutdown|reboot|sudo|runas)\b",
        r"\b(remove-item|clear-disk|format-volume|stop-computer|restart-computer)\b",
        r"\b(set-content|add-content|out-file|move-item|copy-item|rename-item)\b",
        r"\bgit\s+(reset\s+--hard|clean\s+-[a-z]*f)",
        r"\b(reg\s+delete|bcdedit|cipher\s+/w)\b",
        r"\b(invoke-expression|iex)\b",
    )
    if any(re.search(pattern, command_lower) for pattern in destructive_patterns):
        risk_reasons.append("命令可能删除数据、修改系统状态或提升权限")
    if method == "item/permissions/requestApproval" or permissions:
        risk_reasons.append("操作请求扩大当前权限范围")
    if re.search(r"(?:curl|wget|irm|invoke-webrequest).*(?:\||iex|sh\b|bash\b)", command_lower):
        risk_reasons.append("命令可能下载并直接执行远程内容")

    high_risk = bool(risk_reasons)
    risk_level = "high" if high_risk else (
        "medium" if method in (
            "item/commandExecution/requestApproval", "item/fileChange/requestApproval") else "low")
    if not risk_reasons and risk_level == "medium":
        risk_reasons.append("操作将执行命令或修改文件，请核对内容")

    normalized.update({
        "approvalMethod": method,
        "command": command,
        "cwd": cwd,
        "reason": reason,
        "permissions": permissions,
        "permissionsSummary": permission_summary,
        "riskLevel": risk_level,
        "riskReasons": risk_reasons,
        "highRisk": high_risk,
    })
    return normalized


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
  [StructLayout(LayoutKind.Sequential)]
  public struct RECT { public int Left, Top, Right, Bottom; }
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int command);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(
    uint flags, uint dx, uint dy, uint data, UIntPtr extra);
}
'@
function Test-ComposerFocus([int]$processId) {
  try {
    $focused = [System.Windows.Automation.AutomationElement]::FocusedElement
    return ($focused.Current.ProcessId -eq $processId -and
            $focused.Current.ClassName -match '(^| )ProseMirror( |$)')
  } catch { return $false }
}
function Invoke-ComposerFocus($element, [int]$processId) {
  try {
    $element.SetFocus()
    Start-Sleep -Milliseconds 100
    if (Test-ComposerFocus $processId) { return $true }
  } catch {}
  try {
    $rect = $element.Current.BoundingRectangle
    if ($rect.Width -lt 1 -or $rect.Height -lt 1) { return $false }
    $clickX = [int]($rect.X + $rect.Width / 2)
    $clickY = [int]($rect.Y + [Math]::Min($rect.Height / 2, $rect.Height - 12))
    [StarlyCodexUi]::SetCursorPos($clickX, $clickY) | Out-Null
    [StarlyCodexUi]::mouse_event(2, 0, 0, 0, [UIntPtr]::Zero)
    [StarlyCodexUi]::mouse_event(4, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 140
    return (Test-ComposerFocus $processId)
  } catch { return $false }
}
$threadLabel = $env:STARLY_CODEX_THREAD_TITLE
$deadline = [DateTime]::UtcNow.AddSeconds(12)
while ([DateTime]::UtcNow -lt $deadline) {
  # Reading Chromium's UI Automation tree can block while navigation is in
  # progress. Get the native top-level handle directly from the process.
  $handle = [IntPtr]::Zero
  $mainProcessId = 0
  $windowRect = [StarlyCodexUi+RECT]::new()
  $mainArea = 0
  $processes = @(Get-Process ChatGPT -ErrorAction SilentlyContinue | Where-Object {
    try { $_.Path -like '*OpenAI.Codex_*' } catch { $false }
  })
  foreach ($process in $processes) {
    $candidateHandle = [IntPtr]$process.MainWindowHandle
    if ($candidateHandle -eq [IntPtr]::Zero) { continue }
    $candidateRect = [StarlyCodexUi+RECT]::new()
    if (-not [StarlyCodexUi]::GetWindowRect($candidateHandle, [ref]$candidateRect)) { continue }
    $area = ($candidateRect.Right - $candidateRect.Left) * ($candidateRect.Bottom - $candidateRect.Top)
    if ($area -gt $mainArea) {
      $handle = $candidateHandle
      $mainProcessId = $process.Id
      $windowRect = $candidateRect
      $mainArea = $area
    }
  }
  if ($handle -eq [IntPtr]::Zero -or $mainArea -lt 300000) {
    Start-Sleep -Milliseconds 350
    continue
  }

  [StarlyCodexUi]::ShowWindow($handle, 9) | Out-Null
  [StarlyCodexUi]::SetForegroundWindow($handle) | Out-Null
  Start-Sleep -Milliseconds 160
  [StarlyCodexUi]::GetWindowRect($handle, [ref]$windowRect) | Out-Null
  $windowWidth = $windowRect.Right - $windowRect.Left
  $windowHeight = $windowRect.Bottom - $windowRect.Top

  # Locate the real contenteditable control first. This keeps working when a
  # browser, terminal, or preview is docked beside the Codex conversation.
  try {
    $root = [System.Windows.Automation.AutomationElement]::FromHandle($handle)
    $candidates = @()
    foreach ($element in $root.FindAll(
        [System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.Condition]::TrueCondition)) {
      try {
        $rect = $element.Current.BoundingRectangle
        $bottom = $rect.Y + $rect.Height
        $insideWindow = $rect.X -ge $windowRect.Left -and
          $rect.X + $rect.Width -le $windowRect.Right -and
          $rect.Y -ge $windowRect.Top -and $bottom -le $windowRect.Bottom
        if ($element.Current.ProcessId -eq $mainProcessId -and
            $element.Current.ClassName -match '(^| )ProseMirror( |$)' -and
            -not $element.Current.IsOffscreen -and $element.Current.IsEnabled -and
            $insideWindow -and $rect.Width -ge 160 -and $rect.Height -ge 32 -and
            $bottom -ge ($windowRect.Top + $windowHeight * 0.55)) {
          $candidates += [PSCustomObject]@{
            Element = $element
            Left = $rect.X
            Bottom = $bottom
          }
        }
      } catch {}
    }
    # The Codex conversation is the left-most content pane when another tool
    # is docked on the right. Bottom position breaks ties between candidates.
    foreach ($candidate in @($candidates | Sort-Object Left,
        @{Expression='Bottom'; Descending=$true})) {
      if (Invoke-ComposerFocus $candidate.Element $mainProcessId) {
        Write-Output ('FOCUSED|' + $threadLabel + '|ProseMirror|automation')
        exit 0
      }
    }
  } catch {}

  # Coordinate fallback tries the left conversation pane first, then wider
  # layouts. Every click is verified before any keyboard input is injected.
  foreach ($bottomOffset in @(72, 108, 145)) {
    foreach ($widthFactor in @(0.35, 0.50, 0.62, 0.74)) {
      $clickX = [int]($windowRect.Left + $windowWidth * $widthFactor)
      $clickY = [int]($windowRect.Bottom - $bottomOffset)
      [StarlyCodexUi]::SetCursorPos($clickX, $clickY) | Out-Null
      [StarlyCodexUi]::mouse_event(2, 0, 0, 0, [UIntPtr]::Zero)
      [StarlyCodexUi]::mouse_event(4, 0, 0, 0, [UIntPtr]::Zero)
      Start-Sleep -Milliseconds 160
      if (Test-ComposerFocus $mainProcessId) {
        Write-Output ('FOCUSED|' + $threadLabel + '|ProseMirror|fallback')
        exit 0
      }
    }
  }
  Start-Sleep -Milliseconds 300
}
Write-Output ('TASK_NOT_READY|' + $threadLabel)
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
            timeout=16,
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


def desktop_model_labels(model: str) -> list[str]:
    value = model.strip()
    if not value:
        return []
    labels = [value]
    pretty = re.sub(r"^gpt-", "GPT-", value, flags=re.IGNORECASE)
    parts = pretty.split("-")
    if len(parts) >= 3:
        labels.extend([pretty, "-".join(parts[1:]), " ".join(parts[1:])])
    return list(dict.fromkeys(label for label in labels if label))


def desktop_effort_labels(effort: str) -> list[str]:
    return {
        "none": ["None", "无"], "minimal": ["Minimal", "最低"],
        "low": ["Low", "低"], "medium": ["Medium", "中"],
        "high": ["High", "高"], "xhigh": ["Extra high", "XHigh", "极高"],
        "max": ["Max", "最高"], "ultra": ["Ultra", "超高"],
    }.get(effort.strip().lower(), [effort.strip()] if effort.strip() else [])


def desktop_permission_labels(permission_mode: str) -> list[str]:
    return {
        "default": ["Default permissions", "Default", "默认权限"],
        "autoapprove": ["Auto-review", "Auto review", "自动审批", "自动审核"],
        "readonly": ["Read only", "Read-only", "只读"],
        "fullaccess": ["Full access", "完全访问权限", "完全访问"],
    }.get(permission_mode.strip().lower(), [])


def desktop_speed_labels(service_tier: str) -> list[str]:
    return {
        "fast": ["Fast", "Priority", "快速"],
        "priority": ["Fast", "Priority", "快速"],
        "standard": ["Standard", "标准"],
    }.get(service_tier.strip().lower(), [])


CODEX_COMPOSER_SETTINGS_SCRIPT = r"""
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class StarlyCodexSettingsUi {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int command);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f,uint x,uint y,uint d,UIntPtr e);
}
'@
function Split-Labels([string]$value) {
  if ([string]::IsNullOrWhiteSpace($value)) { return @() }
  return @($value -split [char]31 | Where-Object { $_ })
}
function Matches([string]$name, [string[]]$labels) {
  foreach ($label in $labels) {
    if ($name.Equals($label, [StringComparison]::OrdinalIgnoreCase) -or
        $name.IndexOf($label, [StringComparison]::OrdinalIgnoreCase) -ge 0) { return $true }
  }
  return $false
}
function Invoke-Element($element) {
  try { ($element.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)).Invoke(); return $true } catch {}
  try { ($element.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)).Select(); return $true } catch {}
  try {
    $r = $element.Current.BoundingRectangle
    [StarlyCodexSettingsUi]::SetCursorPos([int]($r.X+$r.Width/2),[int]($r.Y+$r.Height/2)) | Out-Null
    [StarlyCodexSettingsUi]::mouse_event(2,0,0,0,[UIntPtr]::Zero)
    [StarlyCodexSettingsUi]::mouse_event(4,0,0,0,[UIntPtr]::Zero)
    return $true
  } catch { return $false }
}
function Descendants($root) {
  return @($root.FindAll([System.Windows.Automation.TreeScope]::Descendants,
    [System.Windows.Automation.Condition]::TrueCondition))
}
function Select-Value($root, [string[]]$triggers, [string[]]$options, [string]$kind) {
  if ($options.Count -eq 0) { return }
  $all = Descendants $root
  foreach ($element in $all) {
    try {
      $type = $element.Current.ControlType
      if (($type -eq [System.Windows.Automation.ControlType]::Button -or
           $type -eq [System.Windows.Automation.ControlType]::MenuItem -or
           $type -eq [System.Windows.Automation.ControlType]::ListItem) -and
          (Matches $element.Current.Name $options)) { return }
    } catch {}
  }
  $trigger = $null
  foreach ($element in $all) {
    try {
      if ($element.Current.ControlType -eq [System.Windows.Automation.ControlType]::Button -and
          (Matches $element.Current.Name $triggers)) { $trigger = $element; break }
    } catch {}
  }
  if ($null -eq $trigger -or -not (Invoke-Element $trigger)) { throw "trigger:$kind" }
  Start-Sleep -Milliseconds 220
  foreach ($element in (Descendants $root)) {
    try { if (Matches $element.Current.Name $options) { if (Invoke-Element $element) { Start-Sleep -Milliseconds 180; return } } } catch {}
  }
  throw "option:$kind"
}
$process = @(Get-Process ChatGPT -ErrorAction SilentlyContinue | Where-Object {
  try { $_.Path -like '*OpenAI.Codex_*' -and $_.MainWindowHandle -ne 0 } catch { $false }
} | Sort-Object { $_.MainWindowHandle } | Select-Object -First 1)
if ($process.Count -eq 0) { Write-Output 'SETTING_FAILED|window'; exit 3 }
$handle = [IntPtr]$process[0].MainWindowHandle
[StarlyCodexSettingsUi]::ShowWindow($handle,9) | Out-Null
[StarlyCodexSettingsUi]::SetForegroundWindow($handle) | Out-Null
Start-Sleep -Milliseconds 250
$deadline = [DateTime]::UtcNow.AddSeconds(12)
$lastError = 'task-not-ready'
while ([DateTime]::UtcNow -lt $deadline) {
  try {
    $root = [System.Windows.Automation.AutomationElement]::FromHandle($handle)
    Select-Value $root @('Open model picker','Model','模型') (Split-Labels $env:STARLY_MODEL_LABELS) 'model'
    Select-Value $root @('Reasoning effort','Effort','推理强度') (Split-Labels $env:STARLY_EFFORT_LABELS) 'effort'
    Select-Value $root @('Speed','Service tier','速度') (Split-Labels $env:STARLY_SPEED_LABELS) 'speed'
    Select-Value $root @('Default permissions','Auto-review','Read only','Full access','Permissions','权限') (Split-Labels $env:STARLY_PERMISSION_LABELS) 'permission'
    Write-Output 'CONFIGURED'; exit 0
  } catch { $lastError = $_.Exception.Message; Start-Sleep -Milliseconds 350 }
}
Write-Output ('SETTING_FAILED|' + $lastError); exit 4
"""


def configure_codex_composer(model: str, effort: str, permission_mode: str,
                             service_tier: str) -> tuple[bool, str]:
    environment = os.environ.copy()
    environment["STARLY_MODEL_LABELS"] = "\x1f".join(desktop_model_labels(model))
    environment["STARLY_EFFORT_LABELS"] = "\x1f".join(desktop_effort_labels(effort))
    environment["STARLY_SPEED_LABELS"] = "\x1f".join(desktop_speed_labels(service_tier))
    environment["STARLY_PERMISSION_LABELS"] = "\x1f".join(
        desktop_permission_labels(permission_mode))
    flags = 0x08000000 if os.name == "nt" else 0
    try:
        result = subprocess.run(
            ["powershell.exe", "-NoProfile", "-NonInteractive", "-Command",
             CODEX_COMPOSER_SETTINGS_SCRIPT], capture_output=True, text=True,
            encoding="utf-8", errors="replace", timeout=18,
            creationflags=flags, env=environment, check=False)
    except (OSError, subprocess.SubprocessError) as error:
        return False, f"无法设置 Codex 桌面输入框：{error}"
    output = result.stdout.strip()
    if result.returncode == 0 and output.endswith("CONFIGURED"):
        return True, output
    detail = output or result.stderr.strip() or f"退出码 {result.returncode}"
    return False, f"Codex 桌面选项定位失败：{detail}"


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


def is_workstation_locked() -> bool:
    """Return whether Windows is currently showing its secure lock desktop."""
    if os.name != "nt":
        return False
    user32 = ctypes.WinDLL("user32", use_last_error=True)
    user32.OpenInputDesktop.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
    user32.OpenInputDesktop.restype = wintypes.HANDLE
    user32.SwitchDesktop.argtypes = [wintypes.HANDLE]
    user32.SwitchDesktop.restype = wintypes.BOOL
    user32.CloseDesktop.argtypes = [wintypes.HANDLE]
    user32.CloseDesktop.restype = wintypes.BOOL
    desktop = user32.OpenInputDesktop(0, False, 0x0100)  # DESKTOP_SWITCHDESKTOP
    if not desktop:
        return True
    try:
        return not bool(user32.SwitchDesktop(desktop))
    finally:
        user32.CloseDesktop(desktop)


class BridgeConfig:
    def __init__(self, port: int = DEFAULT_PORT, token: str = "",
                 pairing_code: str = "", gateway_url: str = "",
                 gateway_pairing_id: str = "", gateway_last_seq: int = 0,
                 gateway_send_counter: int = 0,
                 gateway_received_counters: dict[str, int] | None = None,
                 gateway_private_key: str = "", gateway_public_key: str = "",
                 gateway_session_token: str = "", gateway_token: str = "",
                 gateway_device_credential: str = "",
                 gateway_device_id: str = "") -> None:
        self.port = port
        self.token = token or secrets.token_urlsafe(32)
        self.pairing_code = pairing_code if self._is_valid_pairing_code(pairing_code) else self.new_pairing_code()
        self.gateway_url = gateway_url.strip()
        self.gateway_pairing_id = gateway_pairing_id.strip() or secrets.token_hex(16)
        self.gateway_last_seq = max(0, gateway_last_seq)
        self.gateway_send_counter = max(0, gateway_send_counter)
        self.gateway_received_counters = dict(gateway_received_counters or {})
        if not gateway_private_key or not gateway_public_key:
            gateway_private_key, gateway_public_key = generate_device_identity()
        self.gateway_private_key = gateway_private_key
        self.gateway_public_key = gateway_public_key
        self.gateway_session_token = gateway_session_token
        self.gateway_token = gateway_token or self.token
        self.gateway_device_credential = gateway_device_credential
        self.gateway_device_id = (gateway_device_id.strip() or
                                  f"bridge-{secrets.token_hex(12)}")

    @property
    def gateway_enabled(self) -> bool:
        return self.gateway_url.startswith("wss://") or self.gateway_url.startswith("ws://127.0.0.1")

    @staticmethod
    def _is_valid_pairing_code(value: str) -> bool:
        return len(value) == 6 and value.isascii() and value.isdigit()

    @staticmethod
    def new_pairing_code() -> str:
        return f"{secrets.randbelow(1_000_000):06d}"

    def rotate_pairing_code(self) -> None:
        previous = self.pairing_code
        while self.pairing_code == previous:
            self.pairing_code = self.new_pairing_code()

    @classmethod
    def load(cls) -> "BridgeConfig":
        try:
            data = json.loads(CONFIG_PATH.read_text(encoding="utf-8"))
            port = int(data.get("port", DEFAULT_PORT))
            protected_token = str(data.get("token_protected", ""))
            plaintext_token = str(data.get("token", ""))
            token = (unprotect_secret(protected_token) if protected_token else plaintext_token) or \
                secrets.token_urlsafe(32)
            protected_gateway_token = str(data.get("gateway_token_protected", ""))
            plaintext_gateway_token = str(data.get("gateway_token", ""))
            environment_gateway_token = os.environ.get("STARLY_GATEWAY_TOKEN", "").strip()
            gateway_token = environment_gateway_token or (
                unprotect_secret(protected_gateway_token) if protected_gateway_token else
                plaintext_gateway_token or token)
            needs_secret_migration = bool(
                plaintext_token or not protected_token or plaintext_gateway_token or
                environment_gateway_token or
                (gateway_token and not protected_gateway_token))
            pairing_code = str(data.get("pairing_code", ""))
            gateway_url = os.environ.get(
                "STARLY_GATEWAY_URL", str(data.get("gateway_url", ""))).strip()
            gateway_pairing_id = os.environ.get(
                "STARLY_GATEWAY_PAIRING_ID", str(data.get("gateway_pairing_id", ""))).strip()
            gateway_last_seq = int(data.get("gateway_last_seq", 0) or 0)
            gateway_send_counter = int(data.get("gateway_send_counter", 0) or 0)
            raw_received_counters = data.get("gateway_received_counters", {})
            gateway_received_counters = {
                str(key): max(0, int(value))
                for key, value in raw_received_counters.items()
            } if isinstance(raw_received_counters, dict) else {}
            protected_private_key = str(data.get("gateway_private_key_protected", ""))
            gateway_private_key = (unprotect_secret(protected_private_key)
                                   if protected_private_key else "")
            gateway_public_key = str(data.get("gateway_public_key", ""))
            needs_identity_migration = not gateway_private_key or not gateway_public_key
            protected_session_token = str(data.get("gateway_session_token_protected", ""))
            gateway_session_token = (unprotect_secret(protected_session_token)
                                     if protected_session_token else "")
            protected_device_credential = str(
                data.get("gateway_device_credential_protected", ""))
            gateway_device_credential = (unprotect_secret(protected_device_credential)
                                         if protected_device_credential else "")
            gateway_device_id = str(data.get("gateway_device_id", "")).strip()
            # Existing installations were registered under the hostname. Keep
            # that identity when migrating an already-issued device credential.
            if not gateway_device_id and gateway_device_credential:
                gateway_device_id = socket.gethostname()
            needs_device_id_migration = not str(data.get("gateway_device_id", "")).strip()
            if not 1 <= port <= 65535 or len(token) < 32 or len(gateway_token) < 32:
                raise ValueError("invalid config")
            config = cls(port, token, pairing_code, gateway_url,
                         gateway_pairing_id, gateway_last_seq,
                         gateway_send_counter, gateway_received_counters,
                         gateway_private_key, gateway_public_key, gateway_session_token,
                         gateway_token, gateway_device_credential, gateway_device_id)
            if (pairing_code != config.pairing_code or needs_secret_migration or
                    needs_identity_migration or needs_device_id_migration):
                config.save()
            return config
        except (OSError, ValueError, TypeError, json.JSONDecodeError):
            config = cls()
            config.save()
            return config

    def save(self) -> None:
        CONFIG_DIR.mkdir(parents=True, exist_ok=True)
        CONFIG_PATH.write_text(
            json.dumps({
                "port": self.port,
                "token_protected": protect_secret(self.token),
                "gateway_token_protected": protect_secret(self.gateway_token),
                "pairing_code": self.pairing_code,
                "gateway_url": self.gateway_url,
                "gateway_pairing_id": self.gateway_pairing_id,
                "gateway_device_id": self.gateway_device_id,
                "gateway_last_seq": self.gateway_last_seq,
                "gateway_send_counter": self.gateway_send_counter,
                "gateway_received_counters": self.gateway_received_counters,
                "gateway_private_key_protected": protect_secret(self.gateway_private_key),
                "gateway_public_key": self.gateway_public_key,
                "gateway_session_token_protected": (
                    protect_secret(self.gateway_session_token)
                    if self.gateway_session_token else ""),
                "gateway_device_credential_protected": (
                    protect_secret(self.gateway_device_credential)
                    if self.gateway_device_credential else ""),
            }, ensure_ascii=False, indent=2),
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
    VK_V = 0x56
    VK_RETURN = 0x0D
    SCAN_CONTROL = 0x1D
    SCAN_V = 0x2F
    SCAN_RETURN = 0x1C
    CF_DIB = 8
    GMEM_MOVEABLE = 0x0002

    def __init__(self) -> None:
        self.user32 = ctypes.windll.user32
        self.kernel32 = ctypes.windll.kernel32
        # ctypes assumes a 32-bit int return value unless a prototype is set.
        # HGLOBAL and the pointer returned by GlobalLock are 64-bit on this
        # build, so leaving the defaults truncates valid handles.
        self.kernel32.GlobalAlloc.argtypes = [wintypes.UINT, ctypes.c_size_t]
        self.kernel32.GlobalAlloc.restype = wintypes.HGLOBAL
        self.kernel32.GlobalLock.argtypes = [wintypes.HGLOBAL]
        self.kernel32.GlobalLock.restype = ctypes.c_void_p
        self.kernel32.GlobalUnlock.argtypes = [wintypes.HGLOBAL]
        self.kernel32.GlobalUnlock.restype = wintypes.BOOL
        self.kernel32.GlobalFree.argtypes = [wintypes.HGLOBAL]
        self.kernel32.GlobalFree.restype = wintypes.HGLOBAL
        self.user32.SetClipboardData.argtypes = [wintypes.UINT, wintypes.HANDLE]
        self.user32.SetClipboardData.restype = wintypes.HANDLE

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

    def paste_image(self, image_bytes: bytes, text: str,
                    submit_mode: str) -> tuple[bool, str]:
        hwnd, title, process_id = self.foreground_window()
        if hwnd == 0:
            return False, "No active desktop window"
        if process_id == os.getpid():
            return False, "Minimize Starly and focus the Codex composer first"
        try:
            self._set_clipboard_image(image_bytes)
        except (OSError, ValueError, RuntimeError) as error:
            return False, f"Cannot put image on the Windows clipboard: {error}"
        paste_inputs = [
            self._keyboard_input(self.VK_CONTROL, self.SCAN_CONTROL, 0),
            self._keyboard_input(self.VK_V, self.SCAN_V, 0),
            self._keyboard_input(self.VK_V, self.SCAN_V, self.KEYEVENTF_KEYUP),
            self._keyboard_input(self.VK_CONTROL, self.SCAN_CONTROL, self.KEYEVENTF_KEYUP),
        ]
        if not self._send(paste_inputs):
            return False, "Windows rejected the image paste"
        time.sleep(0.45)
        if text:
            encoded = text.encode("utf-16-le")
            units = [int.from_bytes(encoded[index:index + 2], "little")
                     for index in range(0, len(encoded), 2)]
            inputs: list[INPUT] = []
            for unit in units:
                inputs.append(self._keyboard_input(0, unit, self.KEYEVENTF_UNICODE))
                inputs.append(self._keyboard_input(0, unit,
                                                    self.KEYEVENTF_UNICODE | self.KEYEVENTF_KEYUP))
            if not self._send(inputs):
                return False, "Image pasted, but text input was rejected"
            time.sleep(min(1.2, 0.3 + len(units) * 0.006))
        if submit_mode in ("enter", "ctrl_enter") and not self.press_submit(submit_mode)[0]:
            return False, "Image pasted, but submit was rejected"
        action = "image"
        if text:
            action += " and text"
        if submit_mode == "ctrl_enter":
            action += " with Ctrl+Enter"
        elif submit_mode == "enter":
            action += " with Enter"
        return True, f"Sent {action} to {title}"

    def _set_clipboard_image(self, image_bytes: bytes) -> None:
        if not image_bytes or len(image_bytes) > MAX_IMAGE_BYTES:
            raise ValueError(f"图片大小必须不超过 {MAX_IMAGE_BYTES // (1024 * 1024)} MB")
        with Image.open(io.BytesIO(image_bytes)) as source:
            source.load()
            source.thumbnail((4096, 4096), Image.Resampling.LANCZOS)
            bitmap = source.convert("RGB")
        width, height = bitmap.size
        if width <= 0 or height <= 0 or width * height > 25_000_000:
            raise ValueError("图片尺寸过大")
        row_size = (width * 3 + 3) & ~3
        raw = bitmap.tobytes("raw", "BGR")
        pixels = bytearray(row_size * height)
        for row in range(height):
            source_start = row * width * 3
            target_start = (height - row - 1) * row_size
            pixels[target_start:target_start + width * 3] = \
                raw[source_start:source_start + width * 3]
        header = struct.pack("<IiiHHIIiiII", 40, width, height, 1, 24, 0,
                             len(pixels), 0, 0, 0, 0)
        dib = header + pixels
        kernel32 = self.kernel32
        user32 = self.user32
        handle = int(kernel32.GlobalAlloc(self.GMEM_MOVEABLE, len(dib)))
        if handle == 0:
            raise OSError("GlobalAlloc failed")
        locked = int(kernel32.GlobalLock(handle))
        if locked == 0:
            kernel32.GlobalFree(handle)
            raise OSError("GlobalLock failed")
        try:
            ctypes.memmove(locked, dib, len(dib))
        finally:
            kernel32.GlobalUnlock(handle)
        if not user32.OpenClipboard(0):
            kernel32.GlobalFree(handle)
            raise OSError("OpenClipboard failed")
        clipboard_owns_handle = False
        try:
            if not user32.EmptyClipboard():
                raise OSError("EmptyClipboard failed")
            if not user32.SetClipboardData(self.CF_DIB, handle):
                raise OSError("SetClipboardData failed")
            clipboard_owns_handle = True
        finally:
            user32.CloseClipboard()
            if not clipboard_owns_handle:
                kernel32.GlobalFree(handle)

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


class DiscoveryProtocol(asyncio.DatagramProtocol):
    """Small LAN-only bootstrap protocol for discovering and pairing Starly."""

    def __init__(self, server: "BridgeServer") -> None:
        self.server = server
        self.transport: asyncio.DatagramTransport | None = None
        self.failed_attempts: dict[str, list[float]] = {}
        self.successful_pairings: dict[tuple[str, str], tuple[float, dict[str, object]]] = {}

    def connection_made(self, transport: asyncio.BaseTransport) -> None:
        self.transport = transport  # type: ignore[assignment]

    def datagram_received(self, data: bytes, addr: tuple[str, int]) -> None:
        remote_ip = str(addr[0])
        if not self.server._is_allowed_address(remote_ip) or len(data) > 4096:
            return
        try:
            message = json.loads(data.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            return
        if not isinstance(message, dict) or message.get("version") != DISCOVERY_PROTOCOL_VERSION:
            return
        message_type = str(message.get("type", ""))
        nonce = str(message.get("nonce", ""))[:64]
        if not nonce:
            return
        if message_type == "starly_discover":
            self._send({
                "type": "starly_offer",
                "version": DISCOVERY_PROTOCOL_VERSION,
                "nonce": nonce,
                "computer": socket.gethostname(),
                "deviceId": self.server.config.gateway_device_id,
                "host": get_lan_ip(),
                "port": self.server.config.port,
                "pairingPort": DEFAULT_DISCOVERY_PORT,
            }, addr)
            return
        if message_type == "starly_pair":
            self._handle_pair(message, nonce, remote_ip, addr)

    def error_received(self, error: Exception) -> None:
        self.server.event_queue.put(("error", f"局域网发现异常：{error}"))

    def _handle_pair(self, message: dict[str, object], nonce: str,
                     remote_ip: str, addr: tuple[str, int]) -> None:
        now = time.monotonic()
        pairing_key = (remote_ip, nonce)
        cached = self.successful_pairings.get(pairing_key)
        if cached is not None and now - cached[0] < 30:
            self._send(cached[1], addr)
            return
        self.successful_pairings = {
            key: value for key, value in self.successful_pairings.items()
            if now - value[0] < 30
        }
        failures = [attempt for attempt in self.failed_attempts.get(remote_ip, [])
                    if now - attempt < PAIRING_FAILURE_WINDOW_SECONDS]
        self.failed_attempts[remote_ip] = failures
        if len(failures) >= PAIRING_FAILURE_LIMIT:
            self._send_pairing_error(nonce, "尝试次数过多，请一分钟后再试", addr)
            return
        supplied_code = str(message.get("code", ""))
        if not hmac.compare_digest(supplied_code, self.server.config.pairing_code):
            failures.append(now)
            self._send_pairing_error(nonce, "配对码不正确", addr)
            self.server.event_queue.put(("error", f"拒绝了来自 {remote_ip} 的错误六位配对码"))
            return

        self.failed_attempts.pop(remote_ip, None)
        response: dict[str, object] = {
            "type": "starly_paired",
            "version": DISCOVERY_PROTOCOL_VERSION,
            "nonce": nonce,
            "computer": socket.gethostname(),
            "deviceId": self.server.config.gateway_device_id,
            "host": get_lan_ip(),
            "port": self.server.config.port,
            "token": self.server.config.token,
        }
        self.successful_pairings[pairing_key] = (now, response)
        self._send(response, addr)
        self.server.config.rotate_pairing_code()
        self.server.config.save()
        self.server.event_queue.put(("pairing_code_changed", self.server.config.pairing_code))
        self.server.event_queue.put(("paired_bootstrap", f"手机已通过六位码配对：{remote_ip}"))

    def _send_pairing_error(self, nonce: str, message: str,
                            addr: tuple[str, int]) -> None:
        self._send({
            "type": "starly_pair_error",
            "version": DISCOVERY_PROTOCOL_VERSION,
            "nonce": nonce,
            "message": message,
        }, addr)

    def _send(self, message: dict[str, object], addr: tuple[str, int]) -> None:
        if self.transport is None:
            return
        payload = json.dumps(message, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        self.transport.sendto(payload, addr)


class BridgeServer:
    def __init__(self, config: BridgeConfig, event_queue: queue.Queue[tuple[str, str]]) -> None:
        self.config = config
        self.event_queue = event_queue
        self.input = WindowsInput()
        self.thread: threading.Thread | None = None
        self.loop: asyncio.AbstractEventLoop | None = None
        self.stop_event: asyncio.Event | None = None
        self.connections: set[object] = set()
        self.codex: CodexAppServerClient | None = None
        self.codex_refresh_task: asyncio.Task[None] | None = None
        self.codex_snapshot_lock: asyncio.Lock | None = None
        self.codex_snapshot_cache: dict[bool, tuple[float, dict[str, object]]] = {}
        self.pending_desktop_open: set[str] = set()
        self.codex_poll_tasks: dict[str, asyncio.Task[None]] = {}
        self.rollout_observer: object | None = None
        self.rollout_debounce: dict[str, asyncio.TimerHandle] = {}
        self.rollout_states: dict[str, dict[str, object]] = {}
        self.discovery_transport: asyncio.DatagramTransport | None = None
        self.gateway_client: GatewayBridgeClient | None = None
        self.gateway_task: asyncio.Task[None] | None = None
        self.gateway_connections: dict[str, GatewayRelayConnection] = {}
        self.codex_queue = CodexQueueStore(CONFIG_DIR / "codex_queue.json")
        self.codex_queue_tasks: dict[str, asyncio.Task[None]] = {}
        self.codex_queue_wake_events: dict[str, asyncio.Event] = {}
        self.codex_queue_terminal_events: dict[str, asyncio.Event] = {}
        self.codex_queue_terminal_results: dict[str, str] = {}

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
        self._start_codex_queue_workers()
        self._start_rollout_observer()
        if self.config.gateway_enabled:
            gateway_crypto = GatewayCrypto(
                self.config.gateway_token,
                self.config.gateway_pairing_id,
                self.config.gateway_device_id,
                self.config.gateway_send_counter,
                self.config.gateway_received_counters,
                self._handle_gateway_send_counter,
                self._handle_gateway_receive_counter,
                self.config.gateway_private_key,
            )
            self.gateway_client = GatewayBridgeClient(
                self.config.gateway_url,
                self.config.gateway_pairing_id,
                self.config.gateway_device_id,
                self.config.gateway_token,
                self._handle_gateway_payload,
                self._handle_gateway_state,
                self.config.gateway_last_seq,
                self._handle_gateway_sequence,
                gateway_crypto,
                self.config.gateway_public_key,
                self.config.gateway_session_token,
                self._handle_gateway_session,
                self.config.gateway_device_credential,
                self._handle_gateway_credential,
                self._handle_gateway_control,
            )
            self.gateway_task = asyncio.create_task(self.gateway_client.run())
        discovery_ready = False
        try:
            transport, _protocol = await self.loop.create_datagram_endpoint(
                lambda: DiscoveryProtocol(self),
                local_addr=("0.0.0.0", DEFAULT_DISCOVERY_PORT),
                allow_broadcast=True,
            )
            self.discovery_transport = transport  # type: ignore[assignment]
            discovery_ready = True
        except OSError as error:
            self.event_queue.put(("error", f"自动发现端口 {DEFAULT_DISCOVERY_PORT} 启动失败：{error}"))
        try:
            async with websockets.serve(
                self._handle_client,
                "0.0.0.0",
                self.config.port,
                max_size=MAX_WIRE_MESSAGE_SIZE,
                ping_interval=20,
                ping_timeout=20,
            ):
                discovery_text = f"，自动发现端口 {DEFAULT_DISCOVERY_PORT}" if discovery_ready else ""
                self.event_queue.put(("server", f"正在监听端口 {self.config.port}{discovery_text}"))
                await self.stop_event.wait()
        finally:
            for task in self.codex_queue_tasks.values():
                task.cancel()
            await asyncio.gather(*self.codex_queue_tasks.values(), return_exceptions=True)
            self.codex_queue_tasks.clear()
            self._stop_rollout_observer()
            for handle in self.rollout_debounce.values():
                handle.cancel()
            self.rollout_debounce.clear()
            if self.gateway_client:
                await self.gateway_client.stop()
            if self.gateway_task:
                self.gateway_task.cancel()
                await asyncio.gather(self.gateway_task, return_exceptions=True)
            for gateway_connection in self.gateway_connections.values():
                self.connections.discard(gateway_connection)
            self.gateway_connections.clear()
            if self.discovery_transport is not None:
                self.discovery_transport.close()
                self.discovery_transport = None
            if self.codex:
                await self.codex.stop()

    def _start_rollout_observer(self) -> None:
        if Observer is None or self.loop is None:
            self.event_queue.put(("server", "Codex 实时监听不可用，将使用轮询兜底"))
            return
        codex_home = Path(os.environ.get("CODEX_HOME", Path.home() / ".codex"))
        observer = Observer()
        handler = RolloutEventHandler(self._handle_rollout_path_change)
        watched = 0
        for folder_name in ("sessions", "archived_sessions"):
            folder = codex_home / folder_name
            if folder.is_dir():
                observer.schedule(handler, str(folder), recursive=True)
                watched += 1
        if watched == 0:
            self.event_queue.put(("server", "尚未发现 Codex 会话目录，将使用轮询兜底"))
            return
        observer.start()
        self.rollout_observer = observer
        self.event_queue.put(("server", "Codex 任务实时监听已启动"))

    def _stop_rollout_observer(self) -> None:
        observer = self.rollout_observer
        self.rollout_observer = None
        if observer is None:
            return
        try:
            observer.stop()  # type: ignore[attr-defined]
            observer.join(timeout=2)  # type: ignore[attr-defined]
        except Exception:
            pass

    def _handle_rollout_path_change(self, path_value: str) -> None:
        match = ROLLOUT_THREAD_PATTERN.search(Path(path_value).name)
        loop = self.loop
        if match is None or loop is None or loop.is_closed():
            return
        thread_id = match.group(1)
        loop.call_soon_threadsafe(self._debounce_rollout_push, thread_id)

    def _debounce_rollout_push(self, thread_id: str) -> None:
        previous = self.rollout_debounce.pop(thread_id, None)
        if previous is not None:
            previous.cancel()
        loop = asyncio.get_running_loop()
        self.rollout_debounce[thread_id] = loop.call_later(
            0.22, lambda: asyncio.create_task(self._publish_rollout_change(thread_id)))

    async def _publish_rollout_change(self, thread_id: str) -> None:
        self.rollout_debounce.pop(thread_id, None)
        if self.codex is None:
            return
        try:
            detail = await asyncio.to_thread(
                read_rollout_thread_detail, thread_id,
                self.codex.thread_metadata.get(thread_id))
        except (OSError, UnicodeError):
            return
        if detail is None:
            return
        previous = self.rollout_states.get(thread_id, {})
        previous_messages = previous.get("messages")
        known_messages = previous_messages if isinstance(previous_messages, dict) else {}
        previous_activities = previous.get("activities")
        known_activities = previous_activities if isinstance(previous_activities, dict) else {}
        current_messages = self._message_signatures(detail)
        current_activities = self._activity_signatures(detail)
        messages = detail.get("messages")
        changed_messages = [message for message in messages
                            if isinstance(message, dict) and
                            known_messages.get(self._message_id(message)) !=
                            self._message_signature(message)] \
            if isinstance(messages, list) else []
        activities = detail.get("activities")
        changed_activities = [activity for activity in activities
                              if isinstance(activity, dict) and
                              known_activities.get(str(activity.get("id", ""))) !=
                              self._activity_signature(activity)] \
            if isinstance(activities, list) else []
        status = str(detail.get("status", "idle"))
        rollout_event = str(detail.get("rolloutEvent", ""))
        active_turn_id = str(detail.get("activeTurnId", ""))
        updated_at = int(detail.get("updatedAt", 0) or 0)
        previous_event = str(previous.get("rolloutEvent", ""))
        previous_status = str(previous.get("status", ""))
        self.rollout_states[thread_id] = {
            "messages": current_messages,
            "activities": current_activities,
            "status": status,
            "rolloutEvent": rollout_event,
            "activeTurnId": active_turn_id,
            "updatedAt": updated_at,
        }
        self.codex.thread_status[thread_id] = status
        metadata = self.codex.thread_metadata.setdefault(thread_id, {})
        metadata.update({
            "id": thread_id,
            "name": str(detail.get("title", "")),
            "title": str(detail.get("title", "")),
            "preview": str(detail.get("preview", "")),
            "cwd": str(detail.get("cwd", "")),
            "updatedAt": updated_at,
            "archived": bool(detail.get("archived", False)),
            "status": status,
        })
        delta = dict(self._phone_thread_detail(detail))
        delta["messages"] = changed_messages
        delta["activities"] = changed_activities
        delta["updateMode"] = "delta"
        await self._broadcast({"type": "codex_thread", "thread": delta})

        phone_event = ""
        if rollout_event != previous_event:
            if rollout_event == "task_started":
                phone_event = "turn/started"
            elif rollout_event in ("task_complete", "turn_aborted"):
                phone_event = "turn/completed"
        elif previous_status and status != previous_status:
            phone_event = "turn/started" if status == "active" else "turn/completed"
        if phone_event:
            if phone_event == "turn/completed":
                self._signal_codex_queue_terminal(
                    thread_id, "failed" if status == "systemError" else "completed")
            await self._broadcast({
                "type": "codex_event", "event": phone_event,
                "params": {"threadId": thread_id, "updatedAt": updated_at},
            })
            if phone_event == "turn/completed" and thread_id in self.pending_desktop_open:
                self.pending_desktop_open.discard(thread_id)
                asyncio.create_task(self._open_completed_codex_thread(thread_id))
            elif phone_event == "turn/completed":
                await self._schedule_codex_refresh()

    async def _handle_gateway_payload(self, payload: dict[str, object],
                                      source_device_id: str) -> None:
        if self.gateway_client is None or not source_device_id:
            return
        gateway_connection = self.gateway_connections.get(source_device_id)
        if gateway_connection is None:
            self.event_queue.put(("gateway_phone_seen", source_device_id))
            gateway_connection = GatewayRelayConnection(
                self.gateway_client, source_device_id)
            self.gateway_connections[source_device_id] = gateway_connection
            self.connections.add(gateway_connection)
            await self._send_codex_queue_snapshot(gateway_connection)
        await self._handle_message(
            gateway_connection,
            json.dumps(payload, ensure_ascii=False, separators=(",", ":")),
        )

    def _handle_gateway_state(self, connected: bool, message: str) -> None:
        self.event_queue.put(("gateway_connected" if connected else "gateway_disconnected", message))

    def _handle_gateway_sequence(self, seq: int) -> None:
        self.config.gateway_last_seq = max(self.config.gateway_last_seq, seq)
        self.config.save()

    def _handle_gateway_send_counter(self, counter: int) -> None:
        self.config.gateway_send_counter = max(self.config.gateway_send_counter, counter)
        self.config.save()

    def _handle_gateway_receive_counter(self, device_id: str, counter: int) -> None:
        self.config.gateway_received_counters[device_id] = max(
            self.config.gateway_received_counters.get(device_id, 0), counter)
        self.config.save()

    def _handle_gateway_session(self, session_token: str) -> None:
        self.config.gateway_session_token = session_token
        self.config.save()

    def _handle_gateway_credential(self, credential: str) -> None:
        self.config.gateway_device_credential = credential
        self.config.save()

    async def _handle_gateway_control(self, message: dict[str, object]) -> None:
        message_type = str(message.get("type", ""))
        if message_type in ("gateway_pairing_created", "gateway_pairing_request",
                            "gateway_pairing_approved"):
            self.event_queue.put((message_type, json.dumps(
                message, ensure_ascii=False, separators=(",", ":"))))
        elif message_type == "gateway_peer_snapshot":
            self.event_queue.put(("gateway_phone_snapshot", json.dumps(
                message, ensure_ascii=False, separators=(",", ":"))))
        elif message_type == "gateway_presence" and message.get("role") == "phone":
            self.event_queue.put(("gateway_phone_presence", json.dumps(
                message, ensure_ascii=False, separators=(",", ":"))))

    def create_public_pairing(self) -> None:
        if not self.loop or not self.gateway_client:
            self.event_queue.put(("error", "公网 Gateway 未连接"))
            return
        asyncio.run_coroutine_threadsafe(self.gateway_client.send_control({
            "type": "gateway_pairing_create",
        }), self.loop)

    def decide_public_pairing(self, request_id: str, approved: bool) -> None:
        if not self.loop or not self.gateway_client:
            return
        asyncio.run_coroutine_threadsafe(self.gateway_client.send_control({
            "type": "gateway_pairing_decision",
            "requestId": request_id,
            "approved": approved,
        }), self.loop)

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
        supplied_device_id = str(query.get("deviceId", [""])[0]).strip()
        lan_device_id = (supplied_device_id if re.fullmatch(
            r"phone-[A-Za-z0-9._-]{8,120}", supplied_device_id) else peer_label)
        self.event_queue.put(("client_connected", lan_device_id))
        self.connections.add(connection)
        await self._send_json(connection, {
            "type": "hello",
            "computer": socket.gethostname(),
            "version": "2.0.0",
        })
        await self._send_codex_snapshot(connection)
        await self._send_codex_queue_snapshot(connection)
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
            self.event_queue.put(("client_disconnected", lan_device_id))

    async def _handle_message(self, connection: object, raw: str | bytes) -> None:
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
            await self._send_codex_snapshot(
                connection, bool(message.get("includeArchived", False)))
            return
        elif message_type == "codex_queue_snapshot_request":
            await self._send_codex_queue_snapshot(connection, message_id)
            return
        elif message_type == "codex_queue_cancel":
            queue_id = str(message.get("queueId", "")).strip()
            if not queue_id:
                await self._send_error(connection, "缺少排队任务编号", message_id)
                return
            await self._cancel_codex_queue_item(connection, queue_id, message_id)
            return
        elif message_type == "codex_thread_request":
            thread_id = str(message.get("threadId", ""))
            before_message_id = str(message.get("beforeMessageId", ""))
            try:
                limit = max(1, min(int(message.get("limit", MAX_PHONE_DETAIL_MESSAGES)),
                                   MAX_PHONE_DETAIL_MESSAGES))
            except (TypeError, ValueError):
                limit = MAX_PHONE_DETAIL_MESSAGES
            if not thread_id:
                await self._send_error(connection, "缺少 Codex 任务编号", message_id)
                return
            await self._send_codex_thread(
                connection, thread_id, message_id, before_message_id, limit)
            return
        elif message_type == "codex_image_send":
            thread_id = str(message.get("threadId", ""))
            text = str(message.get("text", "")).strip()
            submit_mode = str(message.get("submitMode", "enter"))
            image_data_url = str(message.get("imageData", ""))
            try:
                self._decode_image_data(image_data_url)
            except ValueError as error:
                await self._send_error(connection, str(error), message_id)
                return
            if (not thread_id or len(text) > MAX_TEXT_LENGTH or
                    submit_mode not in ("enter", "ctrl_enter")):
                await self._send_error(connection, "Codex 浠诲姟鎴栨秷鎭唴瀹规棤鏁?", message_id)
                return
            await self._codex_image_send(connection, thread_id, text, submit_mode,
                                         image_data_url, message_id,
                                         str(message.get("model", "")),
                                         str(message.get("effort", "")),
                                         str(message.get("permissionMode", "default")),
                                         str(message.get("serviceTier", "")),
                                         str(message.get("deliveryMode", "background")))
            return
        elif message_type == "codex_send":
            thread_id = str(message.get("threadId", ""))
            text = str(message.get("text", "")).strip()
            submit_mode = str(message.get("submitMode", "enter"))
            if (not thread_id or not text or len(text) > MAX_TEXT_LENGTH or
                    submit_mode not in ("enter", "ctrl_enter")):
                await self._send_error(connection, "Codex 任务或消息内容无效", message_id)
                return
            await self._codex_send(connection, thread_id, text, submit_mode, message_id,
                                   str(message.get("model", "")),
                                   str(message.get("effort", "")),
                                   str(message.get("permissionMode", "default")),
                                   str(message.get("serviceTier", "")),
                                   str(message.get("deliveryMode", "background")))
            return
        elif message_type == "codex_create":
            cwd = str(message.get("cwd", "")).strip()
            text = str(message.get("text", "")).strip()
            model = str(message.get("model", "")).strip()
            effort = str(message.get("effort", "")).strip()
            permission_mode = str(message.get("permissionMode", "default")).strip()
            service_tier = str(message.get("serviceTier", "")).strip()
            delivery_mode = str(message.get("deliveryMode", "background")).strip()
            image_data_url = str(message.get("imageData", "")).strip()
            if delivery_mode == "desktop":
                await self._send_error(
                    connection,
                    "桌面输入框模式暂不支持新建任务，请先在电脑端新建，或切换为默认模式",
                    message_id)
                return
            if not cwd or not text or len(text) > MAX_TEXT_LENGTH:
                await self._send_error(connection, "新任务的工作区或内容无效", message_id)
                return
            try:
                if image_data_url:
                    self._decode_image_data(image_data_url)
                resolved_cwd = Path(cwd).expanduser().resolve(strict=True)
                if not resolved_cwd.is_dir():
                    raise ValueError("工作区不是目录")
                assert self.codex is not None
                known_roots = {
                    Path(str(meta.get("cwd", ""))).resolve()
                    for meta in self.codex.thread_metadata.values()
                    if str(meta.get("cwd", "")).strip()
                }
                configured = os.environ.get("STARLY_WORKSPACE_ROOTS", "")
                for root in configured.split(os.pathsep):
                    if root.strip():
                        known_roots.add(Path(root).expanduser().resolve())
                if not any(resolved_cwd == root or root in resolved_cwd.parents
                           for root in known_roots):
                    raise ValueError(
                        "工作区未授权；请先在 Codex 中打开，或加入 STARLY_WORKSPACE_ROOTS")
                created = await self.codex.create_thread(
                    str(resolved_cwd), text, model, effort, permission_mode, service_tier,
                    image_data_url)
                await self._send_json(connection, {
                    "type": "codex_created", "id": message_id, **created,
                    "operation": "codex_create",
                })
                await self._schedule_codex_refresh()
            except Exception as error:
                await self._send_error(connection, f"新建 Codex 任务失败：{error}", message_id)
            return
        elif message_type == "codex_interrupt":
            thread_id = str(message.get("threadId", ""))
            turn_id = str(message.get("turnId", ""))
            if not thread_id or not turn_id:
                await self._send_error(connection, "当前任务没有可停止的运行轮次", message_id)
                return
            await self._codex_interrupt(connection, thread_id, turn_id, message_id)
            return
        elif message_type == "codex_approval_decision":
            approval_id = str(message.get("approvalId", ""))
            decision = str(message.get("decision", ""))
            permissions = message.get("permissions")
            if (not approval_id or decision not in
                    ("accept", "acceptForSession", "decline", "cancel") or
                    (permissions is not None and not isinstance(permissions, dict))):
                await self._send_error(connection, "审批决定参数无效", message_id)
                return
            try:
                assert self.codex is not None
                await self.codex.resolve_approval(
                    approval_id, decision,
                    permissions if isinstance(permissions, dict) else None)
                await self._send_json(connection, {
                    "type": "ack", "id": message_id, "message": "审批决定已提交",
                })
            except Exception as error:
                await self._send_error(connection, f"提交审批决定失败：{error}", message_id)
            return
        elif message_type == "codex_archive":
            thread_id = str(message.get("threadId", ""))
            archived = bool(message.get("archived", True))
            if not thread_id:
                await self._send_error(connection, "缺少 Codex 任务编号", message_id)
                return
            try:
                assert self.codex is not None
                await self.codex.set_archived(thread_id, archived)
                await self._send_json(connection, {
                    "type": "ack", "id": message_id,
                    "message": "任务已归档" if archived else "任务已恢复",
                })
                await self._broadcast({
                    "type": "codex_event",
                    "event": "thread/archived" if archived else "thread/unarchived",
                    "params": {"threadId": thread_id},
                })
            except Exception as error:
                await self._send_error(connection, f"更新任务归档状态失败：{error}", message_id)
            return
        elif message_type == "codex_rename":
            thread_id = str(message.get("threadId", "")).strip()
            name = str(message.get("name", "")).strip()
            if not thread_id:
                await self._send_error(connection, "缺少 Codex 任务编号", message_id)
                return
            if not name or len(name) > 80:
                await self._send_error(connection, "任务名称应为 1 到 80 个字符", message_id)
                return
            try:
                assert self.codex is not None
                await self.codex.rename_thread(thread_id, name)
                await self._send_json(connection, {
                    "type": "ack", "id": message_id, "message": "任务已重命名",
                })
                await self._broadcast({
                    "type": "codex_event",
                    "event": "thread/renamed",
                    "params": {"threadId": thread_id},
                })
            except Exception as error:
                await self._send_error(connection, f"重命名任务失败：{error}", message_id)
            return
        else:
            await self._send_error(connection, "未知操作", message_id)
            return
        self.event_queue.put(("action" if ok else "error", result))
        response_type = "ack" if ok else "error"
        await self._send_json(connection, {
            "type": response_type,
            "id": message_id,
            "operation": str(message_type or ""),
            "message": result,
        })

    @staticmethod
    def _decode_image_data(value: object) -> bytes:
        data = str(value or "").strip()
        if not data.startswith("data:image/") or "," not in data:
            raise ValueError("鍥剧墖鏁版嵁鏍煎紡鏃犳硶璇嗗埆")
        _, encoded = data.split(",", 1)
        if len(encoded) > ((MAX_IMAGE_BYTES + 2) // 3) * 4 + 4:
            raise ValueError("鍥剧墖鏁版嵁瓒呭嚭澶у皬闄愬埗")
        try:
            decoded = base64.b64decode(encoded, validate=True)
        except (binascii.Error, ValueError):
            raise ValueError("鍥剧墖鏁版嵁鏃犳硶瑙ｇ爜") from None
        if not decoded or len(decoded) > MAX_IMAGE_BYTES:
            raise ValueError(f"图片大小必须不超过 {MAX_IMAGE_BYTES // (1024 * 1024)} MB")
        return decoded

    async def _codex_image_send(self, connection: websockets.ServerConnection,
                                thread_id: str, text: str, submit_mode: str,
                                image_data_url: str, message_id: str,
                                model: str = "", effort: str = "",
                                permission_mode: str = "default",
                                service_tier: str = "",
                                delivery_mode: str = "background") -> None:
        try:
            await self._enqueue_codex_message(
                connection, message_id, thread_id, text, image_data_url,
                submit_mode, model, effort, permission_mode, service_tier,
                delivery_mode, "codex_image_send")
        except Exception as error:
            await self._send_error(connection, f"加入 Codex 队列失败：{error}", message_id)

    async def _send_codex_snapshot(self, connection: websockets.ServerConnection,
                                   include_archived: bool = False) -> None:
        assert self.codex is not None
        if self.codex_snapshot_lock is None:
            self.codex_snapshot_lock = asyncio.Lock()
        async with self.codex_snapshot_lock:
            now = time.monotonic()
            cached = self.codex_snapshot_cache.get(include_archived)
            if cached is not None and now - cached[0] <= 3.0:
                snapshot = cached[1]
            else:
                snapshot = await self.codex.snapshot(include_archived)
                self.codex_snapshot_cache[include_archived] = (time.monotonic(), snapshot)
        await self._send_json(connection, {"type": "codex_snapshot", **snapshot})

    async def _send_codex_thread(self, connection: websockets.ServerConnection,
                                 thread_id: str, message_id: str = "",
                                 before_message_id: str = "",
                                 limit: int = MAX_PHONE_DETAIL_MESSAGES) -> None:
        assert self.codex is not None
        try:
            # Reading history must stay read-only. Resuming here leaves a second
            # app-server owning the same thread and makes the desktop view stale.
            detail = await self.codex.thread_detail(thread_id, before_message_id, limit)
            await self._send_json(connection, {
                "type": "codex_thread", "id": message_id,
                "thread": self._phone_thread_detail(detail),
            })
        except Exception as error:
            await self._send_error(connection, f"读取 Codex 任务失败：{error}", message_id)

    async def _codex_send(self, connection: websockets.ServerConnection, thread_id: str,
                          text: str, submit_mode: str, message_id: str,
                          model: str = "", effort: str = "",
                          permission_mode: str = "default",
                          service_tier: str = "",
                          delivery_mode: str = "background") -> None:
        try:
            await self._enqueue_codex_message(
                connection, message_id, thread_id, text, "", submit_mode,
                model, effort, permission_mode, service_tier, delivery_mode,
                "codex_send")
        except Exception as error:
            await self._send_error(connection, f"加入 Codex 队列失败：{error}", message_id)

    def _ensure_codex_queue_runtime(self) -> None:
        if not hasattr(self, "codex_queue"):
            self.codex_queue = CodexQueueStore(CONFIG_DIR / "codex_queue.json")
        if not hasattr(self, "codex_queue_tasks"):
            self.codex_queue_tasks = {}
        if not hasattr(self, "codex_queue_wake_events"):
            self.codex_queue_wake_events = {}
        if not hasattr(self, "codex_queue_terminal_events"):
            self.codex_queue_terminal_events = {}
        if not hasattr(self, "codex_queue_terminal_results"):
            self.codex_queue_terminal_results = {}

    async def _enqueue_codex_message(
        self,
        connection: object,
        queue_id: str,
        thread_id: str,
        text: str,
        image_data: str,
        submit_mode: str,
        model: str,
        effort: str,
        permission_mode: str,
        service_tier: str,
        delivery_mode: str,
        operation: str,
    ) -> None:
        self._ensure_codex_queue_runtime()
        if not queue_id:
            raise ValueError("缺少消息编号，无法安全去重")
        if delivery_mode not in ("background", "desktop"):
            raise ValueError("未知的发送方式")
        item, created = self.codex_queue.enqueue(CodexQueueItem(
            queue_id=queue_id,
            thread_id=thread_id,
            text=text,
            image_data=image_data,
            submit_mode=submit_mode,
            model=model,
            effort=effort,
            permission_mode=permission_mode,
            service_tier=service_tier,
            delivery_mode=delivery_mode,
        ))
        public_item = self.codex_queue.public_item(item)
        try:
            await self._send_json(connection, {
                "type": "ack",
                "id": queue_id,
                "operation": operation,
                "threadId": thread_id,
                "queueId": queue_id,
                "duplicate": not created,
                "queueItem": public_item,
                "message": "任务已加入执行队列" if created else "已恢复原排队任务",
            })
            if created:
                await self._broadcast_codex_queue_thread("enqueued", item)
        finally:
            # Delivery acknowledgement and execution are independent. A phone
            # can disconnect just after enqueueing without stranding the item.
            if item.state not in TERMINAL_STATES:
                self._start_codex_queue_worker(thread_id)

    async def _send_codex_queue_snapshot(
        self, connection: object, message_id: str = "",
    ) -> None:
        self._ensure_codex_queue_runtime()
        await self._send_json(connection, {
            "type": "codex_queue_snapshot",
            "id": message_id,
            "items": self.codex_queue.snapshot(),
        })

    async def _cancel_codex_queue_item(
        self, connection: object, queue_id: str, message_id: str,
    ) -> None:
        self._ensure_codex_queue_runtime()
        item, canceled = self.codex_queue.cancel(queue_id)
        if item is None:
            await self._send_error(connection, "排队任务不存在", message_id)
            return
        if not canceled:
            message = ("任务正在执行，请使用停止任务功能" if item.state == "running"
                       else "任务已结束，不能再次取消")
            await self._send_error(connection, message, message_id)
            return
        await self._send_json(connection, {
            "type": "ack", "id": message_id,
            "operation": "codex_queue_cancel", "queueId": queue_id,
            "threadId": item.thread_id, "queueItem": self.codex_queue.public_item(item),
            "message": "排队任务已取消",
        })
        await self._broadcast_codex_queue_thread("canceled", item)
        self._wake_codex_queue_worker(item.thread_id)

    def _start_codex_queue_workers(self) -> None:
        self._ensure_codex_queue_runtime()
        for thread_id in self.codex_queue.threads_with_pending():
            self._start_codex_queue_worker(thread_id)

    def _start_codex_queue_worker(self, thread_id: str) -> None:
        self._ensure_codex_queue_runtime()
        current = self.codex_queue_tasks.get(thread_id)
        if current is not None and not current.done():
            self._wake_codex_queue_worker(thread_id)
            return
        self.codex_queue_tasks[thread_id] = asyncio.create_task(
            self._codex_queue_worker(thread_id))

    def _wake_codex_queue_worker(self, thread_id: str) -> None:
        self._ensure_codex_queue_runtime()
        self.codex_queue_wake_events.setdefault(thread_id, asyncio.Event()).set()

    async def _wait_codex_queue_worker(self, thread_id: str, timeout: float = 1.5) -> None:
        event = self.codex_queue_wake_events.setdefault(thread_id, asyncio.Event())
        event.clear()
        try:
            await asyncio.wait_for(event.wait(), timeout=timeout)
        except asyncio.TimeoutError:
            pass

    async def _codex_queue_worker(self, thread_id: str) -> None:
        try:
            while True:
                item = self.codex_queue.next_for_thread(thread_id)
                if item is None:
                    return
                if item.state == "running":
                    await self._recover_running_codex_queue_item(item)
                    continue
                if item.state == "waiting_unlock":
                    await self._wait_codex_queue_worker(thread_id, 2.0)
                    if item.state != "waiting_unlock":
                        continue
                    if await asyncio.to_thread(is_workstation_locked):
                        continue
                    await self._transition_codex_queue_item(item, "queued", "", "queued")

                try:
                    assert self.codex is not None
                    before = await self.codex.thread_detail(thread_id)
                except Exception:
                    await self._wait_codex_queue_worker(thread_id)
                    continue
                if not self._codex_thread_is_idle(before):
                    await self._wait_codex_queue_worker(thread_id)
                    continue
                await self._execute_codex_queue_item(item, before)
        except asyncio.CancelledError:
            raise
        finally:
            current = self.codex_queue_tasks.get(thread_id)
            if current is asyncio.current_task():
                self.codex_queue_tasks.pop(thread_id, None)

    async def _execute_codex_queue_item(
        self, item: CodexQueueItem, before: dict[str, object],
    ) -> None:
        assert self.codex is not None
        terminal_event = self.codex_queue_terminal_events.setdefault(
            item.thread_id, asyncio.Event())
        terminal_event.clear()
        self.codex_queue_terminal_results.pop(item.thread_id, None)
        used_desktop = item.delivery_mode == "desktop"
        if used_desktop and await asyncio.to_thread(is_workstation_locked):
            await self._transition_codex_queue_item(
                item, "waiting_unlock", "电脑已锁屏，等待解锁", "waiting_unlock")
            return
        try:
            if used_desktop:
                sent, result = await self._send_codex_queue_item_to_desktop(item, before)
                if not sent:
                    await self._transition_codex_queue_item(
                        item, "waiting_unlock", result, "waiting_unlock")
                    return
            else:
                try:
                    await self.codex.send_message(
                        item.thread_id, item.text, item.model, item.effort,
                        item.permission_mode, item.image_data, item.service_tier,
                        allow_steer=False)
                except Exception as error:
                    if self._is_queue_active_conflict(error):
                        await self._wait_codex_queue_worker(item.thread_id)
                        return
                    if not self._is_active_writer_conflict(error):
                        raise
                    if await asyncio.to_thread(is_workstation_locked):
                        await self._transition_codex_queue_item(
                            item, "waiting_unlock", "电脑已锁屏，等待解锁",
                            "waiting_unlock")
                        return
                    sent, result = await self._send_codex_queue_item_to_desktop(item, before)
                    if not sent:
                        await self._transition_codex_queue_item(
                            item, "waiting_unlock", result, "waiting_unlock")
                        return
                    used_desktop = True
            await self._transition_codex_queue_item(item, "running", "", "running")
            if used_desktop:
                await self._watch_desktop_submission(item.thread_id, before)
            else:
                await self._schedule_codex_refresh()
            result = await self._await_codex_queue_terminal(item, before)
            await self._transition_codex_queue_item(
                item, result, "Codex 执行失败" if result == "failed" else "", result)
        except asyncio.CancelledError:
            raise
        except Exception as error:
            await self._transition_codex_queue_item(item, "failed", str(error), "failed")

    async def _send_codex_queue_item_to_desktop(
        self, item: CodexQueueItem, before: dict[str, object],
    ) -> tuple[bool, str]:
        thread_title = str(before.get("title", "")).strip()
        if item.image_data:
            image_bytes = self._decode_image_data(item.image_data)
            return await asyncio.to_thread(
                self._send_image_to_codex_desktop, item.thread_id, thread_title,
                item.text, item.submit_mode, image_bytes, item.model, item.effort,
                item.permission_mode, item.service_tier)
        return await asyncio.to_thread(
            self._send_to_codex_desktop, item.thread_id, thread_title, item.text,
            item.submit_mode, item.model, item.effort, item.permission_mode,
            item.service_tier)

    async def _recover_running_codex_queue_item(self, item: CodexQueueItem) -> None:
        assert self.codex is not None
        try:
            detail = await self.codex.thread_detail(item.thread_id)
        except Exception:
            await self._wait_codex_queue_worker(item.thread_id)
            return
        if str(detail.get("status", "")) == "systemError":
            await self._transition_codex_queue_item(
                item, "failed", "Codex 执行失败", "failed")
            return
        if self._codex_thread_is_idle(detail):
            if self._detail_contains_queue_submission(detail, item):
                await self._transition_codex_queue_item(
                    item, "completed", "", "completed")
            else:
                await self._transition_codex_queue_item(item, "queued", "", "queued")
            return
        result = await self._await_codex_queue_terminal(item, detail)
        await self._transition_codex_queue_item(
            item, result, "Codex 执行失败" if result == "failed" else "", result)

    async def _await_codex_queue_terminal(
        self, item: CodexQueueItem, before: dict[str, object],
    ) -> str:
        assert self.codex is not None
        event = self.codex_queue_terminal_events.setdefault(item.thread_id, asyncio.Event())
        baseline = self._latest_message_signature(before)
        saw_active = not self._codex_thread_is_idle(before)
        while item.state == "running":
            try:
                await asyncio.wait_for(event.wait(), timeout=1.5)
            except asyncio.TimeoutError:
                pass
            if event.is_set():
                event.clear()
                result = self.codex_queue_terminal_results.pop(item.thread_id, "completed")
                return "failed" if result == "failed" else "completed"
            try:
                detail = await self.codex.thread_detail(item.thread_id)
            except Exception:
                continue
            status = str(detail.get("status", "idle"))
            if status == "systemError":
                return "failed"
            if not self._codex_thread_is_idle(detail):
                saw_active = True
                continue
            changed = self._latest_message_signature(detail) != baseline
            if saw_active or changed:
                return "completed"
        return "canceled" if item.state == "canceled" else "failed"

    async def _transition_codex_queue_item(
        self, item: CodexQueueItem, state: str, error: str, event: str,
    ) -> None:
        self.codex_queue.transition(item.queue_id, state, error)
        await self._broadcast_codex_queue_thread(event, item)
        self._wake_codex_queue_worker(item.thread_id)

    async def _broadcast_codex_queue_thread(
        self, event: str, primary: CodexQueueItem,
    ) -> None:
        thread_items = [item for item in self.codex_queue.items
                        if item.thread_id == primary.thread_id and
                        (item is primary or item.state not in TERMINAL_STATES)]
        for item in thread_items:
            await self._broadcast({
                "type": "codex_queue_event",
                "event": event if item is primary else "position_changed",
                "item": self.codex_queue.public_item(item),
            })

    def _signal_codex_queue_terminal(self, thread_id: str, result: str) -> None:
        if not thread_id:
            return
        self._ensure_codex_queue_runtime()
        # thread/resume may emit an idle status immediately before turn/start.
        # Treating that stale event as terminal would complete a newly queued
        # item before its turn has actually begun. Polling still reconciles a
        # very fast turn that finishes before we enter the running state.
        active_item = self.codex_queue.next_for_thread(thread_id)
        if active_item is None or active_item.state != "running":
            return
        self.codex_queue_terminal_results[thread_id] = result
        self.codex_queue_terminal_events.setdefault(thread_id, asyncio.Event()).set()
        self._wake_codex_queue_worker(thread_id)

    @staticmethod
    def _codex_thread_is_idle(detail: dict[str, object]) -> bool:
        return (str(detail.get("status", "idle")) not in ("active", "running") and
                not str(detail.get("activeTurnId", "")))

    @staticmethod
    def _detail_contains_queue_submission(
        detail: dict[str, object], item: CodexQueueItem,
    ) -> bool:
        messages = detail.get("messages")
        if not isinstance(messages, list):
            return False
        for message in reversed(messages):
            if not isinstance(message, dict) or str(message.get("role", "")) != "user":
                continue
            timestamp = int(message.get("timestamp", 0) or 0)
            if item.started_at and timestamp and timestamp + 2 < item.started_at:
                continue
            text_matches = not item.text or str(message.get("text", "")).strip() == item.text.strip()
            images = message.get("images")
            image_matches = not item.has_image or (isinstance(images, list) and bool(images))
            if text_matches and image_matches:
                return True
        return False

    @staticmethod
    def _is_queue_active_conflict(error: Exception) -> bool:
        value = str(error).lower()
        return "queue must wait" in value or "active turn" in value

    @staticmethod
    def _is_active_writer_conflict(error: Exception) -> bool:
        error_text = str(error).lower()
        return "active writer" in error_text or "已有活动写入" in error_text

    async def _watch_desktop_submission(self, thread_id: str,
                                        before: dict[str, object]) -> None:
        await self._broadcast({
            "type": "codex_event", "event": "turn/started",
            "params": {"threadId": thread_id},
        })
        previous_poll = self.codex_poll_tasks.get(thread_id)
        if previous_poll and not previous_poll.done():
            previous_poll.cancel()
        if self.rollout_observer is None:
            self.codex_poll_tasks[thread_id] = asyncio.create_task(
                self._poll_desktop_codex_thread(thread_id, before))
        await self._schedule_codex_refresh()

    def _send_to_codex_desktop(self, thread_id: str, thread_title: str,
                               text: str, submit_mode: str, model: str = "",
                               effort: str = "", permission_mode: str = "default",
                               service_tier: str = "") -> tuple[bool, str]:
        if not thread_title:
            return False, "无法确认 Codex 任务标题"
        if not open_codex_thread(thread_id):
            return False, "无法打开电脑端 Codex 任务"
        configured, setting_result = configure_codex_composer(
            model, effort, permission_mode, service_tier)
        if not configured:
            return False, setting_result
        focused, focus_result = focus_codex_composer(thread_title)
        if not focused:
            return False, focus_result
        ok, input_result = self.input.type_text(text, submit_mode)
        if not ok:
            return False, input_result
        return True, f"{focus_result}；{input_result}"

    def _send_image_to_codex_desktop(self, thread_id: str, thread_title: str,
                                     text: str, submit_mode: str,
                                     image_bytes: bytes, model: str = "",
                                     effort: str = "", permission_mode: str = "default",
                                     service_tier: str = "") -> tuple[bool, str]:
        if not thread_title:
            return False, "无法确认 Codex 任务标题"
        if not open_codex_thread(thread_id):
            return False, "无法打开电脑端 Codex 任务"
        configured, setting_result = configure_codex_composer(
            model, effort, permission_mode, service_tier)
        if not configured:
            return False, setting_result
        focused, focus_result = focus_codex_composer(thread_title)
        if not focused:
            return False, focus_result
        ok, input_result = self.input.paste_image(image_bytes, text, submit_mode)
        if not ok:
            return False, input_result
        return True, f"{focus_result}，{input_result}"

    async def _poll_desktop_codex_thread(self, thread_id: str,
                                         baseline_detail: dict[str, object]) -> None:
        assert self.codex is not None
        saw_active_turn = False
        saw_new_message = False
        baseline_message = self._latest_message_signature(baseline_detail)
        known_messages = self._message_signatures(baseline_detail)
        known_activities = self._activity_signatures(baseline_detail)
        last_status = str(baseline_detail.get("status", ""))
        last_active_turn_id = str(baseline_detail.get("activeTurnId", ""))
        consecutive_read_errors = 0
        try:
            # Keep following the desktop-owned turn until it reaches a terminal
            # state. Long Codex tasks can legitimately run for more than five
            # minutes; the task is cancelled when a newer poll replaces it or
            # when StarlyBridge shuts down.
            while True:
                retry_delay = min(10, 2 ** min(consecutive_read_errors, 4))
                await asyncio.sleep(retry_delay)
                try:
                    detail = await self.codex.thread_detail(thread_id)
                except asyncio.CancelledError:
                    raise
                except Exception:
                    # Codex Desktop can briefly rotate or lock its rollout while
                    # persisting a turn. Keep following the same task instead of
                    # abandoning completion detection after one failed read.
                    consecutive_read_errors += 1
                    await self._schedule_codex_refresh()
                    continue
                consecutive_read_errors = 0
                active_turn_id = str(detail.get("activeTurnId", ""))
                status = str(detail.get("status", "idle"))
                latest_message = self._latest_message_signature(detail)
                if active_turn_id:
                    saw_active_turn = True
                changed_messages: list[dict[str, object]] = []
                messages = detail.get("messages")
                if isinstance(messages, list):
                    for message in messages:
                        if not isinstance(message, dict):
                            continue
                        message_id = self._message_id(message)
                        signature = self._message_signature(message)
                        if known_messages.get(message_id) != signature:
                            changed_messages.append(message)
                            known_messages[message_id] = signature
                changed_activities: list[dict[str, object]] = []
                activities = detail.get("activities")
                if isinstance(activities, list):
                    for activity in activities:
                        if not isinstance(activity, dict):
                            continue
                        activity_id = str(activity.get("id", ""))
                        signature = self._activity_signature(activity)
                        if activity_id and known_activities.get(activity_id) != signature:
                            changed_activities.append(activity)
                            known_activities[activity_id] = signature
                if changed_messages or (latest_message and latest_message != baseline_message):
                    saw_new_message = True
                status_changed = status != last_status or active_turn_id != last_active_turn_id
                if changed_messages or changed_activities or status_changed:
                    delta = dict(self._phone_thread_detail(detail))
                    delta["messages"] = changed_messages
                    delta["activities"] = changed_activities
                    delta["updateMode"] = "delta"
                    await self._broadcast({"type": "codex_thread", "thread": delta})
                baseline_message = latest_message or baseline_message
                last_status = status
                last_active_turn_id = active_turn_id
                # Local history is intentionally capped, so its length can stay at 15
                # throughout a whole turn. Detect the active -> idle transition or a
                # changed newest visible message instead of waiting for the list to grow.
                terminal_event = self._terminal_poll_event(
                    status, saw_active_turn or saw_new_message)
                if not active_turn_id and terminal_event:
                    self._signal_codex_queue_terminal(
                        thread_id, "failed" if terminal_event == "turn/failed" else "completed")
                    await self._broadcast({
                        "type": "codex_event", "event": terminal_event,
                        "params": {"threadId": thread_id},
                    })
                    await self._schedule_codex_refresh()
                    return
        except asyncio.CancelledError:
            raise
        finally:
            current = self.codex_poll_tasks.get(thread_id)
            if current is asyncio.current_task():
                self.codex_poll_tasks.pop(thread_id, None)

    @staticmethod
    def _latest_message_signature(detail: dict[str, object]) -> str:
        messages = detail.get("messages")
        if not isinstance(messages, list):
            return ""
        for message in reversed(messages):
            if not isinstance(message, dict):
                continue
            return json.dumps({
                "role": str(message.get("role", "")),
                "text": str(message.get("text", "")),
                "timestamp": int(message.get("timestamp", 0) or 0),
                "turnId": str(message.get("turnId", "")),
                "images": message.get("images") if isinstance(message.get("images"), list) else [],
            }, ensure_ascii=False, sort_keys=True)
        return ""

    @staticmethod
    def _message_id(message: dict[str, object]) -> str:
        message_id = str(message.get("id", ""))
        return message_id or BridgeServer._message_signature(message)

    @staticmethod
    def _message_signature(message: dict[str, object]) -> str:
        return json.dumps({
            "id": str(message.get("id", "")),
            "role": str(message.get("role", "")),
            "text": str(message.get("text", "")),
            "timestamp": int(message.get("timestamp", 0) or 0),
            "turnId": str(message.get("turnId", "")),
            "images": message.get("images") if isinstance(message.get("images"), list) else [],
        }, ensure_ascii=False, sort_keys=True)

    @classmethod
    def _message_signatures(cls, detail: dict[str, object]) -> dict[str, str]:
        result: dict[str, str] = {}
        messages = detail.get("messages")
        if not isinstance(messages, list):
            return result
        for message in messages:
            if isinstance(message, dict):
                result[cls._message_id(message)] = cls._message_signature(message)
        return result

    @staticmethod
    def _activity_signature(activity: dict[str, object]) -> str:
        return json.dumps({
            "id": str(activity.get("id", "")),
            "kind": str(activity.get("kind", "")),
            "title": str(activity.get("title", "")),
            "text": str(activity.get("text", "")),
            "status": str(activity.get("status", "")),
            "timestamp": int(activity.get("timestamp", 0) or 0),
            "turnId": str(activity.get("turnId", "")),
        }, ensure_ascii=False, sort_keys=True)

    @classmethod
    def _activity_signatures(cls, detail: dict[str, object]) -> dict[str, str]:
        result: dict[str, str] = {}
        activities = detail.get("activities")
        if not isinstance(activities, list):
            return result
        for activity in activities:
            if isinstance(activity, dict):
                activity_id = str(activity.get("id", ""))
                if activity_id:
                    result[activity_id] = cls._activity_signature(activity)
        return result

    @staticmethod
    def _terminal_poll_event(status: str, saw_activity: bool) -> str:
        if not saw_activity:
            return ""
        if status == "idle":
            return "turn/completed"
        if status == "systemError":
            return "turn/failed"
        return ""

    @staticmethod
    def _phone_thread_detail(detail: dict[str, object]) -> dict[str, object]:
        """Trim only the phone payload; keep the full detail for bridge logic."""
        messages = detail.get("messages")
        payload = dict(detail)
        payload["goal"] = read_thread_goal(str(payload.get("id", "")))
        payload.setdefault("updateMode", "latest")
        payload.setdefault("hasMoreBefore", False)
        if isinstance(messages, list) and len(messages) > MAX_PHONE_DETAIL_MESSAGES:
            payload["messages"] = messages[-MAX_PHONE_DETAIL_MESSAGES:]
            payload["hasMoreBefore"] = True
        activities = detail.get("activities")
        if isinstance(activities, list) and len(activities) > MAX_PHONE_ACTIVITIES:
            payload["activities"] = activities[-MAX_PHONE_ACTIVITIES:]
        return payload

    async def _codex_interrupt(self, connection: websockets.ServerConnection, thread_id: str,
                               turn_id: str, message_id: str) -> None:
        assert self.codex is not None
        try:
            await self.codex.interrupt(thread_id, turn_id)
            await self._send_json(connection, {
                "type": "ack", "id": message_id, "operation": "codex_interrupt",
                "threadId": thread_id, "message": "已请求停止 Codex 任务",
            })
            await self._schedule_codex_refresh()
        except Exception as error:
            await self._send_error(connection, f"停止 Codex 任务失败：{error}", message_id)

    async def _handle_codex_event(self, method: str, params: dict[str, object]) -> None:
        if method in ("item/commandExecution/requestApproval",
                      "item/fileChange/requestApproval",
                      "item/permissions/requestApproval"):
            await self._broadcast({
                "type": "codex_approval",
                "approval": normalize_approval(method, params),
            })
            return
        if method in ("thread/status/changed", "turn/started", "turn/completed",
                      "account/rateLimits/updated"):
            phone_event = method
            if method == "turn/completed":
                turn = params.get("turn")
                turn_status = str(turn.get("status", "")) if isinstance(turn, dict) else ""
                if turn_status == "failed":
                    phone_event = "turn/failed"
                self._signal_codex_queue_terminal(
                    str(params.get("threadId", "")),
                    "failed" if turn_status == "failed" else "completed")
            elif method == "thread/status/changed":
                status = str(params.get("status", ""))
                if status.lower() in ("idle", "notloaded", "systemerror"):
                    self._signal_codex_queue_terminal(
                        str(params.get("threadId", "")),
                        "failed" if status.lower() == "systemerror" else "completed")
            await self._broadcast({"type": "codex_event", "event": phone_event, "params": params})
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
        connections = getattr(self, "connections", set())
        if not connections:
            return
        raw = json.dumps(message, ensure_ascii=False)
        async def send_one(connection: websockets.ServerConnection) -> None:
            try:
                self._log_wire("电脑→手机", connection, message)
                await asyncio.wait_for(connection.send(raw), timeout=2)
            except (websockets.ConnectionClosed, asyncio.TimeoutError, OSError):
                self.connections.discard(connection)
        await asyncio.gather(*(send_one(connection) for connection in list(connections)))

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
        if key_lower in ("token", "authorization", "pairingtoken",
                          "devicecredential", "secret", "sessiontoken",
                          "text", "imagedata", "objective"):
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


def format_paired_devices(lan_devices: set[str],
                          gateway_devices: dict[str, dict[str, object]]) -> str:
    """Render paired phones without confusing Gateway pairing with LAN sockets."""
    device_ids = set(lan_devices) | set(gateway_devices)
    paired_count = len(device_ids)
    online_count = sum(
        1 for device_id in device_ids
        if device_id in lan_devices or
        bool(gateway_devices.get(device_id, {}).get("online", False)))
    if paired_count == 0:
        return "暂无已配对手机"
    lines = [f"已配对 {paired_count} 部手机 · 在线 {online_count} 部"]
    for device_id in sorted(device_ids):
        device = gateway_devices.get(device_id, {})
        display_name = str(device.get("displayName", "")).strip() or device_id
        states: list[str] = []
        if device_id in lan_devices:
            states.append("局域网在线")
        if device_id in gateway_devices:
            states.append("公网在线" if bool(device.get("online", False))
                          else "公网已配对（离线）")
        lines.append(f"• {display_name} · {' · '.join(states)}")
    return "\n".join(lines)


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
        self.root.geometry("540x860")
        self.root.minsize(500, 720)
        self.root.protocol("WM_DELETE_WINDOW", self.hide_to_tray)
        self.status_var = tk.StringVar(value="正在启动…")
        self.address_var = tk.StringVar()
        self.pairing_code_var = tk.StringVar()
        self.public_pairing_code_var = tk.StringVar(value="点击下方按钮生成")
        self.public_pairing_expiry_var = tk.StringVar(value="一次性配对码有效期 2 分钟")
        self.gateway_config_var = tk.StringVar(value=self._gateway_config_summary())
        self.paired_devices_var = tk.StringVar(value="暂无已配对手机")
        self.connected_devices: set[str] = set()
        self.gateway_devices: dict[str, dict[str, object]] = {}
        self.lan_pairing_collapsed = False
        self.public_pairing_collapsed = False
        self.qr_collapsed = True
        self.log_collapsed = False
        self.log_text: tk.Text
        self.qr_photo: ImageTk.PhotoImage | None = None
        self.public_qr_photo: ImageTk.PhotoImage | None = None
        self.gateway_settings_window: tk.Toplevel | None = None
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
        qr_frame = ttk.LabelFrame(outer, text="局域网自动配对", padding=14)
        qr_frame.pack(fill=tk.X)
        qr_header = ttk.Frame(qr_frame)
        qr_header.pack(fill=tk.X, pady=(0, 8))
        ttk.Label(qr_header, text="手机会自动发现本机，请输入下方 6 位码").pack(side=tk.LEFT)
        self.lan_pairing_toggle_button = ttk.Button(
            qr_header, text="收起", command=self.toggle_lan_pairing, width=8)
        self.lan_pairing_toggle_button.pack(side=tk.RIGHT)
        self.lan_pairing_body = ttk.Frame(qr_frame)
        self.lan_pairing_body.pack(fill=tk.X)
        ttk.Label(
            self.lan_pairing_body,
            textvariable=self.pairing_code_var,
            font=("Consolas", 34, "bold"),
            foreground="#175CD3",
        ).pack(pady=(3, 2))
        ttk.Label(self.lan_pairing_body, textvariable=self.address_var, foreground="#475467").pack()
        ttk.Button(
            self.lan_pairing_body, text="换一个六位配对码",
            command=self.regenerate_pairing_code).pack(pady=(10, 2))
        self.qr_toggle_button = ttk.Button(
            self.lan_pairing_body, text="展开二维码和密钥选项", command=self.toggle_qr)
        self.qr_toggle_button.pack(pady=(6, 0))
        self.qr_body = ttk.Frame(self.lan_pairing_body)
        self.qr_label = ttk.Label(self.qr_body)
        self.qr_label.pack(pady=(10, 8))
        button_row = ttk.Frame(self.qr_body)
        button_row.pack(fill=tk.X, pady=(12, 0))
        ttk.Button(button_row, text="复制配对信息", command=self.copy_pairing).pack(side=tk.LEFT, expand=True, fill=tk.X, padx=(0, 6))
        ttk.Button(button_row, text="更换长期密钥", command=self.regenerate_token).pack(side=tk.LEFT, expand=True, fill=tk.X, padx=(6, 0))
        public_frame = ttk.LabelFrame(outer, text="公网安全配对", padding=12)
        public_frame.pack(fill=tk.X, pady=(10, 0))
        public_header = ttk.Frame(public_frame)
        public_header.pack(fill=tk.X, pady=(0, 7))
        ttk.Label(public_header, text="手机扫码或输入 8 位短码，电脑端确认后才会授权",
                  foreground="#475467").pack(side=tk.LEFT, fill=tk.X, expand=True)
        self.public_pairing_toggle_button = ttk.Button(
            public_header, text="收起", command=self.toggle_public_pairing, width=8)
        self.public_pairing_toggle_button.pack(side=tk.RIGHT, padx=(8, 0))
        self.public_pairing_body = ttk.Frame(public_frame)
        self.public_pairing_body.pack(fill=tk.X)
        gateway_header = ttk.Frame(self.public_pairing_body)
        gateway_header.pack(fill=tk.X, pady=(0, 7))
        ttk.Label(gateway_header, textvariable=self.gateway_config_var,
                  foreground="#175CD3", wraplength=330).pack(side=tk.LEFT, fill=tk.X, expand=True)
        ttk.Button(gateway_header, text="配置服务器",
                   command=self._open_gateway_settings).pack(side=tk.RIGHT, padx=(8, 0))
        public_row = ttk.Frame(self.public_pairing_body)
        public_row.pack(fill=tk.X, pady=(8, 0))
        self.public_qr_label = ttk.Label(public_row)
        self.public_qr_label.pack(side=tk.LEFT, padx=(0, 12))
        public_info = ttk.Frame(public_row)
        public_info.pack(side=tk.LEFT, fill=tk.BOTH, expand=True)
        ttk.Label(public_info, textvariable=self.public_pairing_code_var,
                  font=("Consolas", 21, "bold"), foreground="#175CD3").pack(anchor=tk.W)
        ttk.Label(public_info, textvariable=self.public_pairing_expiry_var,
                  foreground="#667085", wraplength=250).pack(anchor=tk.W, pady=(3, 8))
        ttk.Button(public_info, text="生成公网配对码",
                   command=self.server.create_public_pairing).pack(anchor=tk.W)
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
        ttk.Button(log_header, text="打开日志位置", command=self.open_log_location).pack(
            side=tk.RIGHT, padx=(0, 8))
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

    def _gateway_config_summary(self) -> str:
        if not self.config.gateway_enabled:
            return "尚未配置公网服务器"
        credential_state = ("设备凭据已保护" if self.config.gateway_device_credential
                            else "等待首次安全登记")
        return f"{self.config.gateway_url} · {credential_state}"

    def _open_gateway_settings(self) -> None:
        existing = self.gateway_settings_window
        if existing is not None and existing.winfo_exists():
            existing.deiconify()
            existing.lift()
            existing.focus_force()
            return
        dialog = tk.Toplevel(self.root)
        self.gateway_settings_window = dialog
        dialog.title("公网服务器设置")
        dialog.geometry("570x390")
        dialog.minsize(530, 360)
        dialog.transient(self.root)
        dialog.grab_set()
        dialog.protocol("WM_DELETE_WINDOW", dialog.destroy)

        body = ttk.Frame(dialog, padding=20)
        body.pack(fill=tk.BOTH, expand=True)
        ttk.Label(body, text="连接自建 Starly Gateway",
                  font=("Microsoft YaHei UI", 16, "bold")).grid(
                      row=0, column=0, columnspan=2, sticky=tk.W, pady=(0, 6))
        ttk.Label(
            body,
            text="公网只允许 WSS。Pairing ID 和首次接入 Token 位于服务器的 "
                 "/root/starly-gateway-credentials.txt。",
            foreground="#667085", wraplength=510,
        ).grid(row=1, column=0, columnspan=2, sticky=tk.W, pady=(0, 16))

        url_var = tk.StringVar(master=dialog, value=self.config.gateway_url)
        pairing_var = tk.StringVar(master=dialog, value=self.config.gateway_pairing_id)
        token_var = tk.StringVar(master=dialog, value="")
        ttk.Label(body, text="服务器地址").grid(row=2, column=0, sticky=tk.W, pady=6)
        url_entry = ttk.Entry(body, textvariable=url_var, width=48)
        url_entry.grid(row=2, column=1, sticky=tk.EW, pady=6)
        ttk.Label(body, text="Pairing ID").grid(row=3, column=0, sticky=tk.W, pady=6)
        ttk.Entry(body, textvariable=pairing_var, width=48).grid(
            row=3, column=1, sticky=tk.EW, pady=6)
        ttk.Label(body, text="首次接入 Token").grid(row=4, column=0, sticky=tk.W, pady=6)
        ttk.Entry(body, textvariable=token_var, width=48, show="●").grid(
            row=4, column=1, sticky=tk.EW, pady=6)
        ttk.Label(
            body,
            text="Token 留空会保留当前凭据。输入新 Token 会重新登记设备；密钥只会经 "
                 "Windows DPAPI 加密保存，不写入日志或二维码。",
            foreground="#667085", wraplength=510,
        ).grid(row=5, column=0, columnspan=2, sticky=tk.W, pady=(10, 18))

        buttons = ttk.Frame(body)
        buttons.grid(row=6, column=0, columnspan=2, sticky=tk.EW)
        ttk.Button(buttons, text="停用公网连接",
                   command=lambda: self._disable_gateway(dialog)).pack(side=tk.LEFT)
        ttk.Button(buttons, text="取消", command=dialog.destroy).pack(side=tk.RIGHT)
        ttk.Button(
            buttons, text="保存并重新连接",
            command=lambda: self._save_gateway_settings(
                dialog, url_var.get(), pairing_var.get(), token_var.get()),
        ).pack(side=tk.RIGHT, padx=(0, 8))
        body.columnconfigure(1, weight=1)
        url_entry.focus_set()

    def _save_gateway_settings(self, dialog: tk.Toplevel, raw_url: str,
                               raw_pairing_id: str, raw_token: str) -> None:
        try:
            gateway_url = normalize_gateway_url(raw_url)
        except ValueError as error:
            messagebox.showerror("服务器地址无效", str(error), parent=dialog)
            return
        pairing_id = raw_pairing_id.strip()
        token = raw_token.strip()
        if not re.fullmatch(r"[A-Za-z0-9._-]{8,128}", pairing_id):
            messagebox.showerror(
                "Pairing ID 无效", "Pairing ID 应为 8–128 位字母、数字、点、下划线或短横线。",
                parent=dialog)
            return
        if token and not 32 <= len(token) <= 512:
            messagebox.showerror(
                "Token 无效", "首次接入 Token 长度应为 32–512 个字符。", parent=dialog)
            return
        pairing_changed = pairing_id != self.config.gateway_pairing_id
        url_changed = gateway_url != self.config.gateway_url
        if pairing_changed and not token:
            messagebox.showerror(
                "需要首次接入 Token", "更换 Pairing ID 时必须输入新服务器生成的 Token。",
                parent=dialog)
            return
        if not token and not self.config.gateway_token:
            messagebox.showerror(
                "需要首次接入 Token", "首次配置服务器时必须输入 Token。", parent=dialog)
            return
        if (pairing_changed or (url_changed and token)) and not messagebox.askyesno(
                "重新登记公网设备",
                "将清除旧服务器签发的会话和设备凭据，并生成新的 PC 设备身份。是否继续？",
                parent=dialog):
            return

        self.server.stop()
        reset_identity = pairing_changed or (url_changed and bool(token))
        self.config.gateway_url = gateway_url
        self.config.gateway_pairing_id = pairing_id
        if token:
            self.config.gateway_token = token
            self.config.gateway_session_token = ""
            self.config.gateway_device_credential = ""
        if reset_identity:
            self.config.gateway_device_id = f"bridge-{secrets.token_hex(12)}"
            private_key, public_key = generate_device_identity()
            self.config.gateway_private_key = private_key
            self.config.gateway_public_key = public_key
            self.config.gateway_last_seq = 0
            self.config.gateway_send_counter = 0
            self.config.gateway_received_counters = {}
            self.config.gateway_session_token = ""
            self.config.gateway_device_credential = ""
        self.config.save()
        self.server = BridgeServer(self.config, self.events)
        self.server.start()
        self.gateway_config_var.set(self._gateway_config_summary())
        self.public_pairing_code_var.set("连接成功后可生成")
        self.public_pairing_expiry_var.set("公网地址和凭据已安全保存")
        self.public_qr_label.configure(image="")
        dialog.destroy()
        self.status_var.set("正在连接自建公网服务器…")
        self._append_log("公网 Gateway 配置已更新，正在重新连接")

    def _disable_gateway(self, dialog: tk.Toplevel) -> None:
        if self.config.gateway_enabled and not messagebox.askyesno(
                "停用公网连接", "停用后仍可继续使用局域网连接。是否继续？", parent=dialog):
            return
        self.server.stop()
        self.config.gateway_url = ""
        self.config.gateway_pairing_id = secrets.token_hex(16)
        self.config.gateway_token = secrets.token_urlsafe(32)
        self.config.gateway_session_token = ""
        self.config.gateway_device_credential = ""
        self.config.gateway_device_id = f"bridge-{secrets.token_hex(12)}"
        private_key, public_key = generate_device_identity()
        self.config.gateway_private_key = private_key
        self.config.gateway_public_key = public_key
        self.config.gateway_last_seq = 0
        self.config.gateway_send_counter = 0
        self.config.gateway_received_counters = {}
        self.config.save()
        self.server = BridgeServer(self.config, self.events)
        self.server.start()
        self.gateway_config_var.set(self._gateway_config_summary())
        self.public_pairing_code_var.set("请先配置公网服务器")
        self.public_pairing_expiry_var.set("局域网连接不受影响")
        self.public_qr_label.configure(image="")
        dialog.destroy()
        self.status_var.set("已停用公网连接")
        self._append_log("公网 Gateway 已停用")

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
        code = self.config.pairing_code
        self.pairing_code_var.set(f"{code[:3]} {code[3:]}")
        self.address_var.set(
            f"{socket.gethostname()} · {get_lan_ip()}:{self.config.port} · 自动发现 {DEFAULT_DISCOVERY_PORT}"
        )

    def _poll_events(self) -> None:
        while True:
            try:
                event_type, message = self.events.get_nowait()
            except queue.Empty:
                break
            if event_type == "pairing_code_changed":
                self._refresh_pairing_view()
                display_message = "六位配对码已自动更新"
            elif event_type == "client_connected":
                self.connected_devices.add(message)
                self._refresh_paired_devices()
                display_message = f"手机已配对：{message}"
            elif event_type == "client_disconnected":
                self.connected_devices.discard(message)
                self._refresh_paired_devices()
                display_message = f"手机已断开：{message}"
            elif event_type == "gateway_phone_snapshot":
                try:
                    snapshot = json.loads(message)
                    online_ids = {str(value) for value in snapshot.get("peerDevices", [])
                                  if str(value)}
                    devices: dict[str, dict[str, object]] = {}
                    for value in snapshot.get("knownPeerDevices", []):
                        if not isinstance(value, dict):
                            continue
                        device_id = str(value.get("deviceId", "")).strip()
                        if not device_id:
                            continue
                        devices[device_id] = {
                            "displayName": str(value.get("displayName", "")).strip(),
                            "online": device_id in online_ids,
                        }
                    for device_id in online_ids:
                        devices.setdefault(device_id, {
                            "displayName": "", "online": True,
                        })
                    self.gateway_devices = devices
                    self._refresh_paired_devices()
                    display_message = "公网手机列表已同步"
                except (TypeError, ValueError, json.JSONDecodeError):
                    display_message = "公网手机列表无法识别"
            elif event_type == "gateway_phone_presence":
                try:
                    presence = json.loads(message)
                    device_id = str(presence.get("deviceId", "")).strip()
                    if device_id:
                        device = self.gateway_devices.setdefault(device_id, {
                            "displayName": "", "online": False,
                        })
                        device["online"] = bool(presence.get("online", False))
                        self._refresh_paired_devices()
                    display_message = ("公网手机已上线" if presence.get("online", False)
                                       else "公网手机已离线")
                except (TypeError, ValueError, json.JSONDecodeError):
                    display_message = "公网手机状态无法识别"
            elif event_type == "gateway_phone_seen":
                device = self.gateway_devices.setdefault(message, {
                    "displayName": "", "online": False,
                })
                device["online"] = True
                self._refresh_paired_devices()
                display_message = f"收到公网手机消息：{message}"
            elif event_type == "gateway_pairing_created":
                try:
                    pairing = json.loads(message)
                    self._show_public_pairing(pairing)
                    display_message = "公网一次性配对码已生成，2 分钟内有效"
                except (TypeError, ValueError, json.JSONDecodeError):
                    display_message = "公网配对信息无效"
            elif event_type == "gateway_pairing_request":
                try:
                    pairing = json.loads(message)
                    request_id = str(pairing.get("requestId", ""))
                    phone_name = str(pairing.get("phoneName", "Starly Phone"))
                    verification = str(pairing.get("verificationCode", ""))
                    approved = messagebox.askyesno(
                        "公网配对请求",
                        f"是否允许手机“{phone_name}”连接？\n\n"
                        f"安全校验码：{verification}\n\n"
                        "请确认手机上显示的数字一致。")
                    self.server.decide_public_pairing(request_id, approved)
                    display_message = "已允许公网配对" if approved else "已拒绝公网配对"
                except (TypeError, ValueError, json.JSONDecodeError):
                    display_message = "无法处理公网配对请求"
            elif event_type == "gateway_pairing_approved":
                self.public_pairing_code_var.set("配对已完成")
                self.public_pairing_expiry_var.set("一次性信息已作废")
                self.public_qr_label.configure(image="")
                display_message = "手机已通过公网安全配对"
            elif event_type in ("gateway_connected", "gateway_disconnected"):
                self.gateway_config_var.set(self._gateway_config_summary())
                if event_type == "gateway_disconnected":
                    for device in self.gateway_devices.values():
                        device["online"] = False
                    self._refresh_paired_devices()
                display_message = message
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

    def _show_public_pairing(self, pairing: dict[str, object]) -> None:
        gateway_url = self.config.gateway_url.split("?", 1)[0] + "?pair=1"
        uri = "starly://public-pair?" + urllib.parse.urlencode({
            "v": "2",
            "url": gateway_url,
            "session": str(pairing.get("sessionId", "")),
            "secret": str(pairing.get("secret", "")),
            "expires": str(pairing.get("expiresAt", "")),
        })
        qr = qrcode.QRCode(version=None, box_size=4, border=2)
        qr.add_data(uri)
        qr.make(fit=True)
        image = qr.make_image(fill_color="#101828", back_color="white").convert("RGB")
        image.thumbnail((145, 145), Image.Resampling.LANCZOS)
        self.public_qr_photo = ImageTk.PhotoImage(image)
        self.public_qr_label.configure(image=self.public_qr_photo)
        self.public_pairing_code_var.set(str(pairing.get("code", "")))
        self.public_pairing_expiry_var.set("二维码和短码只能使用一次，2 分钟后失效")

    def _refresh_paired_devices(self) -> None:
        self.paired_devices_var.set(format_paired_devices(
            self.connected_devices, self.gateway_devices))

    def toggle_qr(self) -> None:
        self.qr_collapsed = not self.qr_collapsed
        if self.qr_collapsed:
            self.qr_body.pack_forget()
            self.qr_toggle_button.configure(text="展开二维码和密钥选项")
        else:
            self.qr_body.pack(fill=tk.X)
            self.qr_toggle_button.configure(text="收起二维码和密钥选项")

    def toggle_lan_pairing(self) -> None:
        self.lan_pairing_collapsed = not self.lan_pairing_collapsed
        if self.lan_pairing_collapsed:
            self.lan_pairing_body.pack_forget()
            self.lan_pairing_toggle_button.configure(text="展开")
        else:
            self.lan_pairing_body.pack(fill=tk.X)
            self.lan_pairing_toggle_button.configure(text="收起")

    def toggle_public_pairing(self) -> None:
        self.public_pairing_collapsed = not self.public_pairing_collapsed
        if self.public_pairing_collapsed:
            self.public_pairing_body.pack_forget()
            self.public_pairing_toggle_button.configure(text="展开")
        else:
            self.public_pairing_body.pack(fill=tk.X)
            self.public_pairing_toggle_button.configure(text="收起")

    def toggle_log(self) -> None:
        self.log_collapsed = not self.log_collapsed
        if self.log_collapsed:
            self.log_body.pack_forget()
            self.log_toggle_button.configure(text="展开日志")
        else:
            self.log_body.pack(fill=tk.BOTH, expand=True)
            self.log_toggle_button.configure(text="收起日志")

    def open_log_location(self) -> None:
        try:
            CONFIG_DIR.mkdir(parents=True, exist_ok=True)
            os.startfile(str(CONFIG_DIR))
        except OSError as error:
            messagebox.showerror(
                "无法打开日志位置", f"资源管理器无法打开日志目录：{error}",
                parent=self.root)

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

    def regenerate_pairing_code(self) -> None:
        self.config.rotate_pairing_code()
        self.config.save()
        self._refresh_pairing_view()
        self.status_var.set("六位配对码已更新")
        self._append_log("六位配对码已手动更新")

    def regenerate_token(self) -> None:
        if not messagebox.askyesno(
                "更换局域网密钥",
                "现有局域网直连会失效，需要重新配对；公网 Gateway 不受影响。是否继续？"):
            return
        self.server.stop()
        self.config.token = secrets.token_urlsafe(32)
        self.config.save()
        self.server = BridgeServer(self.config, self.events)
        self.server.start()
        self._refresh_pairing_view()
        self._append_log("局域网配对密钥已更换")

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
