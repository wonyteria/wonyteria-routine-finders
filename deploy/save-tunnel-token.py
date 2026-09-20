#!/usr/bin/env python3
"""Store a Cloudflare connector token without echoing it or using shell history."""

import base64
import getpass
import json
import os
from pathlib import Path


def main():
    token = getpass.getpass("Cloudflare Tunnel token (hidden input): ").strip()
    if not token or any(character.isspace() for character in token):
        raise SystemExit("Paste only the token, not the installation command.")
    try:
        decoded = base64.b64decode(token + "=" * (-len(token) % 4), validate=True)
        credentials = json.loads(decoded)
        if not all(credentials.get(key) for key in ("a", "t", "s")):
            raise ValueError("Missing token fields")
    except (ValueError, TypeError, AttributeError):
        raise SystemExit("Invalid connector token; nothing was saved.") from None

    destination = Path.home() / "services/routine-finders/tunnel.token"
    descriptor = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "w") as stream:
        stream.write(token + "\n")
    print("Tunnel token saved privately. No DNS records were changed.")


if __name__ == "__main__":
    main()
