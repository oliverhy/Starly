from __future__ import annotations

import asyncio
import json
import random
from collections.abc import Awaitable, Callable
from typing import Any

import websockets

try:
    from pc.gateway_crypto import GatewayCrypto, ReplayMessageError
except ImportError:
    from gateway_crypto import GatewayCrypto, ReplayMessageError


JsonObject = dict[str, Any]
PayloadHandler = Callable[[JsonObject, str], Awaitable[None]]
StateHandler = Callable[[bool, str], None]
SequenceHandler = Callable[[int], None]
SessionHandler = Callable[[str], None]
CredentialHandler = Callable[[str], None]
ControlHandler = Callable[[JsonObject], Awaitable[None]]


class GatewayBridgeClient:
    """Persistent outbound connection from StarlyBridge to Starly Gateway."""

    def __init__(self, url: str, pairing_id: str, device_id: str, token: str,
                 payload_handler: PayloadHandler, state_handler: StateHandler,
                 last_received_seq: int = 0,
                 sequence_handler: SequenceHandler | None = None,
                 crypto: GatewayCrypto | None = None,
                 device_public_key: str = "", session_token: str = "",
                 session_handler: SessionHandler | None = None,
                 device_credential: str = "",
                 credential_handler: CredentialHandler | None = None,
                 control_handler: ControlHandler | None = None) -> None:
        self.url = url
        self.pairing_id = pairing_id
        self.device_id = device_id
        self.token = token
        self.payload_handler = payload_handler
        self.state_handler = state_handler
        self.last_received_seq = max(0, last_received_seq)
        self.sequence_handler = sequence_handler
        self.crypto = crypto
        self.device_public_key = device_public_key
        self.session_token = session_token
        self.session_handler = session_handler
        self.device_credential = device_credential
        self.credential_handler = credential_handler
        self.control_handler = control_handler
        self.connection: websockets.ClientConnection | None = None
        self.send_lock = asyncio.Lock()
        self.stop_event = asyncio.Event()
        self.pending_sends: dict[str, str] = {}
        self.retry_task: asyncio.Task[None] | None = None

    async def run(self) -> None:
        delay = 1.0
        while not self.stop_event.is_set():
            try:
                async with websockets.connect(
                    self.url, max_size=16 * 1024 * 1024,
                    ping_interval=20, ping_timeout=20,
                ) as connection:
                    self.connection = connection
                    auth_message = {
                        "type": "gateway_auth",
                        "protocol": 1,
                        "role": "bridge",
                        "pairingId": self.pairing_id,
                        "deviceId": self.device_id,
                        "devicePublicKey": self.device_public_key,
                        "lastReceivedSeq": self.last_received_seq,
                    }
                    if self.session_token:
                        auth_message["sessionToken"] = self.session_token
                    elif self.device_credential:
                        auth_message["deviceCredential"] = self.device_credential
                    else:
                        auth_message["token"] = self.token
                    await connection.send(json.dumps(
                        auth_message, ensure_ascii=False, separators=(",", ":")))
                    raw_ready = await asyncio.wait_for(connection.recv(), timeout=10)
                    ready = json.loads(raw_ready) if isinstance(raw_ready, str) else {}
                    if ready.get("type") != "gateway_ready":
                        raise RuntimeError("Gateway rejected the bridge connection")
                    if self.crypto and isinstance(ready.get("knownPeerDevices"), list):
                        self.crypto.update_peer_public_keys(ready["knownPeerDevices"])
                    if self.control_handler:
                        await self.control_handler({
                            "type": "gateway_peer_snapshot",
                            "peerOnline": bool(ready.get("peerOnline", False)),
                            "peerDevices": ready.get("peerDevices", []),
                            "knownPeerDevices": ready.get("knownPeerDevices", []),
                        })
                    renewed_session = str(ready.get("sessionToken", ""))
                    if renewed_session:
                        self.session_token = renewed_session
                        if self.session_handler:
                            self.session_handler(renewed_session)
                    renewed_credential = str(ready.get("deviceCredential", ""))
                    if renewed_credential:
                        self.device_credential = renewed_credential
                        if self.credential_handler:
                            self.credential_handler(renewed_credential)
                    delay = 1.0
                    self.state_handler(True, "公网 Gateway 已连接")
                    await self._resend_pending()
                    async for raw in connection:
                        await self._handle(raw)
            except asyncio.CancelledError:
                raise
            except Exception as error:
                self.state_handler(False, f"公网 Gateway 已断开：{error}")
                if self.session_token:
                    self.session_token = ""
                    if self.session_handler:
                        self.session_handler("")
            finally:
                self.connection = None
            if self.stop_event.is_set():
                break
            wait = delay + random.random() * min(1.0, delay / 4)
            try:
                await asyncio.wait_for(self.stop_event.wait(), timeout=wait)
            except asyncio.TimeoutError:
                pass
            delay = min(delay * 2, 30.0)

    async def stop(self) -> None:
        self.stop_event.set()
        retry_task = self.retry_task
        self.retry_task = None
        if retry_task is not None:
            retry_task.cancel()
            await asyncio.gather(retry_task, return_exceptions=True)
        connection = self.connection
        if connection is not None:
            await connection.close()

    async def send_payload(self, payload: JsonObject,
                           client_message_id: str = "",
                           target_device_id: str = "") -> None:
        connection = self.connection
        if connection is None:
            raise RuntimeError("公网 Gateway 当前未连接")
        wire_payload = (self.crypto.encrypt(payload, target_device_id)
                        if self.crypto else payload)
        message = {
            "type": "gateway_send",
            "clientMessageId": client_message_id,
            "payload": wire_payload,
        }
        if target_device_id:
            message["targetDeviceId"] = target_device_id
        wire = json.dumps(message, ensure_ascii=False, separators=(",", ":"))
        if client_message_id:
            self.pending_sends[client_message_id] = wire
            self._ensure_retry_task()
        await self._send_wire(connection, wire)

    async def send_control(self, message: JsonObject) -> None:
        connection = self.connection
        if connection is None:
            raise RuntimeError("Gateway is not connected")
        await self._send_wire(connection, json.dumps(
            message, ensure_ascii=False, separators=(",", ":")))

    async def _handle(self, raw: str | bytes) -> None:
        if not isinstance(raw, str):
            return
        try:
            message = json.loads(raw)
        except json.JSONDecodeError:
            return
        if not isinstance(message, dict):
            return
        if message.get("type") == "gateway_accepted":
            client_message_id = str(message.get("clientMessageId", ""))
            if client_message_id:
                self.pending_sends.pop(client_message_id, None)
            return
        message_type = str(message.get("type", ""))
        if (message_type.startswith("gateway_pairing_") or
                message_type in ("gateway_presence", "gateway_devices")):
            if self.control_handler:
                await self.control_handler(message)
            return
        if message.get("type") != "gateway_message":
            return
        payload = message.get("payload")
        if not isinstance(payload, dict):
            return
        try:
            seq = int(message.get("seq", 0))
        except (TypeError, ValueError):
            seq = 0
        if seq > 0 and seq <= self.last_received_seq:
            await self._ack(seq)
            return
        source_device_id = str(message.get("fromDeviceId", ""))
        source_public_key = str(message.get("fromDevicePublicKey", ""))
        if self.crypto and source_device_id and source_public_key:
            self.crypto.update_peer_public_keys([{
                "deviceId": source_device_id, "publicKey": source_public_key,
            }])
        try:
            clear_payload = self.crypto.decrypt(payload) if self.crypto else payload
        except ReplayMessageError:
            # The Gateway may assign a new relay sequence when it replays a
            # phone message that this bridge already authenticated and handled.
            # Acknowledge that relay sequence without executing the payload a
            # second time, otherwise reconnecting repeats the same cached item
            # forever and makes both devices appear offline.
            if seq > 0:
                self.last_received_seq = max(self.last_received_seq, seq)
                if self.sequence_handler:
                    self.sequence_handler(self.last_received_seq)
                await self._ack(seq)
            return
        await self.payload_handler(clear_payload, source_device_id)
        if seq > 0:
            self.last_received_seq = seq
            if self.sequence_handler:
                self.sequence_handler(seq)
            await self._ack(seq)

    async def _ack(self, seq: int) -> None:
        connection = self.connection
        if connection is None:
            return
        async with self.send_lock:
            await connection.send(json.dumps({
                "type": "gateway_ack", "seq": seq,
            }, separators=(",", ":")))

    async def _send_wire(self, connection: websockets.ClientConnection, wire: str) -> None:
        async with self.send_lock:
            await connection.send(wire)

    async def _resend_pending(self) -> None:
        connection = self.connection
        if connection is None or not self.pending_sends:
            return
        for wire in list(self.pending_sends.values()):
            await self._send_wire(connection, wire)
        self._ensure_retry_task()

    def _ensure_retry_task(self) -> None:
        if self.retry_task is None or self.retry_task.done():
            self.retry_task = asyncio.create_task(self._retry_pending_loop())

    async def _retry_pending_loop(self) -> None:
        try:
            while self.pending_sends and not self.stop_event.is_set():
                await asyncio.sleep(3)
                connection = self.connection
                if connection is None:
                    continue
                for wire in list(self.pending_sends.values()):
                    await self._send_wire(connection, wire)
        except (asyncio.CancelledError, websockets.ConnectionClosed):
            pass
        finally:
            self.retry_task = None


class GatewayRelayConnection:
    """BridgeServer-compatible response channel backed by Gateway."""

    def __init__(self, client: GatewayBridgeClient, target_device_id: str = "") -> None:
        self.client = client
        self.target_device_id = target_device_id
        self.remote_address = ("gateway", 0)

    async def send(self, raw: str) -> None:
        payload = json.loads(raw)
        if not isinstance(payload, dict):
            raise RuntimeError("Bridge response must be a JSON object")
        await self.client.send_payload(
            payload, str(payload.get("id", "")), self.target_device_id)
