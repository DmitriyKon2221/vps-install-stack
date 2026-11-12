#!/usr/bin/env python3
"""Make an AWG-Easy vpn:// export usable with AmneziaVPN site split tunneling.

Only the client's full-tunnel route markers are normalized. VPN keys, endpoint,
obfuscation values and server configuration are preserved.
"""

import argparse
import base64
import json
import os
import re
import struct
import sys
import zlib

MAX_PROFILE_BYTES = 1024 * 1024


def convert(link: str) -> str:
    link = link.strip()
    if not link.startswith("vpn://"):
        raise ValueError("input is not a vpn:// profile")
    encoded = link[6:]
    if not re.fullmatch(r"[A-Za-z0-9_-]+", encoded):
        raise ValueError("invalid vpn:// encoding")
    raw = base64.urlsafe_b64decode(encoded + "=" * (-len(encoded) % 4))
    if len(raw) < 5 or len(raw) > MAX_PROFILE_BYTES:
        raise ValueError("invalid compressed profile size")
    expected = struct.unpack(">I", raw[:4])[0]
    if expected > MAX_PROFILE_BYTES:
        raise ValueError("profile is too large")
    decompressor = zlib.decompressobj()
    data = decompressor.decompress(raw[4:], MAX_PROFILE_BYTES + 1)
    data += decompressor.flush()
    if len(data) != expected or not decompressor.eof:
        raise ValueError("invalid compressed profile")
    payload = json.loads(data)
    if payload.get("defaultContainer") != "amnezia-awg":
        raise ValueError("expected an AmneziaWG profile")
    containers = payload.get("containers")
    if not isinstance(containers, list) or len(containers) != 1:
        raise ValueError("unexpected container layout")
    awg = containers[0].get("awg")
    if not isinstance(awg, dict) or not isinstance(awg.get("last_config"), str):
        raise ValueError("AWG client configuration is missing")
    config = json.loads(awg["last_config"])
    routes = config.get("allowed_ips")
    if not isinstance(routes, list) or "0.0.0.0/0" not in routes:
        raise ValueError("expected a full-tunnel AWG profile")
    if "::/0" not in routes:
        routes.append("::/0")

    native = config.get("config")
    if native is not None:
        if not isinstance(native, str):
            raise ValueError("invalid native AWG configuration")
        pattern = r"(?m)^(AllowedIPs[ \t]*=[ \t]*)0\.0\.0\.0/0[ \t]*$"
        if re.search(pattern, native):
            native = re.sub(pattern, r"\g<1>0.0.0.0/0, ::/0", native, count=1)
        elif not re.search(r"(?m)^AllowedIPs[ \t]*=[ \t]*0\.0\.0\.0/0,[ \t]*::/0[ \t]*$", native):
            raise ValueError("unexpected native AllowedIPs; profile left unchanged")
        config["config"] = native

    awg["last_config"] = json.dumps(config, ensure_ascii=False, separators=(",", ":"))
    data = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode()
    framed = struct.pack(">I", len(data)) + zlib.compress(data, level=8)
    return "vpn://" + base64.urlsafe_b64encode(framed).rstrip(b"=").decode()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", help="vpn:// text file, or - for standard input")
    parser.add_argument("output", help="new file to create; existing files are never overwritten")
    args = parser.parse_args()
    source = sys.stdin.read() if args.input == "-" else open(args.input, encoding="utf-8").read()
    result = convert(source)
    old_umask = os.umask(0o077)
    try:
        fd = os.open(args.output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            stream.write(result + "\n")
    finally:
        os.umask(old_umask)
    print(f"Compatible profile saved to {args.output}; keep it private.")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, TypeError, zlib.error) as exc:
        print(f"Error: {exc}", file=sys.stderr)
        sys.exit(1)
