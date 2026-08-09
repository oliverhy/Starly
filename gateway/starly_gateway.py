from __future__ import annotations

import asyncio
import base64
import hashlib
import hmac
import ipaddress
import json
import os
import secrets
import sqlite3
import time
import urllib.parse
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import websockets


PROTOCOL_VERSION = 1
DEFAULT_HOST = "127.0.0.1"
DEFAULT_PORT = 8780
DEFAULT_MESSAGE_TTL_SECONDS = 24 * 60 * 60
DEFAULT_MAX_MESSAGE_BYTES = 16 * 1024 * 1024
AUTH_TIMEOUT_SECONDS = 10
MAX_CONNECTIONS_PER_DEVICE = 2
SESSION_TTL_SECONDS = 60 * 60
PAIRING_TTL_SECONDS = 2 * 60
PAIRING_MAX_ATTEMPTS = 5
PAIRING_CODE_ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"


JsonObject = dict[str, Any]


def _now() -> int:
    return int(time.time())


def _token_hash(token: str) -> str:
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


def _pairing_code() -> str:
    raw = "".join(secrets.choice(PAIRING_CODE_ALPHABET) for _ in range(8))
    return f"{raw[:4]}-{raw[4:]}"


def _normalize_pairing_code(value: str) -> str:
    return "".join(character for character in value.upper() if character.isalnum())


def load_pairings(path: Path) -> dict[str, str]:
    """Load pairingId -> SHA-256(token) without retaining plaintext tokens."""
    if not path.exists():
        raise RuntimeError(f"Gateway pairing file does not exist: {path}")
    raw = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(raw, dict):
        raise RuntimeError("Gateway pairing file must contain a JSON object")
    result: dict[str, str] = {}
    for pairing_id, value in raw.items():
        if not isinstance(pairing_id, str) or not pairing_id.strip():
            raise RuntimeError("Gateway pairing IDs must be non-empty strings")
        token = ""
        token_hash = ""
        if isinstance(value, str):
            token = value
        elif isinstance(value, dict):
            token = str(value.get("token", ""))
            token_hash = str(value.get("tokenSha256", ""))
        if token:
            if len(token) < 32:
                raise RuntimeError(f"Pairing token for {pairing_id} is too short")
            token_hash = _token_hash(token)
        if len(token_hash) != 64:
            raise RuntimeError(f"Pairing {pairing_id} needs token or tokenSha256")
        result[pairing_id] = token_hash.lower()
    if not result:
        raise RuntimeError("Gateway pairing file is empty")
    return result


