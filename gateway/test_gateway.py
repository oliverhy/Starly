from __future__ import annotations

import asyncio
import base64
import json
import tempfile
import unittest
from pathlib import Path

import websockets

from gateway.starly_gateway import GatewayStore, StarlyGateway, _token_hash


TOKEN = "test-token-with-at-least-thirty-two-characters"
PAIRING_ID = "test-pair"
BRIDGE_KEY = base64.b64encode(b"b" * 32).decode("ascii")
BRIDGE_KEY_2 = base64.b64encode(b"c" * 32).decode("ascii")
PHONE_KEY = base64.b64encode(b"p" * 32).decode("ascii")


class GatewayTests(unittest.TestCase):
    def test_device_public_key_is_bound_and_revocable(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            store = GatewayStore(Path(directory) / "gateway.sqlite3")
            try:
                store.register_device(PAIRING_ID, "pc-1", "bridge", 0, "public-key-1")
                store.register_device(PAIRING_ID, "pc-1", "bridge", 0, "public-key-1")
                with self.assertRaisesRegex(ValueError, "public key changed"):
                    store.register_device(PAIRING_ID, "pc-1", "bridge", 0, "public-key-2")
                self.assertTrue(store.rename_device(PAIRING_ID, "pc-1", "Office PC"))
                self.assertEqual(store.devices(PAIRING_ID, "bridge")[0]["displayName"],
                                 "Office PC")
                self.assertTrue(store.revoke_device(PAIRING_ID, "pc-1"))
                self.assertEqual(store.devices(PAIRING_ID, "bridge"), [])
                with self.assertRaisesRegex(ValueError, "revoked"):
                    store.register_device(PAIRING_ID, "pc-1", "bridge", 0, "public-key-1")
            finally:
                store.close()

    def test_short_lived_session_token_is_identity_bound(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            store = GatewayStore(Path(directory) / "gateway.sqlite3")
            try:
                gateway = StarlyGateway({PAIRING_ID: _token_hash(TOKEN)}, store)
                token = gateway._issue_session_token(PAIRING_ID, "pc-1", "bridge")
                self.assertTrue(gateway._validate_session_token(
                    token, PAIRING_ID, "pc-1", "bridge"))
                self.assertFalse(gateway._validate_session_token(
                    token, PAIRING_ID, "pc-2", "bridge"))
                self.assertFalse(gateway._validate_session_token(
                    token, PAIRING_ID, "pc-1", "phone"))
            finally:
                store.close()

    def test_device_credentials_are_identity_bound_and_revoked(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            store = GatewayStore(Path(directory) / "gateway.sqlite3")
            try:
                store.register_device(PAIRING_ID, "phone-1", "phone", 0, "public-key")
                credential = store.issue_device_credential(PAIRING_ID, "phone-1", "phone")
                self.assertTrue(store.validate_device_credential(
                    PAIRING_ID, "phone-1", "phone", credential))
                self.assertFalse(store.validate_device_credential(
                    PAIRING_ID, "phone-2", "phone", credential))
                store.revoke_device(PAIRING_ID, "phone-1")
                self.assertFalse(store.validate_device_credential(
                    PAIRING_ID, "phone-1", "phone", credential))
            finally:
                store.close()

    def test_store_assigns_monotonic_sequence_and_replays(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            store = GatewayStore(Path(directory) / "gateway.sqlite3")
            try:
                first, _ = store.enqueue(PAIRING_ID, "phone-1", "bridge", {"type": "ping"})
                second, _ = store.enqueue(PAIRING_ID, "phone-1", "bridge", {"type": "input"})
                self.assertEqual((first, second), (1, 2))
                replay = store.replay(PAIRING_ID, "bridge", "pc-1", 1)
                self.assertEqual([item["seq"] for item in replay], [2])
                self.assertEqual(replay[0]["payload"]["type"], "input")
                duplicate, created = store.enqueue(
                    PAIRING_ID, "phone-1", "bridge", {"type": "e2ee"}, "same-id")
                repeated, repeated_created = store.enqueue(
                    PAIRING_ID, "phone-1", "bridge", {"type": "e2ee"}, "same-id")
                self.assertEqual(duplicate, repeated)
                self.assertTrue(created)
                self.assertFalse(repeated_created)
            finally:
                store.close()

    def test_gateway_routes_and_replays_messages(self) -> None:
        asyncio.run(self._route_and_replay())

    def test_gateway_routes_to_selected_bridge_only(self) -> None:
        asyncio.run(self._route_to_selected_bridge_only())

    def test_public_pairing_requires_bridge_approval_and_issues_device_credential(self) -> None:
        asyncio.run(self._public_pairing())

    def test_bootstrap_token_cannot_enroll_a_phone_or_be_reused(self) -> None:
        asyncio.run(self._bootstrap_token_is_one_time())

    async def _route_to_selected_bridge_only(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            store = GatewayStore(Path(directory) / "gateway.sqlite3")
            store.register_device(PAIRING_ID, "pc-1", "bridge", 0, BRIDGE_KEY)
            store.register_device(PAIRING_ID, "pc-2", "bridge", 0, BRIDGE_KEY_2)
            store.register_device(PAIRING_ID, "phone-1", "phone", 0, PHONE_KEY)
            pc1_credential = store.issue_device_credential(PAIRING_ID, "pc-1", "bridge")
            pc2_credential = store.issue_device_credential(PAIRING_ID, "pc-2", "bridge")
            phone_credential = store.issue_device_credential(PAIRING_ID, "phone-1", "phone")
            gateway = StarlyGateway({PAIRING_ID: _token_hash(TOKEN)}, store)
            server = await websockets.serve(gateway.handle, "127.0.0.1", 0)
            port = server.sockets[0].getsockname()[1]
            try:
                async with websockets.connect(f"ws://127.0.0.1:{port}/ws") as pc1, \
                        websockets.connect(f"ws://127.0.0.1:{port}/ws") as pc2, \
                        websockets.connect(f"ws://127.0.0.1:{port}/ws") as phone:
                    for connection, device_id in ((pc1, "pc-1"), (pc2, "pc-2")):
                        credential = pc2_credential if device_id == "pc-2" else pc1_credential
                        await connection.send(json.dumps({
                            "type": "gateway_auth", "protocol": 1, "role": "bridge",
                            "pairingId": PAIRING_ID, "deviceId": device_id,
                            "deviceCredential": credential,
                            "devicePublicKey": (BRIDGE_KEY_2 if device_id == "pc-2"
                                                else BRIDGE_KEY),
                        }))
                        self.assertEqual(json.loads(await connection.recv())["type"],
                                         "gateway_ready")
                    await phone.send(json.dumps({
                        "type": "gateway_auth", "protocol": 1, "role": "phone",
                        "pairingId": PAIRING_ID, "deviceId": "phone-1",
                        "deviceCredential": phone_credential,
                        "devicePublicKey": PHONE_KEY,
                    }))
                    ready = json.loads(await phone.recv())
                    self.assertEqual({item["deviceId"] for item in ready["knownPeerDevices"]},
                                     {"pc-1", "pc-2"})
                    self.assertEqual(json.loads(await pc1.recv())["type"], "gateway_presence")
                    self.assertEqual(json.loads(await pc2.recv())["type"], "gateway_presence")

                    await phone.send(json.dumps({
                        "type": "gateway_send", "clientMessageId": "targeted-1",
                        "targetDeviceId": "pc-2",
                        "payload": {"type": "e2ee", "id": "only-pc-2"},
                    }))
                    self.assertEqual(json.loads(await phone.recv())["type"], "gateway_accepted")
                    delivered = json.loads(await asyncio.wait_for(pc2.recv(), timeout=1))
                    self.assertEqual(delivered["payload"]["id"], "only-pc-2")
                    with self.assertRaises(asyncio.TimeoutError):
                        await asyncio.wait_for(pc1.recv(), timeout=0.1)

                self.assertEqual(store.replay(PAIRING_ID, "bridge", "pc-1", 0), [])
                replayed = store.replay(PAIRING_ID, "bridge", "pc-2", 0)
                self.assertEqual([item["payload"]["id"] for item in replayed],
                                 ["only-pc-2"])
            finally:
                server.close()
                await server.wait_closed()
                store.close()

    async def _public_pairing(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            store = GatewayStore(Path(directory) / "gateway.sqlite3")
            gateway = StarlyGateway({PAIRING_ID: _token_hash(TOKEN)}, store)
            server = await websockets.serve(gateway.handle, "127.0.0.1", 0)
            port = server.sockets[0].getsockname()[1]
            public_key = PHONE_KEY
            try:
                async with websockets.connect(f"ws://127.0.0.1:{port}/ws") as bridge:
                    await bridge.send(json.dumps({
                        "type": "gateway_auth", "protocol": 1, "role": "bridge",
                        "pairingId": PAIRING_ID, "deviceId": "pc-1", "token": TOKEN,
                        "devicePublicKey": BRIDGE_KEY,
                    }))
                    self.assertEqual(json.loads(await bridge.recv())["type"], "gateway_ready")
                    await bridge.send(json.dumps({"type": "gateway_pairing_create"}))
                    created = json.loads(await bridge.recv())
                    self.assertEqual(created["type"], "gateway_pairing_created")
                    self.assertRegex(created["code"], r"^[0-9A-Z]{4}-[0-9A-Z]{4}$")

                    async with websockets.connect(
                            f"ws://127.0.0.1:{port}/ws?pair=1") as pairing_phone:
                        await pairing_phone.send(json.dumps({
                            "type": "gateway_pairing_join",
                            "sessionId": created["sessionId"], "secret": created["secret"],
                            "deviceId": "phone-public", "devicePublicKey": public_key,
                            "displayName": "Test Phone",
                        }))
                        waiting = json.loads(await pairing_phone.recv())
                        request = json.loads(await bridge.recv())
                        self.assertEqual(waiting["type"], "gateway_pairing_waiting")
                        self.assertEqual(request["type"], "gateway_pairing_request")
                        self.assertEqual(waiting["verificationCode"],
                                         request["verificationCode"])
                        await bridge.send(json.dumps({
                            "type": "gateway_pairing_decision",
                            "requestId": request["requestId"], "approved": True,
                        }))
                        complete = json.loads(await pairing_phone.recv())
                        self.assertEqual(complete["type"], "gateway_pairing_complete")
                        credential = complete["deviceCredential"]
                        self.assertGreaterEqual(len(credential), 32)
                        self.assertEqual(json.loads(await bridge.recv())["type"],
                                         "gateway_pairing_approved")

                    async with websockets.connect(f"ws://127.0.0.1:{port}/ws") as phone:
                        await phone.send(json.dumps({
                            "type": "gateway_auth", "protocol": 1, "role": "phone",
                            "pairingId": PAIRING_ID, "deviceId": "phone-public",
                            "deviceCredential": credential, "devicePublicKey": public_key,
                        }))
                        ready = json.loads(await phone.recv())
                        self.assertEqual(ready["type"], "gateway_ready")
                        self.assertEqual(ready["deviceCredential"], "")
            finally:
                server.close()
                await server.wait_closed()
                store.close()

    async def _route_and_replay(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            store = GatewayStore(Path(directory) / "gateway.sqlite3")
            store.register_device(PAIRING_ID, "phone-1", "phone", 0, PHONE_KEY)
            phone_credential = store.issue_device_credential(
                PAIRING_ID, "phone-1", "phone")
            gateway = StarlyGateway({PAIRING_ID: _token_hash(TOKEN)}, store)
            server = await websockets.serve(gateway.handle, "127.0.0.1", 0)
            port = server.sockets[0].getsockname()[1]
            try:
                async with websockets.connect(f"ws://127.0.0.1:{port}/ws") as bridge, \
                        websockets.connect(f"ws://127.0.0.1:{port}/ws") as phone:
                    await bridge.send(json.dumps({
                        "type": "gateway_auth", "protocol": 1, "role": "bridge",
                        "pairingId": PAIRING_ID, "deviceId": "pc-1", "token": TOKEN,
                        "devicePublicKey": BRIDGE_KEY,
                    }))
                    bridge_ready = json.loads(await bridge.recv())
                    self.assertEqual(bridge_ready["type"], "gateway_ready")
                    bridge_credential = bridge_ready["deviceCredential"]
                    await phone.send(json.dumps({
                        "type": "gateway_auth", "protocol": 1, "role": "phone",
                        "pairingId": PAIRING_ID, "deviceId": "phone-1",
                        "deviceCredential": phone_credential,
                        "devicePublicKey": PHONE_KEY,
                    }))
                    phone_ready = json.loads(await phone.recv())
                    self.assertEqual(phone_ready["type"], "gateway_ready")
                    self.assertTrue(phone_ready["peerOnline"])
                    presence = json.loads(await bridge.recv())
                    self.assertEqual(presence["type"], "gateway_presence")
                    await phone.send(json.dumps({
                        "type": "gateway_send", "clientMessageId": "m-1",
                        "payload": {"type": "e2ee", "id": "probe"},
                    }))
                    accepted = json.loads(await phone.recv())
                    self.assertEqual(accepted["type"], "gateway_accepted")
                    delivered = json.loads(await bridge.recv())
                    self.assertEqual(delivered["type"], "gateway_message")
                    self.assertEqual(delivered["payload"]["id"], "probe")
                    delivered_seq = delivered["seq"]
                    await phone.send(json.dumps({
                        "type": "gateway_send", "clientMessageId": "m-1",
                        "payload": {"type": "e2ee", "id": "probe"},
                    }))
                    duplicate = json.loads(await phone.recv())
                    self.assertEqual(duplicate["type"], "gateway_accepted")
                    self.assertTrue(duplicate["duplicate"])
                    self.assertEqual(duplicate["seq"], delivered_seq)
                    with self.assertRaises(asyncio.TimeoutError):
                        await asyncio.wait_for(bridge.recv(), timeout=0.1)
                async with websockets.connect(f"ws://127.0.0.1:{port}/ws") as bridge_again:
                    await bridge_again.send(json.dumps({
                        "type": "gateway_auth", "protocol": 1, "role": "bridge",
                        "pairingId": PAIRING_ID, "deviceId": "pc-1",
                        "deviceCredential": bridge_credential,
                        "devicePublicKey": BRIDGE_KEY,
                        "lastReceivedSeq": 0,
                    }))
                    self.assertEqual(json.loads(await bridge_again.recv())["type"], "gateway_ready")
                    replayed = json.loads(await bridge_again.recv())
                    self.assertEqual(replayed["seq"], delivered_seq)
                    self.assertTrue(replayed["replayed"])
            finally:
                server.close()
                await server.wait_closed()
                store.close()

    async def _bootstrap_token_is_one_time(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            store = GatewayStore(Path(directory) / "gateway.sqlite3")
            gateway = StarlyGateway({PAIRING_ID: _token_hash(TOKEN)}, store)
            server = await websockets.serve(gateway.handle, "127.0.0.1", 0)
            port = server.sockets[0].getsockname()[1]
            try:
                async with websockets.connect(f"ws://127.0.0.1:{port}/ws") as phone:
                    await phone.send(json.dumps({
                        "type": "gateway_auth", "protocol": 1, "role": "phone",
                        "pairingId": PAIRING_ID, "deviceId": "stolen-phone",
                        "token": TOKEN, "devicePublicKey": PHONE_KEY,
                    }))
                    with self.assertRaises(websockets.ConnectionClosed):
                        await phone.recv()

                async with websockets.connect(f"ws://127.0.0.1:{port}/ws") as bridge:
                    await bridge.send(json.dumps({
                        "type": "gateway_auth", "protocol": 1, "role": "bridge",
                        "pairingId": PAIRING_ID, "deviceId": "pc-1",
                        "token": TOKEN, "devicePublicKey": BRIDGE_KEY,
                    }))
                    ready = json.loads(await bridge.recv())
                    self.assertGreaterEqual(len(ready["deviceCredential"]), 32)

                async with websockets.connect(f"ws://127.0.0.1:{port}/ws") as attacker:
                    await attacker.send(json.dumps({
                        "type": "gateway_auth", "protocol": 1, "role": "bridge",
                        "pairingId": PAIRING_ID, "deviceId": "attacker-pc",
                        "token": TOKEN, "devicePublicKey": BRIDGE_KEY_2,
                    }))
                    with self.assertRaises(websockets.ConnectionClosed):
                        await attacker.recv()
                self.assertTrue(store.revoke_device(PAIRING_ID, "pc-1"))
                async with websockets.connect(f"ws://127.0.0.1:{port}/ws") as attacker_again:
                    await attacker_again.send(json.dumps({
                        "type": "gateway_auth", "protocol": 1, "role": "bridge",
                        "pairingId": PAIRING_ID, "deviceId": "attacker-after-revoke",
                        "token": TOKEN, "devicePublicKey": BRIDGE_KEY_2,
                    }))
                    with self.assertRaises(websockets.ConnectionClosed):
                        await attacker_again.recv()
            finally:
                server.close()
                await server.wait_closed()
                store.close()


if __name__ == "__main__":
    unittest.main()
