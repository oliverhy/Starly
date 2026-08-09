from __future__ import annotations

import asyncio
import base64
import hashlib
import io
import json
import os
import re
import shutil
from datetime import datetime
from pathlib import Path
from typing import Any, Awaitable, Callable

from PIL import Image


JsonObject = dict[str, Any]
EventCallback = Callable[[str, JsonObject], Awaitable[None]]
LOCAL_DETAIL_MESSAGE_LIMIT = 15
LOCAL_ACTIVITY_LIMIT = 30
THREAD_ID_PATTERN = re.compile(r"^[0-9a-fA-F-]{36}$")


def find_codex_executable() -> Path | None:
    configured = os.environ.get("STARLY_CODEX_PATH", "").strip()
    if configured:
        candidate = Path(configured).expanduser()
        if candidate.is_file():
            return candidate
    local_app_data = Path(os.environ.get("LOCALAPPDATA", ""))
    candidates = list((local_app_data / "OpenAI" / "Codex" / "bin").glob("*/codex.exe"))
    if candidates:
        return max(candidates, key=lambda path: path.stat().st_mtime)
    on_path = shutil.which("codex")
    return Path(on_path) if on_path else None


def _usable_text(value: object) -> str:
    text = str(value or "").strip()
    return "" if "\ufffd" in text else text


def _status_type(value: object) -> str:
    if isinstance(value, dict):
        return str(value.get("type", "notLoaded"))
    return str(value or "notLoaded")


def _rpc_error_text(value: object) -> str:
    if isinstance(value, dict):
        message = str(value.get("message", "") or "").strip()
        if message:
            return message
    return str(value)


def normalize_thread(thread: JsonObject) -> JsonObject:
    cwd = str(thread.get("cwd", ""))
    title = _usable_text(thread.get("name"))
    preview = _usable_text(thread.get("preview"))
    if not title:
        title = Path(cwd).name if cwd else "Codex 任务"
    return {
        "id": str(thread.get("id", "")),
        "title": title[:80],
        "preview": preview[:180],
        "status": _status_type(thread.get("status")),
        "cwd": cwd,
        "updatedAt": int(thread.get("updatedAt", 0) or 0),
        "archived": bool(thread.get("archived", False)),
    }


def normalize_snapshot(rate_response: JsonObject, usage_response: JsonObject,
                       thread_response: JsonObject,
                       model_response: JsonObject | None = None) -> JsonObject:
    limits = rate_response.get("rateLimits")
    limits = limits if isinstance(limits, dict) else {}
    primary = limits.get("primary")
    primary = primary if isinstance(primary, dict) else {}
    secondary = limits.get("secondary")
    secondary = secondary if isinstance(secondary, dict) else {}
    used = max(0.0, min(100.0, float(primary.get("usedPercent", 0) or 0)))
    secondary_used = max(0.0, min(100.0, float(secondary.get("usedPercent", 0) or 0)))
    usage = usage_response.get("usage")
    if not isinstance(usage, dict):
        usage = usage_response.get("summary")
    usage = usage if isinstance(usage, dict) else usage_response
    credits = rate_response.get("credits", limits.get("credits"))
    credits = credits if isinstance(credits, dict) else {}
    reset_credits = rate_response.get("rateLimitResetCredits", limits.get("rateLimitResetCredits"))
    reset_credits = reset_credits if isinstance(reset_credits, dict) else {}
    raw_threads = thread_response.get("data")
    raw_threads = raw_threads if isinstance(raw_threads, list) else []
    threads = [normalize_thread(item) for item in raw_threads if isinstance(item, dict)]
    raw_models = (model_response or {}).get("data")
    models = raw_models if isinstance(raw_models, list) else []
    return {
        "available": True,
        "error": "",
        "quota": {
            "remainingPercent": round(100.0 - used, 1),
            "usedPercent": round(used, 1),
            "resetAt": int(primary.get("resetsAt", 0) or 0),
            "windowMinutes": int(primary.get("windowDurationMins", 0) or 0),
            "secondaryRemainingPercent": round(100.0 - secondary_used, 1) if secondary else -1,
            "secondaryResetAt": int(secondary.get("resetsAt", 0) or 0),
            "plan": str(rate_response.get("planType", limits.get("planType", "")) or ""),
            "credits": str(credits.get("balance", "") or ""),
            "resetCredits": len(reset_credits.get("credits", []) or []),
            "lifetimeTokens": int(usage.get("lifetimeTokens", 0) or 0),
        },
        "threads": threads,
        "models": [item for item in models if isinstance(item, dict) and not item.get("hidden")],
    }


def _local_image_data_url(raw_path: str) -> str:
    path_text = raw_path.strip()
    if not path_text:
        return ""
    if path_text.startswith("file://"):
        from urllib.parse import unquote, urlparse
        parsed = urlparse(path_text)
        decoded_path = unquote(parsed.path)
        if os.name == "nt":
            # Handle both file:///C:/... and file://C:/... forms.
            path_text = (parsed.netloc + decoded_path) if parsed.netloc else decoded_path
            path_text = path_text.lstrip("/")
        else:
            path_text = decoded_path
    path = Path(path_text)
    if not path.is_file():
        return ""
    try:
        with Image.open(path) as source:
            source.thumbnail((720, 720), Image.Resampling.LANCZOS)
            if source.mode != "RGB":
                rgb = Image.new("RGB", source.size, "white")
                if "A" in source.getbands():
                    rgb.paste(source, mask=source.getchannel("A"))
                else:
                    rgb.paste(source)
                source = rgb
            output = io.BytesIO()
            source.save(output, format="JPEG", quality=70, optimize=True)
        return "data:image/jpeg;base64," + base64.b64encode(output.getvalue()).decode("ascii")
    except (OSError, ValueError):
        return ""


