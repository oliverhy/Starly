from __future__ import annotations

import asyncio
import json
import os
import shutil
from pathlib import Path
from typing import Any, Awaitable, Callable


JsonObject = dict[str, Any]
EventCallback = Callable[[str, JsonObject], Awaitable[None]]


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


def _item_text(item: JsonObject) -> tuple[str, str]:
    item_type = str(item.get("type", ""))
    if item_type == "agentMessage":
        return "assistant", str(item.get("text", ""))
    if item_type == "userMessage":
        content = item.get("content")
        parts: list[str] = []
        if isinstance(content, list):
            for value in content:
                if isinstance(value, dict) and value.get("type") in ("text", "inputText"):
                    parts.append(str(value.get("text", "")))
        return "user", "\n".join(parts)
    return "", ""


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
        if process and process.returncode is None:
            process.terminate()
            try:
                await asyncio.wait_for(process.wait(), timeout=2)
            except asyncio.TimeoutError:
                process.kill()
        for task in (self.reader_task, self.stderr_task):
            if task:
                task.cancel()
        self.reader_task = None
        self.stderr_task = None

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
        try:
            rate, usage, threads = await asyncio.gather(
                self.request("account/rateLimits/read"),
                self.request("account/usage/read"),
                self.request("thread/list", {"limit": 30, "archived": False}),
            )
            return normalize_snapshot(rate, usage, threads)
        except Exception as error:
            return {"available": False, "error": str(error), "quota": {}, "threads": []}

    async def thread_detail(self, thread_id: str) -> JsonObject:
        response = await self.request("thread/read", {"threadId": thread_id, "includeTurns": True})
        thread = response.get("thread")
        if not isinstance(thread, dict):
            raise RuntimeError("Codex 没有返回任务详情")
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
                items = turn.get("items")
                if not isinstance(items, list):
                    continue
                for item in items:
                    if not isinstance(item, dict):
                        continue
                    role, text = _item_text(item)
                    if role and text.strip():
                        messages.append({"role": role, "text": text.strip()[:2000]})
        normalized["messages"] = messages[-12:]
        normalized["activeTurnId"] = active_turn_id
        return normalized

    async def send_message(self, thread_id: str, text: str) -> JsonObject:
        detail = await self.thread_detail(thread_id)
        input_items = [{"type": "text", "text": text}]
        active_turn_id = str(detail.get("activeTurnId", ""))
        if active_turn_id:
            result = await self.request("turn/steer", {
                "threadId": thread_id,
                "expectedTurnId": active_turn_id,
                "input": input_items,
            })
        else:
            result = await self.request("turn/start", {"threadId": thread_id, "input": input_items})
        return result

    async def interrupt(self, thread_id: str, turn_id: str) -> JsonObject:
        return await self.request("turn/interrupt", {"threadId": thread_id, "turnId": turn_id})

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
                        future.set_exception(RuntimeError(str(message["error"])))
                    else:
                        result = message.get("result")
                        future.set_result(result if isinstance(result, dict) else {})
                continue
            method = str(message.get("method", ""))
            params = message.get("params")
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
                    await self.event_callback(method, params)
                continue
            if method and isinstance(params, dict) and self.event_callback:
                await self.event_callback(method, params)

    async def _drain_stderr(self) -> None:
        assert self.process and self.process.stderr
        while await self.process.stderr.readline():
            pass