class GatewayStore:
    def __init__(self, path: Path, message_ttl_seconds: int = DEFAULT_MESSAGE_TTL_SECONDS) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        self.connection = sqlite3.connect(path)
        self.connection.row_factory = sqlite3.Row
        self.message_ttl_seconds = message_ttl_seconds
        self.connection.executescript(
            """
            PRAGMA journal_mode=WAL;
            CREATE TABLE IF NOT EXISTS pair_sequences (
                pairing_id TEXT PRIMARY KEY,
                next_seq INTEGER NOT NULL
            );
            CREATE TABLE IF NOT EXISTS devices (
                pairing_id TEXT NOT NULL,
                device_id TEXT NOT NULL,
                role TEXT NOT NULL,
                public_key TEXT NOT NULL DEFAULT '',
                display_name TEXT NOT NULL DEFAULT '',
                revoked_at INTEGER NOT NULL DEFAULT 0,
                last_acked_seq INTEGER NOT NULL DEFAULT 0,
                last_seen_at INTEGER NOT NULL,
                PRIMARY KEY (pairing_id, device_id)
            );
            CREATE TABLE IF NOT EXISTS device_credentials (
                pairing_id TEXT NOT NULL,
                device_id TEXT NOT NULL,
                role TEXT NOT NULL,
                credential_hash TEXT NOT NULL,
                issued_at INTEGER NOT NULL,
                revoked_at INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (pairing_id, device_id)
            );
            CREATE TABLE IF NOT EXISTS bootstrap_claims (
                pairing_id TEXT NOT NULL,
                role TEXT NOT NULL,
                device_id TEXT NOT NULL,
                claimed_at INTEGER NOT NULL,
                PRIMARY KEY (pairing_id, role)
            );
            CREATE TABLE IF NOT EXISTS messages (
                pairing_id TEXT NOT NULL,
                seq INTEGER NOT NULL,
                source_device_id TEXT NOT NULL,
                client_message_id TEXT NOT NULL DEFAULT '',
                target_role TEXT NOT NULL,
                target_device_id TEXT NOT NULL DEFAULT '',
                payload TEXT NOT NULL,
                created_at INTEGER NOT NULL,
                expires_at INTEGER NOT NULL,
                PRIMARY KEY (pairing_id, seq)
            );
            CREATE INDEX IF NOT EXISTS messages_replay
                ON messages(pairing_id, target_role, seq);
            """
        )
        columns = {str(row["name"]) for row in self.connection.execute(
            "PRAGMA table_info(messages)").fetchall()}
        if "client_message_id" not in columns:
            self.connection.execute(
                "ALTER TABLE messages ADD COLUMN client_message_id TEXT NOT NULL DEFAULT ''")
        if "target_device_id" not in columns:
            self.connection.execute(
                "ALTER TABLE messages ADD COLUMN target_device_id TEXT NOT NULL DEFAULT ''")
        device_columns = {str(row["name"]) for row in self.connection.execute(
            "PRAGMA table_info(devices)").fetchall()}
        for name, definition in (
                ("public_key", "TEXT NOT NULL DEFAULT ''"),
                ("display_name", "TEXT NOT NULL DEFAULT ''"),
                ("revoked_at", "INTEGER NOT NULL DEFAULT 0")):
            if name not in device_columns:
                self.connection.execute(f"ALTER TABLE devices ADD COLUMN {name} {definition}")
        self.connection.execute(
            """CREATE UNIQUE INDEX IF NOT EXISTS messages_client_dedup
               ON messages(pairing_id, source_device_id, client_message_id)
               WHERE client_message_id<>''""")
        # Databases upgraded from an earlier release may already contain an
        # enrolled PC. Mark its bootstrap as consumed so revoking that PC never
        # re-enables the original server Token.
        self.connection.execute(
            """INSERT OR IGNORE INTO bootstrap_claims(pairing_id, role, device_id, claimed_at)
               SELECT pairing_id, role, device_id, issued_at
               FROM device_credentials WHERE role='bridge' AND revoked_at=0""")
        self.connection.commit()

    def close(self) -> None:
        self.connection.close()

    def register_device(self, pairing_id: str, device_id: str, role: str,
                        last_received_seq: int, public_key: str = "") -> int:
        row = self.connection.execute(
            """SELECT last_acked_seq, public_key, revoked_at FROM devices
               WHERE pairing_id=? AND device_id=?""",
            (pairing_id, device_id),
        ).fetchone()
        if row and int(row["revoked_at"] or 0) > 0:
            raise ValueError("device has been revoked")
        remembered_key = str(row["public_key"] or "") if row else ""
        if remembered_key and public_key and not hmac.compare_digest(remembered_key, public_key):
            raise ValueError("device public key changed")
        remembered = int(row["last_acked_seq"]) if row else 0
        acknowledged = max(remembered, max(0, last_received_seq))
        self.connection.execute(
            """
            INSERT INTO devices(pairing_id, device_id, role, public_key,
                                last_acked_seq, last_seen_at)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(pairing_id, device_id) DO UPDATE SET
                role=excluded.role,
                public_key=CASE WHEN devices.public_key='' THEN excluded.public_key
                                ELSE devices.public_key END,
                last_acked_seq=MAX(devices.last_acked_seq, excluded.last_acked_seq),
                last_seen_at=excluded.last_seen_at
            """,
            (pairing_id, device_id, role, public_key, acknowledged, _now()),
        )
        self.connection.commit()
        return acknowledged

    def enqueue(self, pairing_id: str, source_device_id: str,
                target_role: str, payload: JsonObject,
                client_message_id: str = "", target_device_id: str = "") -> tuple[int, bool]:
        self.cleanup()
        self.connection.execute("BEGIN IMMEDIATE")
        try:
            if client_message_id:
                existing = self.connection.execute(
                    """SELECT seq FROM messages
                       WHERE pairing_id=? AND source_device_id=? AND client_message_id=?""",
                    (pairing_id, source_device_id, client_message_id),
                ).fetchone()
                if existing:
                    self.connection.commit()
                    return int(existing["seq"]), False
            row = self.connection.execute(
                "SELECT next_seq FROM pair_sequences WHERE pairing_id=?", (pairing_id,)
            ).fetchone()
            seq = int(row["next_seq"]) if row else 1
            self.connection.execute(
                """
                INSERT INTO pair_sequences(pairing_id, next_seq) VALUES (?, ?)
                ON CONFLICT(pairing_id) DO UPDATE SET next_seq=excluded.next_seq
                """,
                (pairing_id, seq + 1),
            )
            now = _now()
            self.connection.execute(
                """
                INSERT INTO messages(pairing_id, seq, source_device_id, client_message_id,
                                     target_role, target_device_id, payload, created_at, expires_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (pairing_id, seq, source_device_id, client_message_id, target_role,
                 target_device_id,
                 json.dumps(payload, ensure_ascii=False, separators=(",", ":")),
                 now, now + self.message_ttl_seconds),
            )
            self.connection.commit()
            return seq, True
        except Exception:
            self.connection.rollback()
            raise

    def acknowledge(self, pairing_id: str, device_id: str, seq: int) -> None:
        self.connection.execute(
            """
            UPDATE devices SET last_acked_seq=MAX(last_acked_seq, ?), last_seen_at=?
            WHERE pairing_id=? AND device_id=?
            """,
            (max(0, seq), _now(), pairing_id, device_id),
        )
        self.connection.commit()

    def replay(self, pairing_id: str, target_role: str, target_device_id: str,
               after_seq: int) -> list[JsonObject]:
        self.cleanup()
        rows = self.connection.execute(
            """
            SELECT seq, source_device_id, payload, created_at
            FROM messages
            WHERE pairing_id=? AND target_role=?
              AND (target_device_id='' OR target_device_id=?)
              AND seq>? AND expires_at>?
            ORDER BY seq ASC
            """,
            (pairing_id, target_role, target_device_id, max(0, after_seq), _now()),
        ).fetchall()
        return [{
            "seq": int(row["seq"]),
            "sourceDeviceId": str(row["source_device_id"]),
            "payload": json.loads(str(row["payload"])),
            "createdAt": int(row["created_at"]),
        } for row in rows]

    def devices(self, pairing_id: str, role: str) -> list[JsonObject]:
        rows = self.connection.execute(
            """SELECT device_id, role, public_key, display_name, last_seen_at FROM devices
               WHERE pairing_id=? AND role=? AND revoked_at=0 ORDER BY last_seen_at DESC""",
            (pairing_id, role),
        ).fetchall()
        return [{
            "deviceId": str(row["device_id"]),
            "role": str(row["role"]),
            "publicKey": str(row["public_key"]),
            "displayName": str(row["display_name"]),
            "lastSeenAt": int(row["last_seen_at"]),
        } for row in rows]

    def device_exists(self, pairing_id: str, device_id: str, role: str) -> bool:
        return self.connection.execute(
            """SELECT 1 FROM devices WHERE pairing_id=? AND device_id=? AND role=?
               AND revoked_at=0""",
            (pairing_id, device_id, role),
        ).fetchone() is not None

    def has_role(self, pairing_id: str, role: str) -> bool:
        return self.connection.execute(
            """SELECT 1 FROM devices WHERE pairing_id=? AND role=? AND revoked_at=0 LIMIT 1""",
            (pairing_id, role),
        ).fetchone() is not None

    def issue_device_credential(self, pairing_id: str, device_id: str, role: str) -> str:
        credential = secrets.token_urlsafe(32)
        self.connection.execute(
            """
            INSERT INTO device_credentials(pairing_id, device_id, role, credential_hash,
                                           issued_at, revoked_at)
            VALUES (?, ?, ?, ?, ?, 0)
            ON CONFLICT(pairing_id, device_id) DO UPDATE SET
                role=excluded.role,
                credential_hash=excluded.credential_hash,
                issued_at=excluded.issued_at,
                revoked_at=0
            """,
            (pairing_id, device_id, role, _token_hash(credential), _now()),
        )
        self.connection.commit()
        return credential

    def validate_device_credential(self, pairing_id: str, device_id: str,
                                   role: str, credential: str) -> bool:
        if len(credential) < 32:
            return False
        row = self.connection.execute(
            """SELECT credential_hash FROM device_credentials
               WHERE pairing_id=? AND device_id=? AND role=? AND revoked_at=0""",
            (pairing_id, device_id, role),
        ).fetchone()
        return bool(row and hmac.compare_digest(
            str(row["credential_hash"]), _token_hash(credential)))

    def has_device_credential(self, pairing_id: str, device_id: str, role: str) -> bool:
        return self.connection.execute(
            """SELECT 1 FROM device_credentials
               WHERE pairing_id=? AND device_id=? AND role=? AND revoked_at=0""",
            (pairing_id, device_id, role),
        ).fetchone() is not None

    def bootstrap_claimed(self, pairing_id: str, role: str) -> bool:
        return self.connection.execute(
            "SELECT 1 FROM bootstrap_claims WHERE pairing_id=? AND role=?",
            (pairing_id, role),
        ).fetchone() is not None

    def claim_bootstrap(self, pairing_id: str, role: str, device_id: str) -> None:
        self.connection.execute(
            """INSERT OR IGNORE INTO bootstrap_claims(
                   pairing_id, role, device_id, claimed_at) VALUES (?, ?, ?, ?)""",
            (pairing_id, role, device_id, _now()),
        )
        self.connection.commit()

    def device_public_key(self, pairing_id: str, device_id: str) -> str:
        row = self.connection.execute(
            """SELECT public_key FROM devices WHERE pairing_id=? AND device_id=?
               AND revoked_at=0""", (pairing_id, device_id)).fetchone()
        return str(row["public_key"]) if row else ""

    def rename_device(self, pairing_id: str, device_id: str, display_name: str) -> bool:
        cursor = self.connection.execute(
            """UPDATE devices SET display_name=? WHERE pairing_id=? AND device_id=?
               AND revoked_at=0""", (display_name[:64], pairing_id, device_id))
        self.connection.commit()
        return cursor.rowcount > 0

    def revoke_device(self, pairing_id: str, device_id: str) -> bool:
        cursor = self.connection.execute(
            """UPDATE devices SET revoked_at=? WHERE pairing_id=? AND device_id=?
               AND revoked_at=0""", (_now(), pairing_id, device_id))
        self.connection.commit()
        self.connection.execute(
            """UPDATE device_credentials SET revoked_at=?
               WHERE pairing_id=? AND device_id=? AND revoked_at=0""",
            (_now(), pairing_id, device_id),
        )
        self.connection.commit()
        return cursor.rowcount > 0

    def cleanup(self) -> None:
        self.connection.execute("DELETE FROM messages WHERE expires_at<=?", (_now(),))
        self.connection.commit()


@dataclass(eq=False)
class ClientSession:
    connection: websockets.ServerConnection
    pairing_id: str
    device_id: str
    role: str
    last_acked_seq: int
    public_key: str = ""
    action_times: list[float] = field(default_factory=list)


@dataclass
class PublicPairingSession:
    session_id: str
    pairing_id: str
    bridge_device_id: str
    bridge_public_key: str
    secret_hash: str
    code: str
    expires_at: int
    attempts: int = 0
    request_id: str = ""
    phone_device_id: str = ""
    phone_public_key: str = ""
    phone_name: str = ""
    verification_code: str = ""
    phone_connection: websockets.ServerConnection | None = None


class StarlyGateway:
    def __init__(self, pairings: dict[str, str], store: GatewayStore,
                 max_message_bytes: int = DEFAULT_MAX_MESSAGE_BYTES) -> None:
        self.pairings = pairings
        self.store = store
        self.max_message_bytes = max_message_bytes
        self.sessions: set[ClientSession] = set()
        self.lock = asyncio.Lock()
        self.session_secret = secrets.token_bytes(32)
        self.auth_attempts: dict[str, list[float]] = {}
        self.pairing_attempts: dict[str, list[float]] = {}
        self.public_pairings: dict[str, PublicPairingSession] = {}

    @staticmethod
    def _remote_ip(connection: websockets.ServerConnection) -> str:
        remote = connection.remote_address
        remote_ip = str(remote[0]) if isinstance(remote, tuple) and remote else "unknown"
        # Only trust the address supplied by the local reverse proxy. Public
        # clients cannot override this because Nginx replaces X-Real-IP.
        try:
            is_local_proxy = ipaddress.ip_address(remote_ip).is_loopback
        except ValueError:
            is_local_proxy = False
        if not is_local_proxy:
            return remote_ip
        forwarded = str(connection.request.headers.get("X-Real-IP", "")).strip()
        try:
            return str(ipaddress.ip_address(forwarded)) if forwarded else remote_ip
        except ValueError:
            return remote_ip

    def _issue_session_token(self, pairing_id: str, device_id: str, role: str) -> str:
        payload = json.dumps({
            "pairingId": pairing_id, "deviceId": device_id, "role": role,
            "expiresAt": _now() + SESSION_TTL_SECONDS,
        }, separators=(",", ":")).encode("utf-8")
        signature = hmac.new(self.session_secret, payload, hashlib.sha256).digest()
        return (base64.urlsafe_b64encode(payload).decode("ascii").rstrip("=") + "." +
                base64.urlsafe_b64encode(signature).decode("ascii").rstrip("="))

    def _validate_session_token(self, value: str, pairing_id: str,
                                device_id: str, role: str) -> bool:
        try:
            encoded_payload, encoded_signature = value.split(".", 1)
            payload = base64.urlsafe_b64decode(encoded_payload + "=" * (-len(encoded_payload) % 4))
            signature = base64.urlsafe_b64decode(
                encoded_signature + "=" * (-len(encoded_signature) % 4))
            expected = hmac.new(self.session_secret, payload, hashlib.sha256).digest()
            claims = json.loads(payload)
            return (hmac.compare_digest(signature, expected) and
                    claims.get("pairingId") == pairing_id and
                    claims.get("deviceId") == device_id and claims.get("role") == role and
                    int(claims.get("expiresAt", 0)) > _now())
        except (ValueError, TypeError, json.JSONDecodeError):
            return False

    async def handle(self, connection: websockets.ServerConnection) -> None:
        request_url = urllib.parse.urlparse(connection.request.path)
        request_path = request_url.path
        if request_path == "/ws" and urllib.parse.parse_qs(
                request_url.query).get("pair", [""])[0] == "1":
            await self._handle_public_pairing_connection(connection)
            return
        if request_path != "/ws":
            await connection.close(code=4004, reason="unknown endpoint")
            return
        remote_ip = self._remote_ip(connection)
        now_monotonic = time.monotonic()
        attempts = [item for item in self.auth_attempts.get(remote_ip, [])
                    if now_monotonic - item < 60]
        if len(attempts) >= 20:
            await connection.close(code=4008, reason="authentication rate limit exceeded")
            return
        attempts.append(now_monotonic)
        self.auth_attempts[remote_ip] = attempts
        session: ClientSession | None = None
        try:
            raw = await asyncio.wait_for(connection.recv(), timeout=AUTH_TIMEOUT_SECONDS)
            session = await self._authenticate(connection, raw)
            if session is None:
                return
            async with self.lock:
                same_device = [item for item in self.sessions
                               if item.pairing_id == session.pairing_id and
                               item.device_id == session.device_id]
                if len(same_device) >= MAX_CONNECTIONS_PER_DEVICE:
                    await connection.close(code=4008, reason="too many device connections")
                    return
                self.sessions.add(session)
                peer_role = "bridge" if session.role == "phone" else "phone"
                peer_devices = sorted({item.device_id for item in self.sessions
                                       if item.pairing_id == session.pairing_id and
                                       item.role == peer_role})
            await self._send_json(connection, {
                "type": "gateway_ready",
                "protocol": PROTOCOL_VERSION,
                "pairingId": session.pairing_id,
                "deviceId": session.device_id,
                "lastAckedSeq": session.last_acked_seq,
                "peerOnline": len(peer_devices) > 0,
                "peerDevices": peer_devices,
                "knownPeerDevices": self.store.devices(session.pairing_id, peer_role),
                "sessionToken": self._issue_session_token(
                    session.pairing_id, session.device_id, session.role),
                "sessionExpiresIn": SESSION_TTL_SECONDS,
                "deviceCredential": getattr(session, "new_device_credential", ""),
            })
            await self._broadcast_presence(session, True)
            await self._replay(session)
            async for message in connection:
                await self._handle_message(session, message)
        except (asyncio.TimeoutError, websockets.ConnectionClosed):
            pass
        finally:
            if session is not None:
                async with self.lock:
                    self.sessions.discard(session)
                await self._broadcast_presence(session, False)

    async def _authenticate(self, connection: websockets.ServerConnection,
                            raw: str | bytes) -> ClientSession | None:
        if not isinstance(raw, str) or len(raw.encode("utf-8")) > 16 * 1024:
            await connection.close(code=4000, reason="invalid authentication message")
            return None
        try:
            message = json.loads(raw)
        except json.JSONDecodeError:
            await connection.close(code=4000, reason="invalid authentication message")
            return None
        if not isinstance(message, dict) or message.get("type") != "gateway_auth":
            await connection.close(code=4000, reason="authentication required")
            return None
        pairing_id = str(message.get("pairingId", "")).strip()
        device_id = str(message.get("deviceId", "")).strip()
        role = str(message.get("role", "")).strip()
        token = str(message.get("token", ""))
        device_credential = str(message.get("deviceCredential", ""))
        session_token = str(message.get("sessionToken", ""))
        public_key = str(message.get("devicePublicKey", "")).strip()
        if (role not in ("phone", "bridge") or not pairing_id or not device_id or
                len(pairing_id) > 128 or len(device_id) > 128):
            await connection.close(code=4000, reason="invalid device identity")
            return None
        expected_hash = self.pairings.get(pairing_id, "")
        valid_session = self._validate_session_token(
            session_token, pairing_id, device_id, role) if session_token else False
        valid_credential = self.store.validate_device_credential(
            pairing_id, device_id, role, device_credential)
        valid_legacy = bool(expected_hash and token and hmac.compare_digest(
            _token_hash(token), expected_hash))
        device_exists = self.store.device_exists(pairing_id, device_id, role)
        # The server token is a one-time PC bootstrap credential. Phones must
        # use the short-lived public pairing flow. Legacy known devices may use
        # it once only to migrate to a device-specific credential.
        needs_credential_migration = (device_exists and
                                      not self.store.has_device_credential(
                                          pairing_id, device_id, role))
        bootstrap_available = (role == "bridge" and
                               not self.store.bootstrap_claimed(pairing_id, "bridge") and
                               not self.store.has_role(pairing_id, "bridge"))
        legacy_allowed = valid_legacy and (bootstrap_available or needs_credential_migration)
        if not (valid_session or valid_credential or legacy_allowed):
            await connection.close(code=4001, reason="authentication failed")
            return None
        try:
            decoded_public_key = base64.b64decode(public_key, validate=True)
        except ValueError:
            decoded_public_key = b""
        if not 32 <= len(decoded_public_key) <= 256:
            await connection.close(code=4000, reason="valid device public key is required")
            return None
        try:
            last_received_seq = int(message.get("lastReceivedSeq", 0))
        except (TypeError, ValueError):
            last_received_seq = 0
        try:
            remembered = self.store.register_device(
                pairing_id, device_id, role, max(0, last_received_seq), public_key)
        except ValueError as error:
            await connection.close(code=4003, reason=str(error))
            return None
        if bootstrap_available and legacy_allowed:
            self.store.claim_bootstrap(pairing_id, role, device_id)
        session = ClientSession(connection, pairing_id, device_id, role, remembered, public_key)
        if legacy_allowed or (valid_session and not device_credential):
            setattr(session, "new_device_credential", self.store.issue_device_credential(
                pairing_id, device_id, role))
        return session

    async def _handle_message(self, session: ClientSession, raw: str | bytes) -> None:
        if not isinstance(raw, str) or len(raw.encode("utf-8")) > self.max_message_bytes:
            await session.connection.close(code=4009, reason="message too large")
            return
        try:
            message = json.loads(raw)
        except json.JSONDecodeError:
            await self._send_error(session.connection, "invalid JSON")
            return
        if not isinstance(message, dict):
            await self._send_error(session.connection, "message must be an object")
            return
        message_type = message.get("type")
        if message_type == "gateway_ack":
            try:
                seq = int(message.get("seq", 0))
            except (TypeError, ValueError):
                seq = 0
            if seq > 0:
                session.last_acked_seq = max(session.last_acked_seq, seq)
                self.store.acknowledge(session.pairing_id, session.device_id, seq)
            return
        if message_type == "gateway_ping":
            await self._send_json(session.connection, {
                "type": "gateway_pong", "timestamp": _now(),
            })
            return
        if message_type == "gateway_pairing_create":
            if session.role != "bridge":
                await self._send_error(session.connection, "only a bridge can create pairing sessions")
                return
            await self._create_public_pairing(session)
            return
        if message_type == "gateway_pairing_decision":
            if session.role != "bridge":
                await self._send_error(session.connection, "only a bridge can approve pairing")
                return
            await self._decide_public_pairing(session, message)
            return
        now_monotonic = time.monotonic()
        session.action_times = [item for item in session.action_times
                                if now_monotonic - item < 60]
        if len(session.action_times) >= 120:
            await self._send_error(session.connection, "gateway rate limit exceeded")
            return
        session.action_times.append(now_monotonic)
        if message_type in ("gateway_device_list", "gateway_device_rename",
                            "gateway_device_revoke"):
            await self._handle_device_management(session, message)
            return
        if message_type != "gateway_send" or not isinstance(message.get("payload"), dict):
            await self._send_error(session.connection, "unsupported gateway message")
            return
        if message["payload"].get("type") != "e2ee":
            await self._send_error(session.connection, "gateway payload must be end-to-end encrypted")
            return
        target_role = "bridge" if session.role == "phone" else "phone"
        target_device_id = str(message.get("targetDeviceId", "")).strip()[:128]
        if target_device_id and not self.store.device_exists(
                session.pairing_id, target_device_id, target_role):
            await self._send_error(session.connection, "target device is not paired")
            return
        if not target_device_id:
            known_targets = self.store.devices(session.pairing_id, target_role)
            if len(known_targets) == 1:
                target_device_id = str(known_targets[0]["deviceId"])
            elif len(known_targets) > 1 and session.role == "phone":
                await self._send_error(session.connection, "target device is required")
                return
        client_message_id = str(message.get("clientMessageId", ""))[:256]
        seq, created = self.store.enqueue(
            session.pairing_id, session.device_id, target_role,
            message["payload"], client_message_id, target_device_id)
        await self._send_json(session.connection, {
            "type": "gateway_accepted",
            "clientMessageId": str(message.get("clientMessageId", "")),
            "seq": seq,
            "duplicate": not created,
        })
        if not created:
            return
        envelope = {
            "type": "gateway_message",
            "seq": seq,
            "fromRole": session.role,
            "fromDeviceId": session.device_id,
            "fromDevicePublicKey": session.public_key,
            "createdAt": _now(),
            "payload": message["payload"],
        }
        await self._send_to_role(
            session.pairing_id, target_role, envelope, target_device_id)

    def _cleanup_public_pairings(self) -> None:
        now = _now()
        self.public_pairings = {
            session_id: pairing for session_id, pairing in self.public_pairings.items()
            if pairing.expires_at > now
        }

    async def _create_public_pairing(self, bridge: ClientSession) -> None:
        self._cleanup_public_pairings()
        for session_id, pairing in list(self.public_pairings.items()):
            if (pairing.pairing_id == bridge.pairing_id and
                    pairing.bridge_device_id == bridge.device_id):
                if pairing.phone_connection is not None:
                    await pairing.phone_connection.close(code=4000, reason="pairing replaced")
                self.public_pairings.pop(session_id, None)
        secret = secrets.token_urlsafe(32)
        pairing = PublicPairingSession(
            session_id=secrets.token_urlsafe(18),
            pairing_id=bridge.pairing_id,
            bridge_device_id=bridge.device_id,
            bridge_public_key=bridge.public_key,
            secret_hash=_token_hash(secret),
            code=_pairing_code(),
            expires_at=_now() + PAIRING_TTL_SECONDS,
        )
        self.public_pairings[pairing.session_id] = pairing
        await self._send_json(bridge.connection, {
            "type": "gateway_pairing_created",
            "sessionId": pairing.session_id,
            "secret": secret,
            "code": pairing.code,
            "expiresAt": pairing.expires_at,
        })

    async def _handle_public_pairing_connection(
            self, connection: websockets.ServerConnection) -> None:
        remote_ip = self._remote_ip(connection)
        now_monotonic = time.monotonic()
        attempts = [item for item in self.pairing_attempts.get(remote_ip, [])
                    if now_monotonic - item < 60]
        if len(attempts) >= PAIRING_MAX_ATTEMPTS:
            await connection.close(code=4008, reason="pairing rate limit exceeded")
            return
        attempts.append(now_monotonic)
        self.pairing_attempts[remote_ip] = attempts
        try:
            raw = await asyncio.wait_for(connection.recv(), timeout=AUTH_TIMEOUT_SECONDS)
            if not isinstance(raw, str) or len(raw.encode("utf-8")) > 16 * 1024:
                raise ValueError("invalid pairing request")
            message = json.loads(raw)
            if not isinstance(message, dict) or message.get("type") != "gateway_pairing_join":
                raise ValueError("invalid pairing request")
            self._cleanup_public_pairings()
            session_id = str(message.get("sessionId", "")).strip()
            supplied_secret = str(message.get("secret", ""))
            supplied_code = _normalize_pairing_code(str(message.get("code", "")))
            pairing = self.public_pairings.get(session_id) if session_id else None
            if pairing is None and supplied_code:
                pairing = next((item for item in self.public_pairings.values()
                                if _normalize_pairing_code(item.code) == supplied_code), None)
            if pairing is None or pairing.expires_at <= _now():
                raise ValueError("pairing code is invalid or expired")
            pairing.attempts += 1
            if pairing.attempts > PAIRING_MAX_ATTEMPTS:
                self.public_pairings.pop(pairing.session_id, None)
                raise ValueError("pairing attempts exceeded")
            if session_id and not hmac.compare_digest(
                    pairing.secret_hash, _token_hash(supplied_secret)):
                raise ValueError("pairing code is invalid or expired")
            if not session_id and supplied_code != _normalize_pairing_code(pairing.code):
                raise ValueError("pairing code is invalid or expired")
            if pairing.phone_connection is not None:
                raise ValueError("pairing request already pending")
            phone_device_id = str(message.get("deviceId", "")).strip()[:128]
            phone_public_key = str(message.get("devicePublicKey", "")).strip()
            phone_name = str(message.get("displayName", "Starly Phone")).strip()[:64]
            if not phone_device_id or not phone_public_key:
                raise ValueError("invalid phone identity")
            try:
                decoded_public_key = base64.b64decode(phone_public_key, validate=True)
            except ValueError:
                decoded_public_key = b""
            if not 32 <= len(decoded_public_key) <= 256:
                raise ValueError("invalid phone public key")
            pairing.request_id = secrets.token_urlsafe(18)
            pairing.phone_device_id = phone_device_id
            pairing.phone_public_key = phone_public_key
            pairing.phone_name = phone_name or "Starly Phone"
            pairing.phone_connection = connection
            verify_material = (pairing.request_id + phone_device_id + phone_public_key).encode("utf-8")
            verify_digest = hmac.new(
                pairing.secret_hash.encode("ascii"), verify_material, hashlib.sha256).digest()
            pairing.verification_code = f"{int.from_bytes(verify_digest[:4], 'big') % 1000000:06d}"
            await self._send_json(connection, {
                "type": "gateway_pairing_waiting",
                "requestId": pairing.request_id,
                "verificationCode": pairing.verification_code,
                "expiresAt": pairing.expires_at,
            })
            bridges = [item for item in self.sessions
                       if item.pairing_id == pairing.pairing_id and
                       item.role == "bridge" and item.device_id == pairing.bridge_device_id]
            if not bridges:
                raise ValueError("computer is offline")
            await asyncio.gather(*(self._send_json(item.connection, {
                "type": "gateway_pairing_request",
                "requestId": pairing.request_id,
                "phoneDeviceId": pairing.phone_device_id,
                "phonePublicKey": pairing.phone_public_key,
                "phoneName": pairing.phone_name,
                "verificationCode": pairing.verification_code,
                "expiresAt": pairing.expires_at,
            }) for item in bridges))
            await connection.wait_closed()
        except (asyncio.TimeoutError, json.JSONDecodeError, ValueError) as error:
            if connection.state.name != "CLOSED":
                await self._send_json(connection, {
                    "type": "gateway_pairing_error", "message": str(error),
                })
                await connection.close(code=4001, reason="pairing failed")

    async def _decide_public_pairing(self, bridge: ClientSession,
                                     message: JsonObject) -> None:
        request_id = str(message.get("requestId", "")).strip()
        approved = bool(message.get("approved", False))
        pairing = next((item for item in self.public_pairings.values()
                        if item.request_id == request_id), None)
        if (pairing is None or pairing.pairing_id != bridge.pairing_id or
                pairing.bridge_device_id != bridge.device_id or
                pairing.phone_connection is None or pairing.expires_at <= _now()):
            await self._send_error(bridge.connection, "pairing request is no longer available")
            return
        phone_connection = pairing.phone_connection
        if not approved:
            await self._send_json(phone_connection, {
                "type": "gateway_pairing_rejected", "message": "computer rejected pairing",
            })
            await phone_connection.close(code=4003, reason="pairing rejected")
            self.public_pairings.pop(pairing.session_id, None)
            return
        try:
            self.store.register_device(
                pairing.pairing_id, pairing.phone_device_id, "phone", 0,
                pairing.phone_public_key)
            credential = self.store.issue_device_credential(
                pairing.pairing_id, pairing.phone_device_id, "phone")
            await self._send_json(phone_connection, {
                "type": "gateway_pairing_complete",
                "pairingId": pairing.pairing_id,
                "deviceId": pairing.phone_device_id,
                "deviceCredential": credential,
                "targetDeviceId": pairing.bridge_device_id,
                "targetPublicKey": pairing.bridge_public_key,
                "verificationCode": pairing.verification_code,
            })
            await self._send_json(bridge.connection, {
                "type": "gateway_pairing_approved",
                "phoneDeviceId": pairing.phone_device_id,
                "phoneName": pairing.phone_name,
            })
            await phone_connection.close(code=1000, reason="pairing complete")
        except ValueError as error:
            await self._send_json(phone_connection, {
                "type": "gateway_pairing_error", "message": str(error),
            })
            await phone_connection.close(code=4003, reason="pairing failed")
        finally:
            self.public_pairings.pop(pairing.session_id, None)

    async def _handle_device_management(self, session: ClientSession,
                                        message: JsonObject) -> None:
        message_type = str(message.get("type", ""))
        target_role = "bridge" if session.role == "phone" else "phone"
        device_id = str(message.get("deviceId", "")).strip()[:128]
        if message_type == "gateway_device_rename":
            display_name = str(message.get("displayName", "")).strip()[:64]
            if not device_id or not self.store.rename_device(
                    session.pairing_id, device_id, display_name):
                await self._send_error(session.connection, "device not found")
                return
        elif message_type == "gateway_device_revoke":
            if not device_id or device_id == session.device_id or not self.store.revoke_device(
                    session.pairing_id, device_id):
                await self._send_error(session.connection, "device cannot be revoked")
                return
            async with self.lock:
                targets = [item for item in self.sessions
                           if item.pairing_id == session.pairing_id and
                           item.device_id == device_id]
            await asyncio.gather(*(item.connection.close(
                code=4003, reason="device revoked") for item in targets), return_exceptions=True)
        await self._send_json(session.connection, {
            "type": "gateway_devices",
            "devices": self.store.devices(session.pairing_id, target_role),
        })

    async def _replay(self, session: ClientSession) -> None:
        for envelope in self.store.replay(
                session.pairing_id, session.role, session.device_id,
                session.last_acked_seq):
            await self._send_json(session.connection, {
                "type": "gateway_message",
                "seq": envelope["seq"],
                "fromDeviceId": envelope["sourceDeviceId"],
                "fromDevicePublicKey": self.store.device_public_key(
                    session.pairing_id, str(envelope["sourceDeviceId"])),
                "createdAt": envelope["createdAt"],
                "replayed": True,
                "payload": envelope["payload"],
            })

    async def _broadcast_presence(self, source: ClientSession, online: bool) -> None:
        await self._send_to_role(source.pairing_id,
                                 "phone" if source.role == "bridge" else "bridge", {
            "type": "gateway_presence",
            "role": source.role,
            "deviceId": source.device_id,
            "devicePublicKey": source.public_key,
            "online": online,
            "timestamp": _now(),
        })

    async def _send_to_role(self, pairing_id: str, role: str, message: JsonObject,
                            target_device_id: str = "") -> None:
        async with self.lock:
            targets = [session for session in self.sessions
                       if session.pairing_id == pairing_id and session.role == role and
                       (not target_device_id or session.device_id == target_device_id)]
        if not targets:
            return
        results = await asyncio.gather(
            *(self._send_json(target.connection, message) for target in targets),
            return_exceptions=True,
        )
        _ = results

    @staticmethod
    async def _send_json(connection: websockets.ServerConnection,
                         message: JsonObject) -> None:
        await connection.send(json.dumps(message, ensure_ascii=False, separators=(",", ":")))

    async def _send_error(self, connection: websockets.ServerConnection, message: str) -> None:
        await self._send_json(connection, {"type": "gateway_error", "message": message})


async def run_gateway() -> None:
    host = os.environ.get("STARLY_GATEWAY_HOST", DEFAULT_HOST)
    port = int(os.environ.get("STARLY_GATEWAY_PORT", str(DEFAULT_PORT)))
    data_dir = Path(os.environ.get("STARLY_GATEWAY_DATA", "./data")).resolve()
    pairings_path = Path(os.environ.get(
        "STARLY_GATEWAY_PAIRINGS", str(data_dir / "pairings.json"))).resolve()
    pairings = load_pairings(pairings_path)
    store = GatewayStore(data_dir / "gateway.sqlite3")
    gateway = StarlyGateway(pairings, store)
    try:
        async with websockets.serve(
            gateway.handle,
            host,
            port,
            max_size=DEFAULT_MAX_MESSAGE_BYTES,
            ping_interval=20,
            ping_timeout=20,
        ):
            print(f"Starly Gateway listening on ws://{host}:{port}/ws")
            await asyncio.Future()
    finally:
        store.close()


if __name__ == "__main__":
    asyncio.run(run_gateway())
