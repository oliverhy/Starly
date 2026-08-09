from __future__ import annotations

import base64
import hashlib
import json
import os
import time
from collections.abc import Callable
from typing import Any

from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey, X25519PublicKey


JsonObject = dict[str, Any]
CounterHandler = Callable[[int], None]


class ReplayMessageError(ValueError):
    """The authenticated sender counter was already processed."""


def derive_pairing_key(token: str, pairing_id: str) -> bytes:
    if len(token) < 32:
        raise ValueError("E2EE token must contain at least 32 characters")
    material = b"starly-e2ee-v1\0" + pairing_id.encode("utf-8") + b"\0" + token.encode("utf-8")
    return hashlib.sha256(material).digest()


def generate_device_identity() -> tuple[str, str]:
    """Return a base64 PKCS#8 private key and X.509 public key."""
    private_key = X25519PrivateKey.generate()
    private_der = private_key.private_bytes(
        serialization.Encoding.DER,
        serialization.PrivateFormat.PKCS8,
        serialization.NoEncryption(),
    )
    public_der = private_key.public_key().public_bytes(
        serialization.Encoding.DER,
        serialization.PublicFormat.SubjectPublicKeyInfo,
    )
    return (base64.b64encode(private_der).decode("ascii"),
            base64.b64encode(public_der).decode("ascii"))


class GatewayCrypto:
    def __init__(self, token: str, pairing_id: str, device_id: str,
                 send_counter: int = 0, received_counters: dict[str, int] | None = None,
                 send_counter_handler: CounterHandler | None = None,
                 receive_counter_handler: Callable[[str, int], None] | None = None,
                 private_key: str = "", peer_public_keys: dict[str, str] | None = None) -> None:
        self.legacy_key = derive_pairing_key(token, pairing_id)
        self.pairing_id = pairing_id
        self.device_id = device_id
        self.send_counter = max(0, send_counter)
        self.received_counters = dict(received_counters or {})
        self.send_counter_handler = send_counter_handler
        self.receive_counter_handler = receive_counter_handler
        self.private_key = self._load_private_key(private_key) if private_key else None
        self.peer_public_keys = dict(peer_public_keys or {})

    def update_peer_public_keys(self, peers: list[JsonObject]) -> None:
        for peer in peers:
            device_id = str(peer.get("deviceId", ""))
            public_key = str(peer.get("publicKey", ""))
            if device_id and public_key:
                self.peer_public_keys[device_id] = public_key

    def encrypt(self, payload: JsonObject, target_device_id: str = "") -> JsonObject:
        self.send_counter += 1
        timestamp = int(time.time())
        nonce = os.urandom(12)
        aad = self._aad(self.device_id, self.send_counter, timestamp)
        plaintext = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        key, version = self._key_for_peer(target_device_id)
        sealed = AESGCM(key).encrypt(nonce, plaintext, aad)
        if self.send_counter_handler:
            self.send_counter_handler(self.send_counter)
        return {
            "type": "e2ee",
            "version": version,
            "senderDeviceId": self.device_id,
            "counter": self.send_counter,
            "timestamp": timestamp,
            "nonce": base64.b64encode(nonce).decode("ascii"),
            "ciphertext": base64.b64encode(sealed[:-16]).decode("ascii"),
            "tag": base64.b64encode(sealed[-16:]).decode("ascii"),
        }

    def decrypt(self, envelope: JsonObject) -> JsonObject:
        version = int(envelope.get("version", 0))
        if envelope.get("type") != "e2ee" or version not in (1, 2):
            raise ValueError("Gateway payload is not encrypted")
        sender = str(envelope.get("senderDeviceId", ""))
        counter = int(envelope.get("counter", 0))
        timestamp = int(envelope.get("timestamp", 0))
        if not sender or counter <= self.received_counters.get(sender, 0):
            raise ReplayMessageError("Rejected replayed encrypted message")
        if abs(int(time.time()) - timestamp) > 48 * 60 * 60:
            raise ValueError("Rejected expired encrypted message")
        nonce = base64.b64decode(str(envelope.get("nonce", "")), validate=True)
        ciphertext = base64.b64decode(str(envelope.get("ciphertext", "")), validate=True)
        tag = base64.b64decode(str(envelope.get("tag", "")), validate=True)
        if len(nonce) != 12 or len(tag) != 16:
            raise ValueError("Invalid encrypted message parameters")
        key = self.legacy_key if version == 1 else self._key_for_peer(sender)[0]
        plaintext = AESGCM(key).decrypt(
            nonce, ciphertext + tag, self._aad(sender, counter, timestamp))
        payload = json.loads(plaintext.decode("utf-8"))
        if not isinstance(payload, dict):
            raise ValueError("Decrypted payload must be an object")
        self.received_counters[sender] = counter
        if self.receive_counter_handler:
            self.receive_counter_handler(sender, counter)
        return payload

    def _aad(self, sender: str, counter: int, timestamp: int) -> bytes:
        return f"starly|{self.pairing_id}|{sender}|{counter}|{timestamp}".encode("utf-8")

    @staticmethod
    def _load_private_key(value: str) -> X25519PrivateKey:
        key = serialization.load_der_private_key(base64.b64decode(value, validate=True), None)
        if not isinstance(key, X25519PrivateKey):
            raise ValueError("Device private key is not X25519")
        return key

    def _key_for_peer(self, device_id: str) -> tuple[bytes, int]:
        if self.private_key is None:
            return self.legacy_key, 1
        encoded = self.peer_public_keys.get(device_id, "")
        if not encoded:
            raise ValueError(f"Missing X25519 public key for device {device_id}")
        key = serialization.load_der_public_key(base64.b64decode(encoded, validate=True))
        if not isinstance(key, X25519PublicKey):
            raise ValueError("Peer public key is not X25519")
        secret = self.private_key.exchange(key)
        material = (b"starly-e2ee-v2\0" + self.pairing_id.encode("utf-8") +
                    b"\0" + secret)
        return hashlib.sha256(material).digest(), 2
