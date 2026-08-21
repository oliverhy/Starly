from __future__ import annotations

import json
import os
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable

try:
    from pc.secret_store import protect_secret, unprotect_secret
except ImportError:
    from secret_store import protect_secret, unprotect_secret


QUEUE_STATES = {
    "queued", "running", "waiting_unlock", "completed", "failed", "canceled",
}
TERMINAL_STATES = {"completed", "failed", "canceled"}
ACTIVE_STATES = {"running", "waiting_unlock"}


def _now_seconds() -> int:
    return int(time.time())


@dataclass
class CodexQueueItem:
    queue_id: str
    thread_id: str
    text: str
    image_data: str = ""
    submit_mode: str = "enter"
    model: str = ""
    effort: str = ""
    permission_mode: str = "default"
    service_tier: str = ""
    delivery_mode: str = "background"
    state: str = "queued"
    enqueued_at: int = field(default_factory=_now_seconds)
    started_at: int = 0
    completed_at: int = 0
    error: str = ""
    protected_payload: str = field(default="", repr=False)

    @property
    def has_image(self) -> bool:
        return bool(self.image_data)

    def public(self, position: int = 0) -> dict[str, object]:
        return {
            "queueId": self.queue_id,
            "threadId": self.thread_id,
            "text": self.text,
            "hasImage": self.has_image,
            "state": self.state,
            "position": position,
            "enqueuedAt": self.enqueued_at,
            "startedAt": self.started_at,
            "completedAt": self.completed_at,
            "error": self.error,
        }

    def sensitive_payload(self) -> dict[str, str]:
        return {
            "text": self.text,
            "imageData": self.image_data,
            "submitMode": self.submit_mode,
            "model": self.model,
            "effort": self.effort,
            "permissionMode": self.permission_mode,
            "serviceTier": self.service_tier,
            "deliveryMode": self.delivery_mode,
        }


