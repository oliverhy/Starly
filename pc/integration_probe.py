import asyncio
import json
import os
from pathlib import Path

import websockets


async def main() -> None:
    config_path = Path(os.environ["APPDATA"]) / "StarlyBridge" / "config.json"
    config = json.loads(config_path.read_text(encoding="utf-8"))
    uri = f"ws://127.0.0.1:{config['port']}/?token={config['token']}"
    async with websockets.connect(uri, proxy=None) as connection:
        hello = json.loads(await connection.recv())
        assert hello["type"] == "hello"
        await connection.send(json.dumps({"type": "ping", "id": "probe"}))
        response = json.loads(await connection.recv())
        assert response == {"type": "ack", "id": "probe", "message": "pong"}
        print("Bundled bridge handshake and ping: OK")


if __name__ == "__main__":
    asyncio.run(main())
