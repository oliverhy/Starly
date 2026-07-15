from __future__ import annotations

import asyncio
import base64
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
    }


def normalize_snapshot(rate_response: JsonObject, usage_response: JsonObject,
                       thread_response: JsonObject) -> JsonObject:
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


def read_rollout_thread_detail(thread_id: str,
                               metadata: JsonObject | None = None) -> JsonObject | None:
    """Read recent visible messages directly from Codex's append-only history."""
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

    newest_first: list[JsonObject] = []
    latest_task_event = ""
    latest_turn_id = ""
    for raw_line in _reverse_jsonl_lines(path):
        is_agent = b'agent_message' in raw_line
        is_user = b'response_item' in raw_line and b'"role"' in raw_line and \
            b'"user"' in raw_line
        is_task_event = b'task_started' in raw_line or b'task_complete' in raw_line
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
        if payload_type in ("task_started", "task_complete") and not latest_task_event:
            latest_task_event = payload_type
            latest_turn_id = str(payload.get("turn_id", ""))
        if len(newest_first) < LOCAL_DETAIL_MESSAGE_LIMIT and is_agent and \
                payload_type == "agent_message":
            text, images = _extract_inline_images(str(payload.get("message", "")))
            if text or images:
                newest_first.append({
                    "role": "assistant", "text": text, "images": images,
                    "timestamp": _timestamp_value(record.get("timestamp")),
                    "turnId": str(payload.get("turn_id", "")) or
                              str(record.get("timestamp", "")),
                })
        elif len(newest_first) < LOCAL_DETAIL_MESSAGE_LIMIT and is_user and \
                payload_type == "message" and str(payload.get("role", "")) == "user":
            text, images = _rollout_user_message(payload)
            if text or images:
                passthrough = payload.get("internal_chat_message_metadata_passthrough")
                turn_id = str(passthrough.get("turn_id", "")) \
                    if isinstance(passthrough, dict) else ""
                newest_first.append({
                    "role": "user", "text": text, "images": images,
                    "timestamp": _timestamp_value(record.get("timestamp")),
                    "turnId": turn_id or str(record.get("timestamp", "")),
                })
        if len(newest_first) >= LOCAL_DETAIL_MESSAGE_LIMIT and latest_task_event:
            break

    messages = list(reversed(newest_first))
    status = "active" if latest_task_event == "task_started" else "idle"
    normalized = normalize_thread({
        "id": thread_id,
        "name": meta.get("title", ""),
        "preview": meta.get("preview", ""),
        "status": status,
        "cwd": meta.get("cwd", ""),
        "updatedAt": meta.get("updatedAt", 0),
    })
    normalized["messages"] = messages
    normalized["activeTurnId"] = latest_turn_id if status == "active" else ""
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

    async def snapshot(self) -> JsonObject:
        last_error: Exception | None = None
        for attempt in range(2):
            try:
                rate, usage, threads = await asyncio.gather(
                    self.request("account/rateLimits/read"),
                    self.request("account/usage/read"),
                    self.request("thread/list", {"limit": 30, "archived": False}),
                )
                snapshot = normalize_snapshot(rate, usage, threads)
                for thread in snapshot["threads"]:
                    thread_id = str(thread.get("id", ""))
                    if thread_id:
                        self.thread_metadata[thread_id] = dict(thread)
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

    async def thread_detail(self, thread_id: str) -> JsonObject:
        local_detail = await asyncio.to_thread(
            read_rollout_thread_detail, thread_id, self.thread_metadata.get(thread_id))
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
        return self._normalize_thread_detail(thread)

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
                        messages.append({
                            "role": role,
                            "text": text.strip(),
                            "images": images,
                            "timestamp": timestamp,
                            "turnId": str(turn.get("id", "")),
                        })
        normalized["messages"] = messages
        normalized["activeTurnId"] = active_turn_id
        if active_turn_id:
            normalized["status"] = "active"
        elif normalized["status"] != "systemError":
            normalized["status"] = "idle"
        self.thread_status[str(normalized.get("id", ""))] = normalized["status"]
        return normalized

    async def send_message(self, thread_id: str, text: str) -> JsonObject:
        # thread/list and thread/read can see persisted history without loading
        # it into this app-server process. turn/start only accepts a running or
        # resumed thread, so restore the selected history first.
        async with self._thread_lock(thread_id):
            resumed = await self.request("thread/resume", {"threadId": thread_id}, timeout=30)
            thread = resumed.get("thread")
            if not isinstance(thread, dict):
                raise RuntimeError("Codex 没有返回恢复后的任务")
            detail = self._normalize_thread_detail(thread)
            input_items = [{"type": "text", "text": text}]
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
                }, timeout=30)
            self.thread_status[thread_id] = "active"
            return result

    def _thread_lock(self, thread_id: str) -> asyncio.Lock:
        lock = self.thread_locks.get(thread_id)
        if lock is None:
            lock = asyncio.Lock()
            self.thread_locks[thread_id] = lock
        return lock

    async def interrupt(self, thread_id: str, turn_id: str) -> JsonObject:
        return await self.request("turn/interrupt", {"threadId": thread_id, "turnId": turn_id})

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
                if method in ("item/commandExecution/requestApproval", "item/fileChange/requestApproval"):
                    await self._write({"id": request_id, "result": {"decision": "decline"}})
                elif method == "item/permissions/requestApproval":
                    await self._write({"id": request_id, "result": {"permissions": {}}})
                else:
                    await self._write({
                        "id": request_id,
                        "error": {"code": -32001, "message": "Starly 暂不支持此交互确认，请在电脑端完成"},
                    })
                if isinstance(params, dict) and self.event_callback:
                    asyncio.create_task(self.event_callback(method, params))
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