def _image_source(value: object) -> str:
    source = str(value or "").strip()
    if source.startswith(("https://", "http://", "data:image/")):
        return source
    return _local_image_data_url(source)


_MARKDOWN_IMAGE_PATTERN = re.compile(r"!\[([^\]]*)\]\((?:<([^>]+)>|([^\)]+))\)")
_HTML_IMAGE_PATTERN = re.compile(
    r"<img\b[^>]*\bsrc\s*=\s*[\"']([^\"']+)[\"'][^>]*>",
    re.IGNORECASE,
)


def _extract_inline_images(text: str) -> tuple[str, list[str]]:
    """Convert Markdown/HTML image references into phone-renderable sources."""
    images: list[str] = []

    def replace_markdown(match: re.Match[str]) -> str:
        alt = match.group(1).strip()
        candidate = (match.group(2) or match.group(3) or "").strip()
        source = _image_source(candidate)
        if not source:
            return match.group(0)
        images.append(source)
        return alt or "图片"

    def replace_html(match: re.Match[str]) -> str:
        source = _image_source(match.group(1).strip())
        if not source:
            return match.group(0)
        images.append(source)
        return "图片"

    cleaned = _MARKDOWN_IMAGE_PATTERN.sub(replace_markdown, text)
    cleaned = _HTML_IMAGE_PATTERN.sub(replace_html, cleaned)
    return cleaned.strip(), images


def _item_content(item: JsonObject) -> tuple[str, str, list[str]]:
    item_type = str(item.get("type", ""))
    if item_type == "agentMessage":
        text, images = _extract_inline_images(_usable_text(item.get("text")))
        return "assistant", text, images
    if item_type == "userMessage":
        content = item.get("content")
        parts: list[str] = []
        images: list[str] = []
        if isinstance(content, list):
            for value in content:
                if not isinstance(value, dict):
                    continue
                value_type = str(value.get("type", ""))
                if value_type in ("text", "inputText"):
                    parts.append(str(value.get("text", "")))
                elif value_type == "image":
                    source = _image_source(value.get(
                        "url", value.get("path", value.get("imageUrl"))))
                    if source:
                        images.append(source)
                elif value_type in ("localImage", "inputImage"):
                    source = _image_source(value.get("path", value.get("imageUrl")))
                    if source:
                        images.append(source)
        text, inline_images = _extract_inline_images("\n".join(parts))
        return "user", text, images + inline_images
    if item_type == "imageGeneration":
        source = _image_source(item.get("savedPath", item.get("result")))
        return "assistant", "生成的图片", [source] if source else []
    return "", "", []


def _timestamp_value(value: object) -> int:
    text = str(value or "").strip()
    if not text:
        return 0
    try:
        return int(datetime.fromisoformat(text.replace("Z", "+00:00")).timestamp())
    except ValueError:
        return 0


def _redact_activity_text(value: object, limit: int = 600) -> str:
    """Keep public progress summaries useful without relaying likely secrets."""
    text = str(value or "").strip()
    text = re.sub(r"-----BEGIN [^-]+PRIVATE KEY-----.*?-----END [^-]+PRIVATE KEY-----",
                  "[已隐藏私钥]", text, flags=re.IGNORECASE | re.DOTALL)
    text = re.sub(r"\bBearer\s+[A-Za-z0-9._~+/=-]+", "Bearer [已隐藏]", text,
                  flags=re.IGNORECASE)
    text = re.sub(r"\bsk-[A-Za-z0-9_-]{12,}\b", "[已隐藏密钥]", text)
    text = re.sub(
        r"(?i)\b(password|passwd|token|secret|api[_-]?key)\s*[:=]\s*[^\s,;]+",
        lambda match: f"{match.group(1)}=[已隐藏]", text)
    return text[:limit]


def _tool_display_name(value: object) -> str:
    name = str(value or "").strip().lower()
    labels = {
        "exec": "执行本地操作",
        "wait": "等待后台任务",
        "apply_patch": "修改文件",
        "view_image": "查看图片",
        "web_search": "搜索网页",
        "imagegen": "生成图片",
    }
    return labels.get(name, "调用工具")