class CodexQueueStore:
    """Persistent FIFO state; task bodies are encrypted by Windows DPAPI."""

    VERSION = 1

    def __init__(
        self,
        path: Path,
        protect: Callable[[str], str] = protect_secret,
        unprotect: Callable[[str], str] = unprotect_secret,
        terminal_limit: int = 100,
    ) -> None:
        self.path = path
        self.protect = protect
        self.unprotect = unprotect
        self.terminal_limit = max(0, terminal_limit)
        self.items: list[CodexQueueItem] = []
        self.load()

    def load(self) -> None:
        self.items = []
        try:
            document = json.loads(self.path.read_text(encoding="utf-8"))
        except (FileNotFoundError, OSError, UnicodeError, json.JSONDecodeError):
            return
        records = document.get("items") if isinstance(document, dict) else None
        if not isinstance(records, list):
            return
        seen: set[str] = set()
        changed = False
        for record in records:
            if not isinstance(record, dict):
                changed = True
                continue
            queue_id = str(record.get("queueId", "")).strip()
            thread_id = str(record.get("threadId", "")).strip()
            protected_payload = str(record.get("payloadProtected", ""))
            state = str(record.get("state", "queued"))
            if (not queue_id or not thread_id or queue_id in seen or
                    not protected_payload or state not in QUEUE_STATES):
                changed = True
                continue
            try:
                payload = json.loads(self.unprotect(protected_payload))
            except (OSError, ValueError, TypeError, json.JSONDecodeError, RuntimeError):
                changed = True
                continue
            if not isinstance(payload, dict):
                changed = True
                continue
            item = CodexQueueItem(
                queue_id=queue_id,
                thread_id=thread_id,
                text=str(payload.get("text", "")),
                image_data=str(payload.get("imageData", "")),
                submit_mode=str(payload.get("submitMode", "enter")),
                model=str(payload.get("model", "")),
                effort=str(payload.get("effort", "")),
                permission_mode=str(payload.get("permissionMode", "default")),
                service_tier=str(payload.get("serviceTier", "")),
                delivery_mode=str(payload.get("deliveryMode", "background")),
                state=state,
                enqueued_at=int(record.get("enqueuedAt", 0) or 0) or _now_seconds(),
                started_at=int(record.get("startedAt", 0) or 0),
                completed_at=int(record.get("completedAt", 0) or 0),
                error=str(record.get("error", "")),
                protected_payload=protected_payload,
            )
            self.items.append(item)
            seen.add(queue_id)
        if self._prune_terminal_items():
            changed = True
        if changed:
            self.save()

    def save(self) -> None:
        self._prune_terminal_items()
        records: list[dict[str, object]] = []
        for item in self.items:
            if not item.protected_payload:
                raw_payload = json.dumps(
                    item.sensitive_payload(), ensure_ascii=False, separators=(",", ":"))
                item.protected_payload = self.protect(raw_payload)
            records.append({
                "queueId": item.queue_id,
                "threadId": item.thread_id,
                "state": item.state,
                "enqueuedAt": item.enqueued_at,
                "startedAt": item.started_at,
                "completedAt": item.completed_at,
                "error": item.error,
                "payloadProtected": item.protected_payload,
            })
        self.path.parent.mkdir(parents=True, exist_ok=True)
        temporary = self.path.with_suffix(self.path.suffix + ".tmp")
        temporary.write_text(json.dumps({
            "version": self.VERSION,
            "items": records,
        }, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
        os.replace(temporary, self.path)

    def enqueue(self, item: CodexQueueItem) -> tuple[CodexQueueItem, bool]:
        existing = self.get(item.queue_id)
        if existing is not None:
            return existing, False
        if not item.queue_id or not item.thread_id:
            raise ValueError("queueId and threadId are required")
        if item.state not in QUEUE_STATES:
            raise ValueError("invalid queue state")
        self.items.append(item)
        self.save()
        return item, True

    def get(self, queue_id: str) -> CodexQueueItem | None:
        return next((item for item in self.items if item.queue_id == queue_id), None)

    def threads_with_pending(self) -> list[str]:
        return list(dict.fromkeys(
            item.thread_id for item in self.items if item.state not in TERMINAL_STATES))

    def next_for_thread(self, thread_id: str) -> CodexQueueItem | None:
        for item in self.items:
            if item.thread_id == thread_id and item.state in ACTIVE_STATES:
                return item
        return next((item for item in self.items
                     if item.thread_id == thread_id and item.state == "queued"), None)

    def transition(self, queue_id: str, state: str, error: str = "") -> CodexQueueItem:
        if state not in QUEUE_STATES:
            raise ValueError("invalid queue state")
        item = self.get(queue_id)
        if item is None:
            raise KeyError(queue_id)
        now = _now_seconds()
        item.state = state
        item.error = error
        if state == "queued":
            item.started_at = 0
            item.completed_at = 0
        elif state == "running":
            item.started_at = item.started_at or now
            item.completed_at = 0
        elif state in TERMINAL_STATES:
            item.completed_at = now
        self.save()
        return item

    def cancel(self, queue_id: str) -> tuple[CodexQueueItem | None, bool]:
        item = self.get(queue_id)
        if item is None:
            return None, False
        if item.state not in ("queued", "waiting_unlock"):
            return item, False
        return self.transition(queue_id, "canceled"), True

    def position(self, target: CodexQueueItem) -> int:
        if target.state in ACTIVE_STATES:
            return 0
        if target.state != "queued":
            return 0
        position = 0
        for item in self.items:
            if item.thread_id != target.thread_id or item.state != "queued":
                continue
            position += 1
            if item is target:
                return position
        return 0

    def public_item(self, item: CodexQueueItem) -> dict[str, object]:
        return item.public(self.position(item))

    def snapshot(self) -> list[dict[str, object]]:
        return [self.public_item(item) for item in self.items]

    def _prune_terminal_items(self) -> bool:
        terminal = [item for item in self.items if item.state in TERMINAL_STATES]
        excess = len(terminal) - self.terminal_limit
        if excess <= 0:
            return False
        remove_ids = {id(item) for item in terminal[:excess]}
        self.items = [item for item in self.items if id(item) not in remove_ids]
        return True
