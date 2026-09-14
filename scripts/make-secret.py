#!/usr/bin/env python3
"""Regenerates the obfuscated backend secret in Sources/App/BackendCredential.swift.

    python3 scripts/make-secret.py 'the-secret'      # set it
    python3 scripts/make-secret.py --clear           # back to unsigned

The same value goes in the backend's environment:

    VIBESCROLL_SECRETS='the-secret' npm start

The pad is random per run, so two builds of the same secret do not produce
byte-identical binaries — which is the only thing standing between this and a
plain string literal. It is obfuscation, not encryption: anybody who wants the
value can have it, and `ClientSignature` says so in as many words.
"""
import os
import pathlib
import re
import sys

TARGET = pathlib.Path(__file__).resolve().parent.parent / "Sources/App/BackendCredential.swift"


def literal(name: str, data: bytes) -> str:
    if not data:
        return f"    private static let {name}: [UInt8] = []"
    body = ", ".join(str(b) for b in data)
    lines, current = [], "    "
    for chunk in body.split(", "):
        piece = chunk + ", "
        if len(current) + len(piece) > 92:
            lines.append(current.rstrip())
            current = "    "
        current += piece
    lines.append(current.rstrip().rstrip(","))
    return f"    private static let {name}: [UInt8] = [\n" + "\n".join(
        "    " + line.strip() for line in lines) + "\n    ]"


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__)
        return 2
    arg = sys.argv[1]
    if arg == "--clear":
        cipher = pad = b""
    else:
        raw = arg.encode("utf-8")
        pad = os.urandom(len(raw))
        cipher = bytes(a ^ b for a, b in zip(raw, pad))

    source = TARGET.read_text()
    for name, data in (("cipher", cipher), ("pad", pad)):
        pattern = rf"    private static let {name}: \[UInt8\] = (?:\[\]|\[[^\]]*\])"
        source, count = re.subn(pattern, literal(name, data), source, count=1)
        if count != 1:
            print(f"error: could not find the {name} array in {TARGET}", file=sys.stderr)
            return 1
    TARGET.write_text(source)

    print(f"wrote {TARGET.relative_to(pathlib.Path.cwd()) if TARGET.is_relative_to(pathlib.Path.cwd()) else TARGET}")
    if cipher:
        print("\nSet the same value on the server:\n")
        print(f"    VIBESCROLL_SECRETS='{arg}' npm start\n")
        print("Keep the previous secret in that list for a release or two —")
        print("installed copies of the app still carry it.")
    else:
        print("cleared: this build will send unsigned requests")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
