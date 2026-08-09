from __future__ import annotations

import json
import hashlib
import secrets
from pathlib import Path


def main() -> None:
    data_dir = Path(__file__).resolve().parent / "data"
    data_dir.mkdir(parents=True, exist_ok=True)
    path = data_dir / "pairings.json"
    pairings: dict[str, object] = {}
    if path.exists():
        loaded = json.loads(path.read_text(encoding="utf-8"))
        if isinstance(loaded, dict):
            pairings = loaded
    pairing_id = secrets.token_hex(16)
    token = secrets.token_urlsafe(32)
    pairings[pairing_id] = {
        "tokenSha256": hashlib.sha256(token.encode("utf-8")).hexdigest()
    }
    path.write_text(json.dumps(pairings, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"Pairing ID: {pairing_id}")
    print(f"Token: {token}")
    print(f"Gateway pairing file: {path}")
    print("Copy pairings.json to the VPS gateway data directory.")


if __name__ == "__main__":
    main()