def _rollout_activity(record: JsonObject, raw_line: bytes,
                      completed_calls: set[str]) -> JsonObject | None:
    payload = record.get("payload")
    if not isinstance(payload, dict):
        return None
    payload_type = str(payload.get("type", ""))
    call_id = str(payload.get("call_id", ""))
    timestamp = _timestamp_value(record.get("timestamp"))
    turn_id = str(payload.get("turn_id", ""))
    title = ""
    text = ""
    kind = "tool"
    status = "completed"
    if payload_type == "agent_reasoning":
        text = _redact_activity_text(payload.get("text"))
        if not text:
            return None
        title = "思考摘要"
        kind = "reasoning"
    elif payload_type in ("custom_tool_call", "function_call"):
        title = _tool_display_name(payload.get("name"))
        kind = "tool"
        status = "completed" if call_id in completed_calls or \
            str(payload.get("status", "")) == "completed" else "running"
    elif payload_type == "patch_apply_end":
        changes = payload.get("changes")
        names: list[str] = []
        if isinstance(changes, dict):
            names = [Path(str(path)).name for path in list(changes.keys())[:6]]
        title = "文件修改完成" if bool(payload.get("success", False)) else "文件修改失败"
        text = "、".join(name for name in names if name)
        kind = "file"
        status = "completed" if bool(payload.get("success", False)) else "failed"
    elif payload_type == "web_search_end":
        title = "网页搜索完成"
        kind = "web"
    elif payload_type == "mcp_tool_call_end":
        title = "外部工具调用完成"
        kind = "tool"
    elif payload_type == "image_generation_end":
        title = "图片生成完成"
        kind = "image"
    else:
        return None
    return {
        "id": hashlib.sha1(raw_line).hexdigest()[:24],
        "kind": kind,
        "title": title,
        "text": text,
        "status": status,
        "timestamp": timestamp,
        "turnId": turn_id,
    }


