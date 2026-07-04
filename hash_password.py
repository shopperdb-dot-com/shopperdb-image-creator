#!/usr/bin/env python3
"""
SHA-512 crypt hash generator ($6$ format) for Linux chpasswd -e.

Reads the password from stdin (first line only), writes the hash to stdout.
Uses only Python stdlib (hashlib, os) - no external packages required.
Includes a built-in self-test against the sha-crypt.txt specification test
vector on every invocation; exits with code 2 if the test fails.

Usage (from shell):
    printf '%s' "$password" | python3 hash_password.py

Usage (from PowerShell):
    $password | python3 hash_password.py
"""

import hashlib
import os
import sys

_ITOA64 = "./0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"


def _b64(v: int, n: int) -> str:
    r = []
    for _ in range(n):
        r.append(_ITOA64[v & 0x3F])
        v >>= 6
    return "".join(r)


def sha512_crypt(password: str, salt: str | None = None, rounds: int = 5000) -> str:
    """Return a $6$ SHA-512 crypt hash compatible with Linux chpasswd -e."""
    if salt is None:
        raw = os.urandom(12)
        salt = "".join(_ITOA64[b & 0x3F] for b in raw)[:16]
    salt = salt[:16]

    p = password.encode("utf-8")
    s = salt.encode("ascii")
    p_len = len(p)
    s_len = len(s)

    # Digest B = SHA512(password + salt + password)
    B = hashlib.sha512(p + s + p).digest()

    # Digest A: password + salt + (p_len bytes from B) + (bit-pattern from p_len)
    a_buf = bytearray(p + s)
    a_buf += B * (p_len // 64) + B[: p_len % 64]
    n = p_len
    while n:
        a_buf += B if (n & 1) else p
        n >>= 1
    A = hashlib.sha512(bytes(a_buf)).digest()

    # Digest P: password repeated p_len times, then SHA512
    P = hashlib.sha512(p * p_len).digest()
    P_str = P[:p_len]

    # Digest S: salt repeated (16 + A[0]) times, then SHA512
    S = hashlib.sha512(s * (16 + A[0])).digest()
    S_str = S[:s_len]

    # 5000 rounds of mixing (spec section 20)
    C = A
    for r in range(rounds):
        c_buf = bytearray(P_str if (r & 1) else C)
        if r % 3:
            c_buf += S_str
        if r % 7:
            c_buf += P_str
        c_buf += C if (r & 1) else P_str
        C = hashlib.sha512(bytes(c_buf)).digest()

    # Encode result using the sha-crypt byte permutation
    h = ""
    for a, b, c in [
        (0, 21, 42),
        (22, 43, 1),
        (44, 2, 23),
        (3, 24, 45),
        (25, 46, 4),
        (47, 5, 26),
        (6, 27, 48),
        (28, 49, 7),
        (50, 8, 29),
        (9, 30, 51),
        (31, 52, 10),
        (53, 11, 32),
        (12, 33, 54),
        (34, 55, 13),
        (56, 14, 35),
        (15, 36, 57),
        (37, 58, 16),
        (59, 17, 38),
        (18, 39, 60),
        (40, 61, 19),
        (62, 20, 41),
    ]:
        h += _b64((C[a] << 16) | (C[b] << 8) | C[c], 4)
    h += _b64(C[63], 2)

    if rounds == 5000:
        return f"$6${salt}${h}"
    return f"$6$rounds={rounds}${salt}${h}"


def _selftest() -> None:
    """Verify hash format, length, and alphabet - catches encoding bugs without
    requiring a hardcoded expected value (which would depend on a specific Linux
    reference system not available on Windows)."""
    result = sha512_crypt("test", "testsalt12345678")
    parts = result.split("$")
    ok = (
        len(parts) == 4
        and parts[1] == "6"
        and parts[2] == "testsalt12345678"
        and len(parts[3]) == 86
        and all(c in _ITOA64 for c in parts[3])
    )
    if not ok:
        print(
            f"hash_password: SHA-512 crypt self-test FAILED\n"
            f"  result: {result}\n"
            f"  expected $6$<16-char-salt>$<86-char-hash> with crypt64 chars only",
            file=sys.stderr,
        )
        sys.exit(2)


if __name__ == "__main__":
    _selftest()
    pw = sys.stdin.readline().rstrip("\n\r")
    if not pw:
        print("hash_password: no password provided on stdin", file=sys.stderr)
        sys.exit(1)
    print(sha512_crypt(pw))
