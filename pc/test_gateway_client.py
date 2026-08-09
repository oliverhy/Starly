from __future__ import annotations

import asyncio
import json
import tempfile
import unittest
from pathlib import Path

import websockets

from gateway.starly_gateway import GatewayStore, StarlyGateway, _token_hash
from pc.gateway_client import GatewayBridgeClient, GatewayRelayConnection
from pc.gateway_crypto import GatewayCrypto, generate_device_identity


TOKEN = "bridge-test-token-with-at-least-32-characters"
PAIRING_ID = "bridge-test-pair"


class GatewayBridgeClientTests(unittest.TestCase):
    def test_bridge_receives_phone_payload_and_replies(self) -> None:
        asyncio.run(self._round_trip())

    def test_replayed_encrypted_payload_is_acked_without_reexecution(self) -> None:
        phone_crypto = GatewayCrypto(TOKEN, PAIRING_ID, "phone-1")
        bridge_crypto = GatewayCrypto(TOKEN, PAIRING_ID, "pc-1")
        envelope = phone_crypto.encrypt({"type": "ping", "id": "duplicate"})
        self.assertEqual(bridge_crypto.decrypt(envelope)["id"], "duplicate")
        handled: list[dict[str, object]] = []
        sent: list[dict[str, object]] = []

        async def handle(payload: dict[str, object], _source: str) -> None:
            handled.append(payload)

        class FakeConnection:
            async def send(self, raw: str) -> None:
                sent.append(json.loads(raw))

        client = GatewayBridgeClient(
            "ws://127.0.0.1/ws", PAIRING_ID, "pc-1", TOKEN,
            handle, lambda _connected, _message: None, crypto=bridge_crypto)
        client.connection = FakeConnection()  # type: ignore[assignment]
        asyncio.run(client._handle(json.dumps({
            "type": "gateway_message", "seq": 7,
            "fromDeviceId": "phone-1", "payload": envelope,
        })))

        self.assertEqual(handled, [])
        self.assertEqual(client.last_received_seq, 7)
        self.assertEqual(sent, [{"type": "gateway_ack", "seq": 7}])

    def test_presence_is_forwarded_to_bridge_ui_control_handler(self) -> None:
        controls: list[dict[str, object]] = []

        async def handle(_payload: dict[str, object], _source: str) -> None:
            return None

        async def control(message: dict[str, object]) -> None:
            controls.append(message)

        client = GatewayBridgeClient(
            "ws://127.0.0.1/ws", PAIRING_ID, "pc-1", TOKEN,
            handle, lambda _connected, _message: None, control_handler=control)
        asyncio.run(client._handle(json.dumps({
            "type": "gateway_presence", "role": "phone",
            "deviceId": "phone-1", "online": True,
        })))

        self.assertEqual(len(controls), 1)
        self.assertEqual(controls[0]["type"], "gateway_presence")
        self.assertEqual(controls[0]["deviceId"], "phone-1")

    async def _round_trip(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            store = GatewayStore(Path(directory) / "gateway.sqlite3")
            pc_private, pc_public = generate_device_identity()
            phone_private, phone_public = generate_device_identity()
            store.register_device(
                PAIRING_ID, "phone-1", "phone", 0, phone_public)
            phone_credential = store.issue_device_credential(
                PAIRING_ID, "phone-1", "phone")
            gateway = StarlyGateway({PAIRING_ID: _token_hash(TOKEN)}, store)
            server = await websockets.serve(gateway.handle, "127.0.0.1", 0)
            port = server.sockets[0].getsockname()[1]
            received: list[dict[str, object]] = []
            connected = asyncio.Event()
            client: GatewayBridgeClient

            async def handle(payload: dict[str, object], source_device_id: str) -> None:
                received.append(payload)
                relay = GatewayRelayConnection(client, source_device_id)
                await relay.send(json.dumps({
                    "type": "ack", "id": payload.get("id", ""), "message": "pong",
                }))

            def state(is_connected: bool, _message: str) -> None:
                if is_connected:
                    connected.set()

            client = GatewayBridgeClient(
                f"ws://127.0.0.1:{port}/ws", PAIRING_ID, "pc-1", TOKEN,
                handle, state, crypto=GatewayCrypto(
                    TOKEN, PAIRING_ID, "pc-1", private_key=pc_private),
                device_public_key=pc_public,
            )
            task = asyncio.create_task(client.run())
            try:
                await asyncio.wait_for(connected.wait(), timeout=2)
                async with websockets.connect(f"ws://127.0.0.1:{port}/ws") as phone:
                    phone_crypto = GatewayCrypto(
                        TOKEN, PAIRING_ID, "phone-1", private_key=phone_private,
                        peer_public_keys={"pc-1": pc_public})
                    await phone.send(json.dumps({
                        "type": "gateway_auth", "role": "phone", "pairingId": PAIRING_ID,
                        "deviceId": "phone-1", "deviceCredential": phone_credential,
                        "devicePublicKey": phone_public,
                    }))
                    self.assertEqual(json.loads(await phone.recv())["type"], "gateway_ready")
                    await phone.send(json.dumps({
                        "type": "gateway_send", "clientMessageId": "probe",
                        "targetDeviceId": "pc-1",
                        "payload": phone_crypto.encrypt(
                            {"type": "ping", "id": "probe"}, "pc-1"),
                    }))
                    while True:
                        message = json.loads(await asyncio.wait_for(phone.recv(), timeout=2))
                        if message.get("type") == "gateway_message":
                            clear = phone_crypto.decrypt(message["payload"])
                            self.assertEqual(clear["message"], "pong")
                            break
                self.assertEqual(received[0]["type"], "ping")
                for _ in range(20):
                    if not client.pending_sends:
                        break
                    await asyncio.sleep(0.05)
                self.assertEqual(client.pending_sends, {})
            finally:
                await client.stop()
                task.cancel()
                await asyncio.gather(task, return_exceptions=True)
                server.close()
                await server.wait_closed()
                store.close()


if __name__ == "__main__":
    unittest.main()