def _recent_rollout_activities(path: Path,
                               limit: int = LOCAL_ACTIVITY_LIMIT) -> list[JsonObject]:
    """Return public activity for the latest turn; never expose tool I/O or encrypted reasoning."""
    newest_first: list[JsonObject] = []
    completed_calls: set[str] = set()
    saw_latest_turn = False
    scanned = 0
    for raw_line in _reverse_jsonl_lines(path):
        scanned += 1
        if scanned > 20_000:
            break
        try:
            record = json.loads(raw_line)
        except (UnicodeDecodeError, json.JSONDecodeError):
            continue
        payload = record.get("payload")
        if not isinstance(payload, dict):
            continue
        payload_type = str(payload.get("type", ""))
        if payload_type in ("custom_tool_call_output", "function_call_output"):
            call_id = str(payload.get("call_id", ""))
            if call_id:
                completed_calls.add(call_id)
            continue
        if payload_type in ("task_complete", "turn_aborted"):
            saw_latest_turn = True
            continue
        if payload_type == "task_started":
            if saw_latest_turn or newest_first:
                break
            saw_latest_turn = True
            continue
        activity = _rollout_activity(record, raw_line, completed_calls)
        if activity is not None:
            newest_first.append(activity)
            saw_latest_turn = True
    chronological = list(reversed(newest_first))
    if len(chronological) <= limit:
        return chronological
    # Tool-heavy turns can otherwise push every reasoning summary out of the
    # phone window. Reserve up to half the window for public reasoning, then
    # fill the rest with the newest operational events while preserving order.
    reasoning = [item for item in chronological if item.get("kind") == "reasoning"][-limit // 2:]
    reasoning_ids = {str(item.get("id", "")) for item in reasoning}
    remaining = limit - len(reasoning)
    operational = [item for item in chronological
                   if str(item.get("id", "")) not in reasoning_ids][-remaining:]
    selected_ids = {str(item.get("id", "")) for item in reasoning + operational}
    return [item for item in chronological if str(item.get("id", "")) in selected_ids]


def _reverse_jsonl_lines(path: Path, chunk_size: int = 256 * 1024):
    """Yield a JSONL file from newest to oldest without loading it into memory."""
    with path.open("rb") as handle:
        handle.seek(0, os.SEEK_END)
        position = handle.tell()
        buffer = b""
        while position > 0:
            read_size = min(chunk_size, position)
            position -= read_size
            handle.seek(position)
            buffer = handle.read(read_size) + buffer
            lines = buffer.split(b"\n")
            buffer = lines[0]
            for line in reversed(lines[1:]):
                if line:
                    yield line
        if buffer:
            yield buffer


def _find_rollout_file(thread_id: str) -> Path | None:
    if not THREAD_ID_PATTERN.fullmatch(thread_id):
        return None
    codex_home = Path(os.environ.get("CODEX_HOME", Path.home() / ".codex"))
    matches: list[Path] = []
    for folder_name in ("sessions", "archived_sessions"):
        folder = codex_home / folder_name
        if folder.is_dir():
            matches.extend(folder.rglob(f"*{thread_id}.jsonl"))
    valid = [path for path in matches if path.is_file()]
    return max(valid, key=lambda path: path.stat().st_mtime) if valid else None


def _indexed_thread_title(thread_id: str) -> str:
    codex_home = Path(os.environ.get("CODEX_HOME", Path.home() / ".codex"))
    index_path = codex_home / "session_index.jsonl"
    title = ""
    try:
        with index_path.open("r", encoding="utf-8") as handle:
            for line in handle:
                try:
                    item = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if str(item.get("id", "")) == thread_id:
                    title = _usable_text(item.get("thread_name")) or title
    except (OSError, UnicodeError):
        return ""
    return title


def _rollout_user_message(payload: JsonObject) -> tuple[str, list[str]]:
    content = payload.get("content")
    if not isinstance(content, list):
        return "", []
    parts: list[str] = []
    images: list[str] = []
    for item in content:
        if not isinstance(item, dict):
            continue
        item_type = str(item.get("type", ""))
        if item_type in ("input_text", "text"):
            parts.append(str(item.get("text", "")))
        elif item_type in ("input_image", "image", "local_image"):
            source = _image_source(item.get(
                "image_url", item.get("url", item.get("path"))))
            if source:
                images.append(source)
    text, inline_images = _extract_inline_images("\n".join(parts).strip())
    ignored_prefixes = (
        "<environment_context>", "<recommended_plugins>",
        "<permissions instructions>", "<app-context>",
    )
    if text.startswith(ignored_prefixes):
        text = ""
    return text, images + inline_images


def _latest_rollout_settings(path: Path, max_records: int = 20_000) -> JsonObject:
    """Read the settings that the desktop actually used for the latest turn."""
    scanned = 0
    for raw_line in _reverse_jsonl_lines(path):
        scanned += 1
        if scanned > max_records:
            break
        if b'"type":"turn_context"' not in raw_line and b'"type": "turn_context"' not in raw_line:
            continue
        try:
            record = json.loads(raw_line)
        except (UnicodeDecodeError, json.JSONDecodeError):
            continue
        payload = record.get("payload")
        record_type = str(record.get("type", ""))
        payload_type = str(payload.get("type", "")) if isinstance(payload, dict) else ""
        if not isinstance(payload, dict) or \
                (record_type != "turn_context" and payload_type != "turn_context"):
            continue
        collaboration = payload.get("collaboration_mode")
        collaboration_settings = collaboration.get("settings") \
            if isinstance(collaboration, dict) else {}
        collaboration_settings = collaboration_settings \
            if isinstance(collaboration_settings, dict) else {}
        sandbox = payload.get("sandbox_policy")
        sandbox = sandbox if isinstance(sandbox, dict) else {}
        sandbox_type = re.sub(r"[^a-z]", "", str(sandbox.get("type", "")).lower())
        approval_policy = str(payload.get("approval_policy", "")).lower()
        if sandbox_type == "dangerfullaccess":
            permission_mode = "fullAccess"
        elif sandbox_type == "readonly":
            permission_mode = "readOnly"
        elif sandbox_type == "workspacewrite" and approval_policy == "never":
            permission_mode = "autoApprove"
        else:
            permission_mode = "default"
        return {
            "model": str(payload.get("model", collaboration_settings.get("model", ""))),
            "effort": str(payload.get(
                "effort", collaboration_settings.get("reasoning_effort", ""))),
            "permissionMode": permission_mode,
            "serviceTier": str(payload.get(
                "service_tier", payload.get("serviceTier", ""))),
        }
    return {}


def read_rollout_thread_detail(thread_id: str,
                               metadata: JsonObject | None = None,
                               before_message_id: str = "",
                               limit: int = LOCAL_DETAIL_MESSAGE_LIMIT) -> JsonObject | None:
    """Read a stable page of visible messages from Codex's append-only history."""
    path = _find_rollout_file(thread_id)
    if path is None:
        return None
    meta = dict(metadata or {})
    if not meta.get("cwd"):
        try:
            with path.open("r", encoding="utf-8") as handle:
                first = json.loads(handle.readline())
            payload = first.get("payload")
            if isinstance(payload, dict):
                meta["cwd"] = str(payload.get("cwd", ""))
        except (OSError, UnicodeError, json.JSONDecodeError):
            pass
    if not meta.get("title"):
        meta["title"] = _indexed_thread_title(thread_id)
    meta["id"] = thread_id
    meta["name"] = str(meta.get("title", ""))
    meta["updatedAt"] = int(path.stat().st_mtime)

    page_limit = max(1, min(int(limit or LOCAL_DETAIL_MESSAGE_LIMIT), 100))
    newest_first: list[JsonObject] = []
    latest_task_event = ""
    latest_turn_id = ""
    cursor_found = not before_message_id
    for raw_line in _reverse_jsonl_lines(path):
        is_agent = b'agent_message' in raw_line
        is_user = b'response_item' in raw_line and b'"role"' in raw_line and \
            b'"user"' in raw_line
        is_task_event = b'task_started' in raw_line or b'task_complete' in raw_line or \
            b'turn_aborted' in raw_line
        if not (is_agent or is_user or is_task_event):
            continue
        try:
            record = json.loads(raw_line)
        except (UnicodeDecodeError, json.JSONDecodeError):
            continue
        payload = record.get("payload")
        if not isinstance(payload, dict):
            continue
        payload_type = str(payload.get("type", ""))
        if payload_type in ("task_started", "task_complete", "turn_aborted") and \
                not latest_task_event:
            latest_task_event = payload_type
            latest_turn_id = str(payload.get("turn_id", ""))
        visible_message: JsonObject | None = None
        if is_agent and payload_type == "agent_message":
            text, images = _extract_inline_images(str(payload.get("message", "")))
            if text or images:
                visible_message = {
                    "id": hashlib.sha1(raw_line).hexdigest()[:24],
                    "role": "assistant", "text": text, "images": images,
                    "timestamp": _timestamp_value(record.get("timestamp")),
                    "turnId": str(payload.get("turn_id", "")) or
                              str(record.get("timestamp", "")),
                }
        elif is_user and payload_type == "message" and \
                str(payload.get("role", "")) == "user":
            text, images = _rollout_user_message(payload)
            if text or images:
                passthrough = payload.get("internal_chat_message_metadata_passthrough")
                turn_id = str(passthrough.get("turn_id", "")) \
                    if isinstance(passthrough, dict) else ""
                visible_message = {
                    "id": hashlib.sha1(raw_line).hexdigest()[:24],
                    "role": "user", "text": text, "images": images,
                    "timestamp": _timestamp_value(record.get("timestamp")),
                    "turnId": turn_id or str(record.get("timestamp", "")),
                }
        if visible_message is not None:
            message_id = str(visible_message.get("id", ""))
            if not cursor_found:
                if message_id == before_message_id:
                    cursor_found = True
            elif len(newest_first) <= page_limit:
                newest_first.append(visible_message)
        if cursor_found and len(newest_first) > page_limit and latest_task_event:
            break

    if before_message_id and not cursor_found:
        newest_first = []
    has_more_before = len(newest_first) > page_limit
    messages = list(reversed(newest_first[:page_limit]))
    status = "active" if latest_task_event == "task_started" else "idle"
    normalized = normalize_thread({
        "id": thread_id,
        "name": meta.get("title", ""),
        "preview": meta.get("preview", ""),
        "status": status,
        "cwd": meta.get("cwd", ""),
        "updatedAt": meta.get("updatedAt", 0),
        "archived": meta.get("archived", False),
    })
    normalized["messages"] = messages
    normalized["activities"] = _recent_rollout_activities(path)
    normalized["activeTurnId"] = latest_turn_id if status == "active" else ""
    normalized["hasMoreBefore"] = has_more_before
    normalized["updateMode"] = "older" if before_message_id else "latest"
    normalized["rolloutEvent"] = latest_task_event
    normalized.update(_latest_rollout_settings(path))
    return normalized


class CodexAppServerClient:
    def __init__(self, event_callback: EventCallback | None = None) -> None:
        self.executable = find_codex_executable()
        self.event_callback = event_callback
        self.process: asyncio.subprocess.Process | None = None
        self.reader_task: asyncio.Task[None] | None = None
        self.stderr_task: asyncio.Task[None] | None = None
        self.pending: dict[int, asyncio.Future[JsonObject]] = {}
        self.next_id = 1
        self.start_lock = asyncio.Lock()
        self.thread_locks: dict[str, asyncio.Lock] = {}
        self.thread_status: dict[str, str] = {}
        self.thread_metadata: dict[str, JsonObject] = {}
        self.approval_requests: dict[str, tuple[int, str, JsonObject]] = {}

    async def start(self) -> None:
        if self.process and self.process.returncode is None:
            return
        async with self.start_lock:
            if self.process and self.process.returncode is None:
                return
            if self.executable is None:
                raise RuntimeError("未找到 Codex 桌面端，请先安装或启动 Codex")
            flags = 0x08000000 if os.name == "nt" else 0
            self.process = await asyncio.create_subprocess_exec(
                str(self.executable), "app-server",
                stdin=asyncio.subprocess.PIPE,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
                creationflags=flags,
                limit=32 * 1024 * 1024,
            )
            self.reader_task = asyncio.create_task(self._reader_loop())
            self.stderr_task = asyncio.create_task(self._drain_stderr())
            await self.request("initialize", {
                "clientInfo": {"name": "starly", "title": "Starly", "version": "2.1.0"},
                "capabilities": {"experimentalApi": True},
            })
            await self._write({"method": "initialized", "params": {}})

    async def stop(self) -> None:
        process = self.process
        self.process = None
        tasks = [task for task in (self.reader_task, self.stderr_task) if task]
        self.reader_task = None
        self.stderr_task = None
        if process and process.returncode is None:
            process.terminate()
            try:
                await asyncio.wait_for(process.wait(), timeout=2)
            except asyncio.TimeoutError:
                process.kill()
                await process.wait()
        current_task = asyncio.current_task()
        wait_tasks: list[asyncio.Task[None]] = []
        for task in tasks:
            if task is not current_task:
                task.cancel()
                wait_tasks.append(task)
        if wait_tasks:
            await asyncio.gather(*wait_tasks, return_exceptions=True)
        restart_error = RuntimeError("Codex 服务正在重新连接")
        for future in list(self.pending.values()):
            if not future.done():
                future.set_exception(restart_error)
        self.pending.clear()
        self.approval_requests.clear()

    async def request(self, method: str, params: JsonObject | None = None,
                      timeout: float = 15) -> JsonObject:
        if method != "initialize":
            await self.start()
        request_id = self.next_id
        self.next_id += 1
        future = asyncio.get_running_loop().create_future()
        self.pending[request_id] = future
        await self._write({"id": request_id, "method": method, "params": params or {}})
        try:
            return await asyncio.wait_for(future, timeout=timeout)
        finally:
            self.pending.pop(request_id, None)

    async def snapshot(self, include_archived: bool = False) -> JsonObject:
        last_error: Exception | None = None
        for attempt in range(2):
            try:
                requests = [
                    self.request("account/rateLimits/read"),
                    self.request("account/usage/read"),
                    self.request("thread/list", {"limit": 30, "archived": False}),
                    self.request("model/list", {"limit": 50, "includeHidden": False}),
                ]
                if include_archived:
                    requests.append(self.request(
                        "thread/list", {"limit": 30, "archived": True}))
                responses = await asyncio.gather(*requests)
                rate, usage, threads, models = responses[:4]
                snapshot = normalize_snapshot(rate, usage, threads, models)
                for thread in snapshot["threads"]:
                    thread["archived"] = False
                if include_archived and len(responses) > 4:
                    archived_snapshot = normalize_snapshot({}, {}, responses[4])
                    for thread in archived_snapshot["threads"]:
                        thread["archived"] = True
                    known_ids = {str(thread.get("id", "")) for thread in snapshot["threads"]}
                    snapshot["threads"].extend(
                        thread for thread in archived_snapshot["threads"]
                        if str(thread.get("id", "")) not in known_ids)
                for thread in snapshot["threads"]:
                    thread_id = str(thread.get("id", ""))
                    if thread_id:
                        self.thread_metadata[thread_id] = dict(thread)
                await self._reconcile_snapshot_thread_statuses(snapshot["threads"])
                for thread in snapshot["threads"]:
                    thread_id = str(thread.get("id", ""))
                    if thread_id in self.thread_status:
                        thread["status"] = self.thread_status[thread_id]
                return snapshot
            except Exception as error:
                last_error = error
                has_active_turn = any(status == "active" for status in self.thread_status.values())
                if attempt == 0 and not has_active_turn:
                    await self.stop()
                    await asyncio.sleep(0.2)
                    continue
                break
        error_text = str(last_error or "").strip()
        if not error_text and last_error is not None:
            error_text = type(last_error).__name__
        return {"available": False, "error": error_text, "quota": {}, "threads": []}

    async def _reconcile_snapshot_thread_statuses(
            self, threads: list[JsonObject]) -> None:
        """Resolve unknown/stale list states from the append-only rollout."""
        candidates: list[tuple[JsonObject, str]] = []
        for thread in threads:
            thread_id = str(thread.get("id", ""))
            if not thread_id:
                continue
            listed_status = str(thread.get("status", "notLoaded"))
            if listed_status in ("idle", "systemError"):
                # A terminal app-server list result is already authoritative
                # and must replace an old phone/bridge-side active cache.
                self.thread_status[thread_id] = listed_status
            elif listed_status in ("active", "notLoaded") or \
                    self.thread_status.get(thread_id) == "active":
                candidates.append((thread, thread_id))
        if not candidates:
            return
        details = await asyncio.gather(*(
            asyncio.to_thread(
                read_rollout_thread_detail, thread_id,
                self.thread_metadata.get(thread_id))
            for _, thread_id in candidates
        ))
        for (thread, thread_id), detail in zip(candidates, details):
            if detail is None:
                continue
            persisted_status = str(detail.get("status", "notLoaded"))
            persisted_updated_at = int(detail.get("updatedAt", 0) or 0)
            listed_updated_at = int(thread.get("updatedAt", 0) or 0)
            # A previous rollout can still exist for a brand-new turn for a
            # brief moment. Only accept history at least as recent as the list
            # entry. This also resolves notLoaded after a Bridge restart, when
            # no in-memory active cache exists to trigger the old reconciliation.
            if persisted_status != "notLoaded" and persisted_updated_at >= listed_updated_at:
                self.thread_status[thread_id] = persisted_status

    async def thread_detail(self, thread_id: str, before_message_id: str = "",
                            limit: int = LOCAL_DETAIL_MESSAGE_LIMIT) -> JsonObject:
        local_detail = await asyncio.to_thread(
            read_rollout_thread_detail, thread_id, self.thread_metadata.get(thread_id),
            before_message_id, limit)
        if local_detail is not None:
            # The desktop writes task_started/task_complete to the rollout even
            # when the bridge-owned app-server does not receive that task's
            # notifications. Treat the newest persisted event as authoritative;
            # otherwise an old in-memory "active" value can keep a completed
            # desktop task running forever on the phone.
            self.thread_status[thread_id] = str(local_detail.get("status", "idle"))
            return local_detail
        response = await self.request("thread/read", {"threadId": thread_id, "includeTurns": True})
        thread = response.get("thread")
        if not isinstance(thread, dict):
            raise RuntimeError("Codex 没有返回任务详情")
        return self._page_thread_detail(
            self._normalize_thread_detail(thread), before_message_id, limit)

    async def resume_thread_detail(self, thread_id: str) -> JsonObject:
        async with self._thread_lock(thread_id):
            response = await self.request("thread/resume", {"threadId": thread_id}, timeout=30)
            thread = response.get("thread")
            if not isinstance(thread, dict):
                raise RuntimeError("Codex 没有返回恢复后的任务")
            return self._normalize_thread_detail(thread)

    def _normalize_thread_detail(self, thread: JsonObject) -> JsonObject:
        normalized = normalize_thread(thread)
        messages: list[JsonObject] = []
        active_turn_id = ""
        turns = thread.get("turns")
        if isinstance(turns, list):
            for turn in turns:
                if not isinstance(turn, dict):
                    continue
                if str(turn.get("status", "")) == "inProgress":
                    active_turn_id = str(turn.get("id", ""))
                started_at = int(turn.get("startedAt", 0) or 0)
                completed_at = int(turn.get("completedAt", 0) or 0)
                items = turn.get("items")
                if not isinstance(items, list):
                    continue
                for item in items:
                    if not isinstance(item, dict):
                        continue
                    role, text, images = _item_content(item)
                    if role and (text.strip() or images):
                        timestamp = started_at if role == "user" else (completed_at or started_at)
                        message_id_source = json.dumps({
                            "threadId": str(thread.get("id", "")),
                            "turnId": str(turn.get("id", "")),
                            "role": role,
                            "timestamp": timestamp,
                            "index": len(messages),
                            "text": text.strip(),
                        }, ensure_ascii=False, sort_keys=True)
                        messages.append({
                            "id": hashlib.sha1(message_id_source.encode("utf-8")).hexdigest()[:24],
                            "role": role,
                            "text": text.strip(),
                            "images": images,
                            "timestamp": timestamp,
                            "turnId": str(turn.get("id", "")),
                        })
        normalized["messages"] = messages
        normalized["activities"] = []
        normalized["activeTurnId"] = active_turn_id
        if active_turn_id:
            normalized["status"] = "active"
        elif normalized["status"] != "systemError":
            normalized["status"] = "idle"
        self.thread_status[str(normalized.get("id", ""))] = normalized["status"]
        return normalized

    @staticmethod
    def _page_thread_detail(detail: JsonObject, before_message_id: str,
                            limit: int) -> JsonObject:
        page_limit = max(1, min(int(limit or LOCAL_DETAIL_MESSAGE_LIMIT), 100))
        raw_messages = detail.get("messages")
        messages = raw_messages if isinstance(raw_messages, list) else []
        cursor_index = len(messages)
        if before_message_id:
            cursor_index = next((index for index, message in enumerate(messages)
                                 if isinstance(message, dict) and
                                 str(message.get("id", "")) == before_message_id), -1)
            if cursor_index < 0:
                cursor_index = 0
        start_index = max(0, cursor_index - page_limit)
        payload = dict(detail)
        payload["messages"] = messages[start_index:cursor_index]
        payload["hasMoreBefore"] = start_index > 0
        payload["updateMode"] = "older" if before_message_id else "latest"
        return payload

    async def send_message(self, thread_id: str, text: str, model: str = "",
                           effort: str = "", permission_mode: str = "default",
                           image_data_url: str = "", service_tier: str = "") -> JsonObject:
        # thread/list and thread/read can see persisted history without loading
        # it into this app-server process. turn/start only accepts a running or
        # resumed thread, so restore the selected history first.
        async with self._thread_lock(thread_id):
            resumed = await self.request("thread/resume", {"threadId": thread_id}, timeout=30)
            thread = resumed.get("thread")
            if not isinstance(thread, dict):
                raise RuntimeError("Codex 没有返回恢复后的任务")
            detail = self._normalize_thread_detail(thread)
            input_items: list[JsonObject] = []
            if text:
                input_items.append({"type": "text", "text": text})
            if image_data_url:
                input_items.append({"type": "image", "url": image_data_url})
            settings = self._turn_settings(model, effort, permission_mode, service_tier)
            if settings:
                await self.request("thread/settings/update", {
                    "threadId": thread_id, **settings,
                }, timeout=30)
            active_turn_id = str(detail.get("activeTurnId", ""))
            if active_turn_id:
                result = await self.request("turn/steer", {
                    "threadId": thread_id,
                    "expectedTurnId": active_turn_id,
                    "input": input_items,
                }, timeout=30)
            else:
                result = await self.request("turn/start", {
                    "threadId": thread_id,
                    "input": input_items,
                    **settings,
                }, timeout=30)
            self.thread_status[thread_id] = "active"
            return result

    async def create_thread(self, cwd: str, text: str, model: str = "",
                            effort: str = "", permission_mode: str = "default",
                            service_tier: str = "", image_data_url: str = "") -> JsonObject:
        settings = self._turn_settings(model, effort, permission_mode, service_tier)
        thread_settings: JsonObject = {
            "cwd": cwd,
            "approvalPolicy": settings.get("approvalPolicy", "on-request"),
            "sandbox": self._thread_sandbox(permission_mode),
        }
        if model:
            thread_settings["model"] = model
        response = await self.request("thread/start", thread_settings, timeout=30)
        thread = response.get("thread")
        if not isinstance(thread, dict) or not str(thread.get("id", "")):
            raise RuntimeError("Codex 没有返回新任务编号")
        thread_id = str(thread["id"])
        input_items: list[JsonObject] = [{"type": "text", "text": text}]
        if image_data_url:
            input_items.append({"type": "image", "url": image_data_url})
        await self.request("turn/start", {
            "threadId": thread_id,
            "input": input_items,
            **settings,
        }, timeout=30)
        normalized = normalize_thread(thread)
        normalized["cwd"] = cwd
        normalized["status"] = "active"
        self.thread_metadata[thread_id] = normalized
        self.thread_status[thread_id] = "active"
        return {"threadId": thread_id, "thread": normalized}

    @staticmethod
    def _thread_sandbox(permission_mode: str) -> str:
        if permission_mode == "readOnly":
            return "read-only"
        if permission_mode == "fullAccess":
            return "danger-full-access"
        return "workspace-write"

    @staticmethod
    def _turn_settings(model: str, effort: str, permission_mode: str,
                       service_tier: str = "") -> JsonObject:
        settings: JsonObject = {}
        if model:
            settings["model"] = model
        if effort:
            settings["effort"] = effort
        if service_tier:
            settings["serviceTier"] = service_tier
        if permission_mode == "readOnly":
            settings["approvalPolicy"] = "on-request"
            settings["sandboxPolicy"] = {"type": "readOnly", "networkAccess": False}
        elif permission_mode == "fullAccess":
            settings["approvalPolicy"] = "never"
            settings["sandboxPolicy"] = {"type": "dangerFullAccess"}
        elif permission_mode == "autoApprove":
            settings["approvalPolicy"] = "never"
            settings["sandboxPolicy"] = {
                "type": "workspaceWrite", "networkAccess": False,
                "writableRoots": [], "excludeTmpdirEnvVar": False,
                "excludeSlashTmp": False,
            }
        return settings

    def _thread_lock(self, thread_id: str) -> asyncio.Lock:
        lock = self.thread_locks.get(thread_id)
        if lock is None:
            lock = asyncio.Lock()
            self.thread_locks[thread_id] = lock
        return lock

    async def interrupt(self, thread_id: str, turn_id: str) -> JsonObject:
        return await self.request("turn/interrupt", {"threadId": thread_id, "turnId": turn_id})

    async def set_archived(self, thread_id: str, archived: bool) -> None:
        method = "thread/archive" if archived else "thread/unarchive"
        await self.request(method, {"threadId": thread_id}, timeout=30)
        metadata = self.thread_metadata.get(thread_id)
        if metadata is not None:
            metadata["archived"] = archived

    async def rename_thread(self, thread_id: str, name: str) -> None:
        await self.request(
            "thread/name/set", {"threadId": thread_id, "name": name}, timeout=30)
        metadata = self.thread_metadata.get(thread_id)
        if metadata is not None:
            metadata["name"] = name
            metadata["title"] = name

    async def resolve_approval(self, approval_id: str, decision: str,
                               permissions: JsonObject | None = None) -> None:
        approval = self.approval_requests.pop(approval_id, None)
        if approval is None:
            raise RuntimeError("审批请求已失效或已处理")
        request_id, method, requested_permissions = approval
        if decision not in ("accept", "acceptForSession", "decline", "cancel"):
            raise RuntimeError("审批决定无效")
        if method == "item/permissions/requestApproval":
            accepted_permissions = permissions if permissions is not None else requested_permissions
            result: JsonObject = {
                "permissions": accepted_permissions if decision.startswith("accept") else {}
            }
        else:
            result = {"decision": decision}
        await self._write({"id": request_id, "result": result})

    async def release_thread(self, thread_id: str) -> None:
        try:
            await self.request("thread/unsubscribe", {"threadId": thread_id}, timeout=10)
        except Exception:
            # Older app-server builds may not expose unsubscribe. Stopping the
            # bridge-owned process still releases the thread safely.
            pass

    async def _write(self, value: JsonObject) -> None:
        if not self.process or not self.process.stdin:
            raise RuntimeError("Codex 服务未启动")
        self.process.stdin.write((json.dumps(value, ensure_ascii=False) + "\n").encode("utf-8"))
        await self.process.stdin.drain()

    async def _reader_loop(self) -> None:
        assert self.process and self.process.stdout
        while True:
            line = await self.process.stdout.readline()
            if not line:
                error = RuntimeError("Codex 服务已退出")
                for future in self.pending.values():
                    if not future.done():
                        future.set_exception(error)
                return
            try:
                message = json.loads(line.decode("utf-8"))
            except (UnicodeDecodeError, json.JSONDecodeError):
                continue
            request_id = message.get("id")
            if isinstance(request_id, int) and ("result" in message or "error" in message):
                future = self.pending.get(request_id)
                if future and not future.done():
                    if "error" in message:
                        future.set_exception(RuntimeError(_rpc_error_text(message["error"])))
                    else:
                        result = message.get("result")
                        future.set_result(result if isinstance(result, dict) else {})
                continue
            method = str(message.get("method", ""))
            params = message.get("params")
            if method and isinstance(params, dict):
                self._track_status(method, params)
            if request_id is not None and method:
                if method in ("item/commandExecution/requestApproval",
                              "item/fileChange/requestApproval",
                              "item/permissions/requestApproval"):
                    approval_id = f"approval-{request_id}"
                    requested = params.get("permissions")
                    self.approval_requests[approval_id] = (
                        int(request_id), method, dict(requested) if isinstance(requested, dict) else {})
                    event_params = dict(params)
                    event_params["approvalId"] = approval_id
                    event_params["approvalMethod"] = method
                    if self.event_callback:
                        asyncio.create_task(self.event_callback(method, event_params))
                else:
                    await self._write({
                        "id": request_id,
                        "error": {"code": -32001, "message": "Starly 暂不支持此交互确认，请在电脑端完成"},
                    })
                continue
            if method and isinstance(params, dict) and self.event_callback:
                # Notifications may arrive before the response to turn/start.
                # Never let a slow phone broadcast block the protocol reader.
                asyncio.create_task(self.event_callback(method, params))

    def _track_status(self, method: str, params: JsonObject) -> None:
        thread_id = str(params.get("threadId", ""))
        if not thread_id:
            return
        if method == "turn/started":
            self.thread_status[thread_id] = "active"
        elif method == "turn/completed":
            turn = params.get("turn")
            turn_status = str(turn.get("status", "")) if isinstance(turn, dict) else ""
            self.thread_status[thread_id] = "systemError" if turn_status == "failed" else "idle"
        elif method == "thread/status/changed":
            self.thread_status[thread_id] = _status_type(params.get("status"))

    async def _drain_stderr(self) -> None:
        assert self.process and self.process.stderr
        while await self.process.stderr.readline():
            pass
